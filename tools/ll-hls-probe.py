#!/usr/bin/env python3
"""Bounded, localhost-only Twitch -> LL-HLS experiment. Not a production server."""

import argparse
import asyncio
import base64
from collections import deque
from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone
import gzip
import json
import hashlib
import logging
import math
from pathlib import Path
import re
import shutil
import signal
import socket
import ssl
import statistics
import struct
import subprocess
import tempfile
import threading
import time
import uuid
from urllib.error import HTTPError, URLError
from urllib.parse import parse_qs, urlencode, urljoin, urlsplit
from urllib.request import Request, urlopen


HEADERS = {
    "User-Agent": "Mozilla/5.0",
    "Origin": "https://player.twitch.tv",
    "Referer": "https://player.twitch.tv",
}
MAX_BOX = 32 * 1024 * 1024
PART_TARGET = 0.35
HOLD_BACK = max(1.5, 3 * PART_TARGET)


class ProbeError(Exception):
    pass


def fetch(url, data=None, headers=None):
    try:
        return urlopen(Request(url, data=data, headers=HEADERS | (headers or {})), timeout=8)
    except HTTPError as error:
        raise ProbeError(f"Upstream HTTP {error.code}") from None
    except URLError:
        raise ProbeError("Upstream connection failed") from None


def resolve(channel):
    body = {
        "operationName": "PlaybackAccessToken",
        "extensions": {"persistedQuery": {
            "version": 1,
            "sha256Hash": "ed230aa1e33e07eebb8928504583da78a5173989fadfb1ac94be06a04f3cdbe9",
        }},
        "variables": {
            "isLive": True, "login": channel, "isVod": False, "vodID": "",
            "playerType": "embed", "platform": "site",
        },
    }
    with fetch("https://gql.twitch.tv/gql", json.dumps(body).encode(), {
        "Client-ID": "kimne78kx3ncx6brgo4mv6wki5h1ko",
        "Content-Type": "application/json",
    }) as response:
        reply = json.load(response)
    token = (reply.get("data") or {}).get("streamPlaybackAccessToken")
    if reply.get("errors") or not token:
        raise ProbeError("Twitch playback token unavailable; no integrity or ad bypass is attempted")
    master = "https://usher.ttvnw.net/api/v2/channel/hls/" + channel + ".m3u8?" + urlencode({
        "platform": "web", "allow_source": "true", "supported_codecs": "h264",
        "fast_bread": "true", "sig": token["signature"], "token": token["value"],
    })
    with fetch(master) as response:
        text = response.read().decode()
    variants = []
    info = ""
    for line in text.splitlines():
        if line.startswith("#EXT-X-STREAM-INF:"):
            info = line
        elif line and not line.startswith("#") and info:
            match = re.search(r"(?:[:,])BANDWIDTH=(\d+)", info)
            if "RESOLUTION=" in info and match:
                variants.append((int(match[1]), urljoin(master, line)))
            info = ""
    if not variants:
        raise ProbeError("No video rendition found")
    # Use the same moderate-bandwidth rendition for both players.
    variants.sort()
    return min(variants, key=lambda variant: abs(variant[0] - 3_000_000))


def media_entries(text, base):
    if not text.startswith("#EXTM3U"):
        raise ProbeError("Invalid upstream playlist")
    forbidden = ("#EXT-X-KEY:", "#EXT-X-BYTERANGE:", "#EXT-X-ENDLIST", "#EXT-X-GAP")
    for line in text.splitlines():
        if line.startswith(forbidden) or line == "#EXT-X-DISCONTINUITY":
            raise ProbeError("Unsupported encryption/range/discontinuity/end transition; stopping, not skipping")
        if line.startswith("#EXT-X-DATERANGE:"):
            match = re.search(r'CLASS="([^"]+)"', line)
            if not match or match[1] not in ("timestamp", "twitch-session", "twitch-stream-source", "twitch-trigger"):
                raise ProbeError("Unsupported ad or date-range transition; stopping, not skipping")
    sequence = re.search(r"(?m)^#EXT-X-MEDIA-SEQUENCE:(\d+)", text)
    if not sequence:
        raise ProbeError("Missing media sequence")
    number = int(sequence[1])
    entries = []
    for line in text.splitlines():
        prefetch = line.startswith("#EXT-X-TWITCH-PREFETCH:")
        if prefetch:
            line = line.split(":", 1)[1]
        elif not line or line.startswith("#"):
            continue
        url = urljoin(base, line)
        if urlsplit(url).scheme != "https":
            raise ProbeError("Only HTTPS upstream media is supported")
        entries.append((number, url, prefetch))
        number += 1
    if not entries:
        raise ProbeError("Empty upstream playlist")
    return entries


def boxes(data):
    offset = 0
    while offset < len(data):
        if len(data) - offset < 8:
            raise ProbeError("Truncated MP4 box")
        size, kind = struct.unpack_from(">I4s", data, offset)
        header = 8
        if size == 1:
            if len(data) - offset < 16:
                raise ProbeError("Truncated extended MP4 box")
            size = struct.unpack_from(">Q", data, offset + 8)[0]
            header = 16
        if size < header or size > MAX_BOX or offset + size > len(data):
            raise ProbeError("Invalid MP4 box length")
        yield kind, data[offset + header:offset + size]
        offset += size


def child(data, name):
    values = [payload for kind, payload in boxes(data) if kind == name]
    if len(values) != 1:
        raise ProbeError(f"Expected one {name.decode()} box")
    return values[0]


def u32(data, offset):
    if offset < 0 or offset + 4 > len(data):
        raise ProbeError("Truncated MP4 field")
    return struct.unpack_from(">I", data, offset)[0]


def video_track(moov):
    for kind, trak in boxes(moov):
        if kind != b"trak":
            continue
        mdia = child(trak, b"mdia")
        if child(mdia, b"hdlr")[8:12] != b"vide":
            continue
        tkhd, mdhd = child(trak, b"tkhd"), child(mdia, b"mdhd")
        track = u32(tkhd, 20 if tkhd[0] else 12)
        scale = u32(mdhd, 20 if mdhd[0] else 12)
        if scale == 0:
            raise ProbeError("Invalid video timescale")
        for kind, trex in boxes(child(moov, b"mvex")):
            if kind == b"trex" and u32(trex, 4) == track:
                return track, scale, u32(trex, 12), u32(trex, 20)
        raise ProbeError("Missing video fragment defaults")
    raise ProbeError("No video track in fragmented MP4")


def fragment_timing(moof, track):
    track_id, scale, default_duration, default_flags = track
    for kind, traf in boxes(moof):
        if kind != b"traf":
            continue
        tfhd = child(traf, b"tfhd")
        if u32(tfhd, 4) != track_id:
            continue
        flags = u32(tfhd, 0) & 0xFFFFFF
        if flags & 1:
            raise ProbeError("Absolute MP4 data offsets cannot be repackaged without rewriting")
        pos = 8 + (8 if flags & 1 else 0) + (4 if flags & 2 else 0)
        if flags & 8:
            default_duration, pos = u32(tfhd, pos), pos + 4
        if flags & 16:
            pos += 4
        if flags & 32:
            default_flags = u32(tfhd, pos)
        tfdt = child(traf, b"tfdt")
        decode = u32(tfdt, 4)
        if tfdt[0] == 1:
            decode = decode * (1 << 32) + u32(tfdt, 8)
        duration, first_flags = 0, None
        for kind, trun in boxes(traf):
            if kind != b"trun":
                continue
            flags, count = u32(trun, 0) & 0xFFFFFF, u32(trun, 4)
            if count > 100_000:
                raise ProbeError("Unbounded MP4 sample count")
            pos = 8 + (4 if flags & 1 else 0)
            first = default_flags
            if flags & 4:
                first, pos = u32(trun, pos), pos + 4
            for index in range(count):
                sample_duration = default_duration
                sample_flags = first if index == 0 else default_flags
                if flags & 0x100:
                    sample_duration, pos = u32(trun, pos), pos + 4
                if flags & 0x200:
                    pos += 4
                if flags & 0x400:
                    sample_flags, pos = u32(trun, pos), pos + 4
                if flags & 0x800:
                    pos += 4
                if pos > len(trun) or sample_duration <= 0:
                    raise ProbeError("Invalid MP4 sample")
                if first_flags is None:
                    first_flags = sample_flags
                duration += sample_duration
        if not duration or first_flags is None:
            raise ProbeError("Empty video fragment")
        return decode / scale, duration / scale, not bool(first_flags & 0x10000)
    raise ProbeError("Fragment has no video samples")


def read_box(stream):
    def exact(size):
        data = bytearray()
        while len(data) < size:
            more = stream.read(size - len(data))
            if not more:
                raise ProbeError("Remuxer stopped inside an MP4 box")
            data.extend(more)
        return bytes(data)
    header = exact(8)
    size = u32(header, 0)
    if size == 1:
        header += exact(8)
        size = struct.unpack_from(">Q", header, 8)[0]
    if size < len(header) or size > MAX_BOX:
        raise ProbeError("Invalid streaming MP4 box size")
    return header + exact(size - len(header))


@dataclass
class Segment:
    sequence: int
    parts: list = field(default_factory=list)
    complete: bool = False
    program_date: datetime | None = None
    part_sources: list = field(default_factory=list)

    @property
    def duration(self):
        return sum(part[1] for part in self.parts)


class Origin:
    def __init__(self, part_target=PART_TARGET):
        self.condition = threading.Condition()
        self.segments = deque()
        self.init = b""
        self.next_sequence = 0
        self.last_end = None
        self.target_duration = None
        self.part_target = part_target
        self.source_format = "remuxed"
        self.resource_loader = False
        self.direct_media = False
        self.upstream_init = None
        self.error = None
        self.stopped = threading.Event()
        self.player_started_at = None
        self.stats = {"parts_published": 0, "parts_requested": 0, "segments_requested": 0,
                      "blocking_requests": 0, "preload_requests": 0, "not_found": 0,
                      "playlist_requests": 0, "init_requests": 0, "http2_requests": 0,
                      "parts_served": 0, "steady_parts_served": 0, "part_windows": {}}

    def fail(self, message):
        with self.condition:
            if not self.stopped.is_set():
                self.error = message
                self.stopped.set()
            self.condition.notify_all()

    def append(self, data, start, duration, independent, program_date=None, complete=False, source=None):
        with self.condition:
            if not 0 < duration <= self.part_target:
                raise ProbeError("Fragment exceeds declared PART-TARGET")
            if self.last_end is not None and abs(start - self.last_end) > 0.002:
                raise ProbeError("Discontinuous video decode timestamps")
            if not self.segments or self.segments[-1].complete or (independent and self.segments[-1].duration >= 1):
                if not independent:
                    raise ProbeError("First fragment is not independently decodable")
                if self.segments:
                    self.segments[-1].complete = True
                self.segments.append(Segment(self.next_sequence, program_date=program_date))
                self.next_sequence += 1
            self.segments[-1].parts.append((data, duration, independent))
            self.segments[-1].part_sources.append(source)
            self.segments[-1].complete = complete
            self.last_end = start + duration
            self.stats["parts_published"] += 1
            completed = [s.duration for s in self.segments if s.complete]
            if len(completed) >= 3 and self.target_duration is None:
                self.target_duration = math.ceil(max(completed))
            if self.target_duration and any(math.floor(value + 0.5) > self.target_duration for value in completed):
                raise ProbeError("Segment duration changed beyond declared target")
            # Retain old bytes beyond the advertised six-segment window.
            while len(self.segments) > 18:
                self.segments.popleft()
            if sum(len(p[0]) for s in self.segments for p in s.parts) > 128 * 1024 * 1024:
                raise ProbeError("Prototype memory budget exceeded")
            if self.segments[-1].duration > 6:
                raise ProbeError("Keyframe interval exceeds prototype target duration")
            self.condition.notify_all()

    def finish_segment(self):
        with self.condition:
            if self.segments:
                self.segments[-1].complete = True
                self.condition.notify_all()

    def playlist(self):
        visible = list(self.segments)[-6:]
        if not visible or not any(segment.complete for segment in visible):
            raise ProbeError("Origin is not ready")
        lines = ["#EXTM3U", "#EXT-X-VERSION:9", f"#EXT-X-TARGETDURATION:{self.target_duration or 6}",
                 "#EXT-X-INDEPENDENT-SEGMENTS",
                 f"#EXT-X-MEDIA-SEQUENCE:{visible[0].sequence}",
                 f'#EXT-X-MAP:URI="{self.upstream_init if self.direct_media else "init.mp4"}"',
                 f"#EXT-X-PART-INF:PART-TARGET={self.part_target}",
                 f"#EXT-X-SERVER-CONTROL:CAN-BLOCK-RELOAD=YES,PART-HOLD-BACK={max(1.5, 3 * self.part_target):.3f}"]
        remaining = sum(segment.duration for segment in visible)
        for segment in visible:
            if segment.program_date is not None:
                lines.append("#EXT-X-PROGRAM-DATE-TIME:" + segment.program_date.isoformat(timespec="milliseconds").replace("+00:00", "Z"))
            if remaining <= 3 * (self.target_duration or 6):
                for index, (_, duration, independent) in enumerate(segment.parts):
                    suffix = ",INDEPENDENT=YES" if independent else ""
                    if self.direct_media:
                        source = segment.part_sources[index]
                        if source is None:
                            raise ProbeError("Missing upstream byte range for a direct part")
                        uri = source[0]
                        suffix += f',BYTERANGE="{source[2]}@{source[1]}"'
                    else:
                        uri = f"part/{segment.sequence}/{index}.mp4"
                    lines.append(f'#EXT-X-PART:DURATION={duration:.6f},URI="{uri}"{suffix}')
            if segment.complete:
                uri = segment.part_sources[0][0] if self.direct_media else f"segment/{segment.sequence}.mp4"
                lines += [f"#EXTINF:{segment.duration:.6f},", uri]
            remaining -= segment.duration
        tail = visible[-1]
        next_sequence, next_part = (tail.sequence + 1, 0) if tail.complete else (tail.sequence, len(tail.parts))
        # The direct-media hint redirects once that part has a real upstream range.
        hint = f"part/{next_sequence}/{next_part}.mp4"
        lines.append(f'#EXT-X-PRELOAD-HINT:TYPE=PART,URI="{hint}"')
        return ("\n".join(lines) + "\n").encode()

    def ready(self):
        return bool(self.init and self.target_duration is not None
                    and sum(s.duration for s in self.segments if s.complete) >= 3 * self.target_duration)

    def respond(self, path, query):
        deadline = time.monotonic() + 3
        with self.condition:
            if self.error:
                return 503, b"Origin stopped; see report", "text/plain"
            if path == "/live.m3u8":
                self.stats["playlist_requests"] += 1
                msn, part = query.get("_HLS_msn"), query.get("_HLS_part")
                if part and not msn:
                    return 400, b"Part directive requires a media sequence", "text/plain"
                if msn:
                    try:
                        if len(msn) != 1 or (part and len(part) != 1):
                            raise ValueError
                        wanted = (int(msn[0]), int(part[0]) if part else None)
                    except ValueError:
                        return 400, b"Invalid delivery directive", "text/plain"
                    if wanted[0] < 0 or wanted[0] > self.next_sequence + 1 or (
                            wanted[1] is not None and not 0 <= wanted[1] <= 128):
                        return 400, b"Out-of-range delivery directive", "text/plain"
                    self.stats["blocking_requests"] += 1
                    while not self.stopped.is_set() and time.monotonic() < deadline:
                        if self.segments:
                            tail = self.segments[-1]
                            if tail.sequence > wanted[0] or (
                                tail.sequence == wanted[0] and (
                                    tail.complete if wanted[1] is None else len(tail.parts) > wanted[1]
                                )
                            ):
                                break
                        self.condition.wait(max(0, deadline - time.monotonic()))
                if self.stopped.is_set():
                    return 503, b"Origin stopped", "text/plain"
                return (200, self.playlist(), "application/vnd.apple.mpegurl") if self.ready() else (
                    503, b"Origin not ready", "text/plain")
            if path == "/init.mp4":
                self.stats["init_requests"] += 1
                return 200, self.init, "video/mp4"
            match = re.fullmatch(r"/(part|segment)/(\d+)(?:/(\d+))?\.mp4", path)
            if match:
                kind, sequence, index = match.groups()
                if kind == "part" and index is not None:
                    self.stats["parts_requested"] += 1
                    while not self.stopped.is_set():
                        segment = next((s for s in self.segments if s.sequence == int(sequence)), None)
                        if segment and int(index) < len(segment.parts):
                            self.stats["parts_served"] += 1
                            if self.player_started_at is not None and time.monotonic() - self.player_started_at >= 10:
                                self.stats["steady_parts_served"] += 1
                                window = str(int((time.monotonic() - self.player_started_at) // 10))
                                self.stats["part_windows"][window] = self.stats["part_windows"].get(window, 0) + 1
                            if self.direct_media:
                                source = segment.part_sources[int(index)]
                                return 200, json.dumps({"url": source[0], "offset": source[1], "length": source[2]}).encode(), "application/json"
                            return 200, segment.parts[int(index)][0], "video/mp4"
                        if time.monotonic() >= deadline or (segment and segment.complete):
                            break
                        self.stats["preload_requests"] += 1
                        self.condition.wait(max(0, deadline - time.monotonic()))
                elif kind == "segment" and index is None:
                    self.stats["segments_requested"] += 1
                    segment = next((s for s in self.segments if s.sequence == int(sequence)), None)
                    if segment and segment.complete:
                        return 200, b"".join(p[0] for p in segment.parts), "video/mp4"
            if self.stopped.is_set():
                return 503, b"Origin stopped", "text/plain"
            self.stats["not_found"] += 1
            return 404, b"Resource unavailable", "text/plain"


def playlist_dates(text):
    dates = {}
    sequence = re.search(r"(?m)^#EXT-X-MEDIA-SEQUENCE:(\d+)", text)
    if not sequence:
        raise ProbeError("Missing media sequence for program dates")
    number = int(sequence[1])
    date, duration = None, None
    for line in text.splitlines():
        if line.startswith("#EXT-X-PROGRAM-DATE-TIME:"):
            date = datetime.fromisoformat(line.split(":", 1)[1].replace("Z", "+00:00"))
            if date.tzinfo is None:
                raise ProbeError("Program date is missing its timezone")
            date = date.astimezone(timezone.utc)
        elif line.startswith("#EXTINF:"):
            duration = float(line.split(":", 1)[1].split(",", 1)[0])
            if not math.isfinite(duration) or duration <= 0:
                raise ProbeError("Invalid segment duration for program-date extrapolation")
        elif line and not line.startswith("#"):
            if date is not None:
                dates[number] = date
                date = date + timedelta(seconds=duration) if duration is not None else None
            number += 1
    return dates


class CMAFParts:
    """Group complete source fragments, preserving their encoded bytes and media clock."""
    def __init__(self, origin, anchor):
        self.origin, self.anchor = origin, anchor
        self.anchor_clock = None
        self.pending = bytearray()
        self.start, self.duration, self.independent = 0, 0, False
        self.source = None

    def push(self, fragment, timing, source=None):
        start, duration, independent = timing
        if not 0 < duration <= self.origin.part_target:
            raise ProbeError("Source fragment exceeds declared PART-TARGET")
        if self.anchor_clock is None:
            if not independent:
                raise ProbeError("CMAF entry is not a random-access fragment")
            self.anchor_clock = start
        if self.pending and (independent or self.duration + duration > self.origin.part_target):
            self.flush()
        if not self.pending:
            self.start, self.independent = start, independent
            self.source = source
        elif abs(start - (self.start + self.duration)) > 0.002:
            raise ProbeError("Discontinuous source CMAF fragment clock")
        elif source is not None:
            if self.source is None or source[0] != self.source[0] or source[1] < self.source[1] + self.source[2]:
                raise ProbeError("Non-contiguous source for a direct CMAF part")
            self.source = (source[0], self.source[1], source[1] + source[2] - self.source[1])
        self.pending.extend(fragment)
        self.duration += duration
        if self.duration >= 0.85 * self.origin.part_target:
            self.flush()

    def flush(self, complete=False):
        if self.pending:
            date = self.anchor + timedelta(seconds=self.start - self.anchor_clock)
            self.origin.append(bytes(self.pending), self.start, self.duration, self.independent, date, complete, self.source)
            self.pending.clear()
            self.duration = 0
        elif complete:
            self.origin.finish_segment()


def ingest_cmaf(origin, media_url, map_url):
    try:
        if urlsplit(map_url).scheme != "https":
            raise ProbeError("Only HTTPS initialization media is supported")
        with fetch(map_url) as response:
            init = response.read(MAX_BOX + 1)
        if len(init) > MAX_BOX:
            raise ProbeError("Initialization media exceeds memory budget")
        track = video_track(child(init, b"moov"))
        origin.init = init
        origin.upstream_init = map_url
        origin.source_format = "source-cmaf"
        expected, parts, discontinuity = None, None, None
        while not origin.stopped.is_set():
            with fetch(media_url) as response:
                text = response.read().decode()
            entries = media_entries(text, media_url)
            disc_match = re.search(r"(?m)^#EXT-X-DISCONTINUITY-SEQUENCE:(\d+)", text)
            current_discontinuity = int(disc_match[1]) if disc_match else 0
            if discontinuity is not None and current_discontinuity != discontinuity:
                raise ProbeError("Source CMAF discontinuity sequence changed")
            discontinuity = current_discontinuity
            current_map = re.search(r'(?m)^#EXT-X-MAP:URI="([^"]+)"$', text)
            if not current_map or urljoin(media_url, current_map[1]) != map_url:
                raise ProbeError("Source CMAF map changed")
            dates = playlist_dates(text)
            if expected is None:
                if not any(entry[2] for entry in entries):
                    raise ProbeError("Channel does not advertise Twitch low-latency prefetch")
                # Anchor on a completed segment with an actual source program date.
                candidates = [entry[0] for entry in entries if not entry[2] and entry[0] in dates]
                if not candidates:
                    raise ProbeError("Source CMAF has no trustworthy program-date anchor")
                expected = candidates[-1]
                parts = CMAFParts(origin, dates[expected])
            if entries[0][0] > expected:
                raise ProbeError("Missed source CMAF segment")
            entry = next((entry for entry in entries if entry[0] == expected), None)
            if entry is None:
                origin.stopped.wait(0.1)
                continue
            pending = bytearray()
            moof, timing, first_fragment = None, None, True
            byte_offset, moof_offset = 0, 0
            with fetch(entry[1]) as response:
                deadline = time.monotonic() + 12
                while not origin.stopped.is_set():
                    block = response.read1(32 * 1024)
                    if not block:
                        break
                    if time.monotonic() > deadline:
                        raise ProbeError("CMAF segment delivery deadline exceeded")
                    pending.extend(block)
                    while len(pending) >= 8:
                        size = u32(pending, 0)
                        if size == 1:
                            if len(pending) < 16:
                                break
                            size = struct.unpack_from(">Q", pending, 8)[0]
                        if size < 8 or size > MAX_BOX:
                            raise ProbeError("Invalid source CMAF box length")
                        if len(pending) < size:
                            break
                        box = bytes(pending[:size])
                        del pending[:size]
                        box_offset = byte_offset
                        byte_offset += size
                        kind, payload = next(boxes(box))
                        if kind == b"moof":
                            if moof is not None:
                                raise ProbeError("Source fragment missing media data")
                            moof, timing = box, fragment_timing(payload, track)
                            moof_offset = box_offset
                            if first_fragment and expected in dates and parts.anchor_clock is not None:
                                predicted_date = parts.anchor + timedelta(seconds=timing[0] - parts.anchor_clock)
                                if abs((predicted_date - dates[expected]).total_seconds()) > 0.2:
                                    raise ProbeError("Source program-date timeline changed")
                            first_fragment = False
                        elif kind == b"mdat":
                            if moof is None:
                                raise ProbeError("Source payload missing fragment header")
                            parts.push(moof + box, timing, (entry[1], moof_offset, byte_offset - moof_offset))
                            moof, timing = None, None
                        elif kind not in (b"emsg", b"styp", b"sidx", b"free", b"prft"):
                            raise ProbeError("Unsupported source CMAF box")
            if pending or moof is not None:
                raise ProbeError("Incomplete source CMAF segment")
            parts.flush(complete=True)
            expected += 1
    except (ProbeError, OSError, ValueError) as error:
        origin.fail(str(error) if isinstance(error, ProbeError) else f"CMAF ingest failed: {type(error).__name__}")


def ingest(origin, media_url, process):
    try:
        expected = None
        initial_map = None
        initial_discontinuity = None
        while not origin.stopped.is_set():
            with fetch(media_url) as response:
                text = response.read().decode()
            entries = media_entries(text, media_url)
            map_match = re.search(r'(?m)^#EXT-X-MAP:URI="([^"]+)"$', text)
            if "#EXT-X-MAP:" in text and not map_match:
                raise ProbeError("Unsupported initialization-map attributes")
            map_url = urljoin(media_url, map_match[1]) if map_match else None
            disc_match = re.search(r"(?m)^#EXT-X-DISCONTINUITY-SEQUENCE:(\d+)", text)
            discontinuity = int(disc_match[1]) if disc_match else 0
            if expected is None:
                if not any(entry[2] for entry in entries):
                    raise ProbeError("Channel does not advertise Twitch low-latency prefetch")
                initial_map, initial_discontinuity = map_url, discontinuity
                if map_url:
                    if urlsplit(map_url).scheme != "https":
                        raise ProbeError("Only HTTPS initialization media is supported")
                    with fetch(map_url) as response:
                        init = response.read(MAX_BOX + 1)
                    if len(init) > MAX_BOX:
                        raise ProbeError("Initialization media exceeds memory budget")
                    process.stdin.write(init)
                    process.stdin.flush()
                expected = entries[max(0, len(entries) - 3)][0]
            elif map_url != initial_map or discontinuity != initial_discontinuity:
                raise ProbeError("Container/discontinuity changed; refusing to splice a broken timeline")
            if entries[0][0] > expected:
                raise ProbeError("Missed upstream segment; refusing to splice a broken timeline")
            entry = next((entry for entry in entries if entry[0] == expected), None)
            if entry is None:
                origin.stopped.wait(0.15)
                continue
            with fetch(entry[1]) as response:
                deadline = time.monotonic() + 12
                while not origin.stopped.is_set():
                    data = response.read1(32 * 1024)
                    if not data:
                        break
                    if time.monotonic() > deadline:
                        raise ProbeError("Upstream segment delivery deadline exceeded")
                    process.stdin.write(data)
                    process.stdin.flush()
            expected += 1
    except (ProbeError, OSError, TimeoutError, ValueError) as error:
        origin.fail(str(error) if isinstance(error, ProbeError) else f"Ingest failed: {type(error).__name__}")


def package(origin, process):
    try:
        initial = bytearray()
        track, pending = None, None
        while not origin.stopped.is_set():
            data = read_box(process.stdout)
            kind, payload = next(boxes(data))
            if kind in (b"ftyp", b"moov"):
                initial.extend(data)
                if kind == b"moov":
                    track = video_track(payload)
                    origin.init = bytes(initial)
            elif kind == b"moof":
                if pending is not None or track is None:
                    raise ProbeError("Unexpected fragment order")
                pending = (data, fragment_timing(payload, track))
            elif kind == b"mdat":
                if pending is None:
                    raise ProbeError("Media payload without fragment")
                origin.append(pending[0] + data, *pending[1])
                pending = None
            elif kind not in (b"free", b"mfra"):
                raise ProbeError("Unsupported remuxer box")
    except (ProbeError, OSError) as error:
        origin.fail(str(error) if isinstance(error, ProbeError) else "Remuxer pipe failed")


class Transport:
    def __init__(self, origin, directory, use_tls=True):
        from hypercorn.config import Config
        self.origin = origin
        self.trust_attempted = False
        self.trust_removed = False
        self.keychain = Path.home() / "Library/Keychains/login.keychain-db"
        self.temporary, self.context = None, None
        self.config = Config()
        if use_tls:
            self.temporary = tempfile.TemporaryDirectory(prefix="loopback-tls-", dir=directory)
            cert, key = (Path(self.temporary.name) / name for name in ("cert.pem", "key.pem"))
            self.cert = cert
            self.common_name = f"Strozz LL-HLS probe {uuid.uuid4()}"
            subprocess.run([
                "openssl", "req", "-x509", "-newkey", "rsa:2048", "-noenc",
                "-keyout", str(key), "-out", str(cert), "-days", "1",
                "-subj", f"/CN={self.common_name}",
                "-addext", "subjectAltName=IP:127.0.0.1",
                "-addext", "basicConstraints=critical,CA:TRUE",
            ], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            self.fingerprint = hashlib.sha1(ssl.PEM_cert_to_DER_cert(cert.read_text())).hexdigest().upper()
            self.context = ssl.create_default_context(cafile=str(cert))
            self.config.certfile, self.config.keyfile = str(cert), str(key)
        sock = socket.socket()
        sock.bind(("127.0.0.1", 0))
        self.url = f"{'https' if use_tls else 'http'}://127.0.0.1:{sock.getsockname()[1]}/live.m3u8"
        self.config.bind = [f"fd://{sock.detach()}"]
        self.log_handler = logging.FileHandler(directory / "transport.log")
        self.log_handler.setFormatter(logging.Formatter("%(asctime)s %(levelname)s %(message)s"))
        self.log = logging.Logger(f"strozz.probe.{uuid.uuid4()}", level=logging.INFO)
        self.log.addHandler(self.log_handler)
        self.config.errorlog = self.log
        self.config.graceful_timeout = 3
        self.thread = threading.Thread(target=self.run, daemon=True)
        self.thread.start()

    def trust_for_native(self):
        if self.temporary is None:
            raise ProbeError("Resource-loader experiments do not use certificate trust")
        self.trust_attempted = True
        result = subprocess.run([
            "/usr/bin/security", "add-trusted-cert", "-r", "trustRoot", "-p", "ssl",
            "-s", "127.0.0.1", "-k", str(self.keychain), str(self.cert),
        ], capture_output=True, text=True)
        if result.returncode:
            raise ProbeError("Temporary login-keychain trust was not authorized; no system-wide fallback attempted")

    async def app(self, scope, receive, send):
        if scope["type"] == "lifespan":
            while True:
                event = await receive()
                if event["type"] == "lifespan.startup":
                    await send({"type": "lifespan.startup.complete"})
                elif event["type"] == "lifespan.shutdown":
                    await send({"type": "lifespan.shutdown.complete"})
                    return
        elif scope["type"] == "http":
            if scope["http_version"] == "2":
                with self.origin.condition:
                    self.origin.stats["http2_requests"] += 1
            if scope["method"] != "GET":
                status, data, kind = 405, b"GET required", "text/plain"
            else:
                status, data, kind = await asyncio.to_thread(
                    self.origin.respond, scope["path"], parse_qs(scope["query_string"].decode()))
            headers = [
                (b"content-type", kind.encode()), (b"content-length", str(len(data)).encode()),
                (b"cache-control", b"no-store"),
            ]
            if kind == "application/vnd.apple.mpegurl" and b"gzip" in dict(scope["headers"]).get(b"accept-encoding", b""):
                data = gzip.compress(data, mtime=0)
                headers = [(key, value) for key, value in headers if key != b"content-length"]
                headers += [(b"content-encoding", b"gzip"), (b"content-length", str(len(data)).encode()),
                            (b"vary", b"Accept-Encoding")]
            await send({"type": "http.response.start", "status": status, "headers": headers})
            await send({"type": "http.response.body", "body": data})

    def run(self):
        from hypercorn.asyncio import serve
        async def shutdown():
            while not self.origin.stopped.is_set():
                await asyncio.sleep(0.1)
        try:
            asyncio.run(serve(self.app, self.config, shutdown_trigger=shutdown))
        except (OSError, RuntimeError) as error:
            self.origin.fail(f"HTTP/2 server failed: {type(error).__name__}")

    def check_ready(self):
        for _ in range(30):
            try:
                with urlopen(self.url, context=self.context, timeout=1) as response:
                    if b"#EXT-X-PART:" not in response.read():
                        raise ProbeError("Origin readiness check failed")
                return
            except URLError:
                if self.origin.error:
                    raise ProbeError(self.origin.error) from None
                time.sleep(0.1)
        raise ProbeError("HTTPS loopback server did not become ready")

    def close(self):
        self.thread.join(timeout=8)
        self.log.removeHandler(self.log_handler)
        self.log_handler.close()
        if self.trust_attempted:
            results = [
                subprocess.run(["/usr/bin/security", "remove-trusted-cert", str(self.cert)], capture_output=True),
                subprocess.run(["/usr/bin/security", "delete-certificate", "-Z", self.fingerprint,
                                str(self.keychain)], capture_output=True),
            ]
            # 44 means the exact item was not present, e.g. authorization failed before importing.
            if any(result.returncode not in (0, 44) for result in results):
                # Preserve the exact certificate for manual recovery rather than losing its identity.
                recovery = Path(self.temporary.name).parent / "certificate-cleanup-required.pem"
                shutil.copyfile(self.cert, recovery)
                raise ProbeError(f"Certificate cleanup requires attention; exact SHA1: {self.fingerprint}")
            check = subprocess.run([
                "/usr/bin/security", "find-certificate", "-c", self.common_name, str(self.keychain),
            ], capture_output=True)
            if check.returncode != 44:
                shutil.copyfile(self.cert, Path(self.temporary.name).parent / "certificate-cleanup-required.pem")
                raise ProbeError(f"Cannot verify certificate removal; exact SHA1: {self.fingerprint}")
            self.trust_removed = True
        if self.thread.is_alive():
            raise ProbeError("HTTP/2 server did not shut down")
        if self.temporary is not None:
            self.temporary.cleanup()


def align_frames(samples):
    """Match short windows so baseline drift cannot smear a whole-run alignment."""
    if not samples:
        return []
    images = [{
        name: base64.b64decode(row[name]["fingerprint"])
        for name in ("baseline", "candidate") if row.get(name, {}).get("fingerprint")
    } for row in samples]
    matches = []
    end_time = samples[-1]["t"]
    for start in range(10, int(end_time), 30):
        end = min(start + 30, end_time)
        if end - start < 15:
            continue
        curve = []
        for shift in range(-120, 121):
            differences, delays = [], []
            for i, row in enumerate(samples):
                j = i + shift
                if not start <= row["t"] < end or not 0 <= j < len(samples) or samples[j]["t"] < 10:
                    continue
                a, b = images[i].get("baseline"), images[j].get("candidate")
                if a and b and len(a) == len(b):
                    differences.append(sum(abs(x - y) for x, y in zip(a, b)) / len(a))
                    delays.append(row["t"] - samples[j]["t"])
            if len(differences) >= 40:
                curve.append((statistics.median(differences), shift, statistics.median(delays), len(delays)))
        if not curve:
            continue
        best = min(curve)
        alternatives = [p for p in curve if abs(p[1] - best[1]) >= 4]
        if (abs(best[1]) == 120 or best[0] > 15 or not alternatives
                or min(alternatives)[0] < best[0] + 2):
            continue
        dates = [
            row["baseline"]["program_date_age"] - row["candidate"]["program_date_age"]
            for row in samples if start <= row["t"] < end
            and "program_date_age" in row.get("baseline", {}) and "program_date_age" in row.get("candidate", {})
        ]
        matches.append({
            "window_seconds": [start, end], "candidate_lead_seconds_estimate": best[2],
            "median_luma_difference": best[0], "matched_samples": best[3],
            "next_distinct_match_difference": min(alternatives)[0],
            "program_date_lead_seconds": statistics.median(dates) if dates else None,
        })
    return matches


def summarize(samples, origin):
    report = {"transport": "resource-loader via loopback HTTP" if origin.resource_loader else "loopback HTTPS/HTTP2",
              "source_format": origin.source_format,
              "origin": dict(origin.stats), "error": origin.error, "players": {}}
    for name in ("baseline", "candidate"):
        rows = [row[name] for row in samples if name in row]
        steady = rows[40:]
        frames = [row for row in rows if "fingerprint" in row]
        coverage = sum("fingerprint" in row for row in steady) / max(1, len(steady))
        frozen = sum(
            abs(current.get("clock", 0) - previous.get("clock", 0)) < 0.01
            for previous, current in zip(steady, steady[1:])
        ) / max(1, len(steady) - 1)
        report["players"][name] = {
            "first_frame_seconds": next((row["t"] for row in samples if "fingerprint" in row.get(name, {})), None),
            "rendered_samples": len(frames),
            "waiting_sample_fraction": sum(row["state"] == "waiting" for row in steady) / max(1, len(steady)),
            "paused_sample_fraction": sum(row["state"] == "paused" for row in steady) / max(1, len(steady)),
            "stationary_playhead_fraction": frozen,
            "steady_decoded_frame_fraction": coverage,
            "median_buffer_seconds": statistics.median([row["buffer"] for row in steady if "buffer" in row]) if any("buffer" in row for row in steady) else None,
            "errors": [row["error"] for row in rows if "error" in row][:3],
            "error_comments": next((row["error_comments"] for row in rows if row.get("error_comments")), []),
            "configured_live_offsets": sorted({row["configured_live_offset"] for row in rows if "configured_live_offset" in row}),
            "recommended_live_offsets": sorted({row["recommended_live_offset"] for row in rows if "recommended_live_offset" in row}),
            "median_program_date_age": statistics.median([row["program_date_age"] for row in steady if "program_date_age" in row]) if any("program_date_age" in row for row in steady) else None,
        }
    report["partial_delivery_observed"] = origin.stats["parts_requested"] > 0
    report["sustained_partial_delivery_observed"] = (
        origin.stats["steady_parts_served"] >= 20 and len(origin.stats["part_windows"]) >= 3)
    if origin.direct_media and samples:
        native = samples[-1].get("candidate", {})
        report["direct_cdn_metrics"] = {key: value for key, value in native.items() if key.startswith("metric_")}
        report["partial_delivery_observed"] = native.get("metric_part_requests", 0) > 0
        report["sustained_partial_delivery_observed"] = (
            native.get("metric_part_requests", 0) >= 20
            and native.get("metric_range_requests", 0) >= 20
            and len([key for key in native.get("metric_part_windows", {}) if int(key) >= 1]) >= 3)
    report["native_candidate_playback_verified"] = (
        not origin.error and (origin.resource_loader or origin.stats["http2_requests"] > 0)
        and report["players"]["candidate"]["steady_decoded_frame_fraction"] >= 0.8
        and report["players"]["candidate"]["rendered_samples"] >= 40
        and not report["players"]["candidate"]["errors"]
    )
    report["comparison_valid"] = (
        report["native_candidate_playback_verified"]
        and report["players"]["baseline"]["steady_decoded_frame_fraction"] >= 0.8
        and not report["players"]["baseline"]["errors"]
    )
    alignments = align_frames(samples) if report["comparison_valid"] else []
    report["frame_alignment_windows"] = alignments
    report["latency_improvement_observed"] = (
        report["comparison_valid"] and report["sustained_partial_delivery_observed"]
        and len(alignments) >= 2 and all(match["candidate_lead_seconds_estimate"] >= 1 for match in alignments)
        and report["players"]["candidate"]["steady_decoded_frame_fraction"] >= 0.99
        and report["players"]["candidate"]["stationary_playhead_fraction"] <= 0.005
    )
    report["success"] = report["latency_improvement_observed"]
    return report


def run(args):
    args.output.mkdir(parents=True, exist_ok=False)
    origin = Origin()
    origin.resource_loader = args.resource_loader
    origin.direct_media = args.direct_media
    server, remux, player = None, None, None
    threads, samples = [], []
    try:
        bitrate, url = resolve(args.channel)
        print(f"Resolved common H.264 rendition: {bitrate / 1_000_000:.2f} Mbps", flush=True)
        with fetch(url) as response:
            source = response.read().decode()
        media_entries(source, url)
        map_match = re.search(r'(?m)^#EXT-X-MAP:URI="([^"]+)"$', source)
        with (args.output / "remux.log").open("wb") as log:
            if map_match:
                origin.part_target = args.cmaf_part_target
                workers = [(ingest_cmaf, (origin, url, urljoin(url, map_match[1])))]
            else:
                if args.direct_media:
                    raise ProbeError("Direct byte-range mode requires original source CMAF")
                if not shutil.which("ffmpeg"):
                    raise ProbeError("TS experiments require an explicitly installed ffmpeg")
                remux = subprocess.Popen([
                    "ffmpeg", "-hide_banner", "-loglevel", "warning", "-nostdin",
                    "-probesize", "1000000", "-analyzeduration", "1000000",
                    "-i", "pipe:0", "-map", "0:v:0", "-map", "0:a:0",
                    "-c", "copy", "-bsf:a", "aac_adtstoasc",
                    "-movflags", "empty_moov+default_base_moof+frag_keyframe",
                    "-frag_duration", "300000", "-flush_packets", "1", "-f", "mp4", "pipe:1",
                ], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=log)
                workers = [(ingest, (origin, url, remux)), (package, (origin, remux))]
            for function, params in workers:
                thread = threading.Thread(target=function, args=params, daemon=True)
                thread.start()
                threads.append(thread)
            with origin.condition:
                ready = origin.condition.wait_for(lambda: origin.ready() or origin.error, timeout=30)
            if not ready or origin.error:
                raise ProbeError(origin.error or "Origin startup timed out")
            with origin.condition:
                initial_playlist = origin.playlist()
            if args.direct_media:
                initial_playlist = re.sub(rb'https://[^",\s]+', b'https://redacted.invalid/media', initial_playlist)
            (args.output / "initial-playlist.m3u8").write_bytes(initial_playlist)
            server = Transport(origin, args.output, use_tls=not args.resource_loader)
            server.check_ready()
            if args.trust_localhost:
                server.trust_for_native()
            print(f"Comparing native AVPlayers for {args.seconds}s; media stays in memory.", flush=True)
            with (args.output / "player.log").open("wb") as log:
                origin.player_started_at = time.monotonic()
                player = subprocess.Popen([str(args.player)], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=log)
                config = json.dumps({
                    "baseline": url, "candidate": server.url,
                    "headers": HEADERS, "seconds": args.seconds,
                    "candidateLiveOffset": args.candidate_live_offset,
                    "candidateForwardBuffer": args.candidate_forward_buffer,
                    "candidateResourceLoader": args.resource_loader,
                })
                try:
                    output, _ = player.communicate(config.encode(), timeout=args.seconds + 15)
                except subprocess.TimeoutExpired:
                    raise ProbeError("Native player exceeded its bounded runtime") from None
                (args.output / "samples.jsonl").write_bytes(output)
                for line in output.splitlines():
                    samples.append(json.loads(line))
                if player.returncode:
                    raise ProbeError("Native player failed; see player.log")
            if origin.error:
                raise ProbeError(origin.error)
    except KeyboardInterrupt:
        origin.error = "Experiment cancelled"
    except (ProbeError, OSError, ValueError, subprocess.CalledProcessError, ModuleNotFoundError) as error:
        origin.error = str(error) if isinstance(error, ProbeError) else f"Experiment failed: {type(error).__name__}"
    finally:
        origin.stopped.set()
        with origin.condition:
            origin.condition.notify_all()
        for process in (player, remux):
            if process is not None:
                if process.poll() is None:
                    process.terminate()
                    try:
                        process.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        process.kill()
                        process.wait()
                for pipe in (process.stdin, process.stdout):
                    if pipe and not pipe.closed:
                        pipe.close()
        if server is not None:
            try:
                server.close()
            except ProbeError as error:
                origin.error = str(error)
        for thread in threads:
            thread.join(timeout=9)
        report = summarize(samples, origin)
        report["temporary_certificate_removed"] = server.trust_removed if server and server.trust_attempted else None
        (args.output / "report.json").write_text(json.dumps(report, indent=2) + "\n")
        print(json.dumps(report, indent=2))
    return 0 if report["success"] else 1


if __name__ == "__main__":
    def interrupt(_signum, _frame):
        raise KeyboardInterrupt
    signal.signal(signal.SIGTERM, interrupt)
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("channel")
    parser.add_argument("--player", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True, help="New evidence directory; never overwritten")
    parser.add_argument("--seconds", type=int, default=90)
    parser.add_argument("--trust-localhost", action="store_true",
                        help="Explicitly consent to temporary login-keychain trust; removed after the run")
    parser.add_argument("--candidate-live-offset", type=float,
                        help="Apply a native live offset after the candidate becomes ready, then seek to live once")
    parser.add_argument("--cmaf-part-target", type=float, default=0.45,
                        help="Declared part duration for grouping untouched source CMAF fragments")
    parser.add_argument("--candidate-forward-buffer", type=float, default=1,
                        help="Candidate native buffer preference in seconds (0 lets AVPlayer choose)")
    parser.add_argument("--resource-loader", action="store_true",
                        help="Experimental custom-scheme AVAssetResourceLoader path; no certificate trust")
    parser.add_argument("--direct-media", action="store_true",
                        help="Experimental original-CDN byte-range parts instead of resource-loader media bytes")
    arguments = parser.parse_args()
    if not re.fullmatch(r"[a-z0-9_]{1,25}", arguments.channel) or not 30 <= arguments.seconds <= 300:
        parser.error("Use a Twitch login and a duration between 30 and 300 seconds")
    if arguments.candidate_live_offset is not None and not 0.5 <= arguments.candidate_live_offset <= 30:
        parser.error("Candidate live offset must be between 0.5 and 30 seconds")
    if not 0.3 <= arguments.cmaf_part_target <= 1:
        parser.error("CMAF part target must be between 0.3 and 1 second")
    if arguments.candidate_forward_buffer is not None and not 0 <= arguments.candidate_forward_buffer <= 30:
        parser.error("Candidate forward buffer must be between 0 and 30 seconds")
    if arguments.resource_loader and arguments.trust_localhost:
        parser.error("Resource-loader mode must not modify certificate trust")
    if arguments.direct_media and not arguments.resource_loader:
        parser.error("Direct media mode currently requires the resource-loader experiment")
    try:
        raise SystemExit(run(arguments))
    except (ProbeError, FileExistsError) as error:
        parser.exit(1, str(error) + "\n")
