#!/usr/bin/env python3
"""Pull and summarize Strozz playback diagnostics without external dependencies."""

from __future__ import annotations

import argparse
import json
import math
import os
import re
import shutil
import subprocess
import sys
import uuid
from collections import Counter, defaultdict
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Iterable


SCHEMA_VERSION = 1
TOOL_SCHEMA_VERSION = 1
DEFAULT_BUNDLE = "com.thatcube.Strozz"
REMOTE_SOURCE = "Library/Caches/PlaybackDiagnostics"
KINDS = {"event", "sample", "summary", "access_log", "error_log"}
LEVELS = {"debug", "info", "warning", "error"}
CUMULATIVE_COUNTERS = {
    "avplayer_stalls",
    "dropped_video_frames",
    "download_overdue",
    "bytes_transferred",
    "media_requests",
    "proxy_requests",
    "proxy_failed_requests",
    "proxy_cancelled_requests",
    "proxy_media_refreshes",
}
AVPLAYER_COUNTERS = {
    "avplayer_stalls",
    "dropped_video_frames",
    "download_overdue",
    "bytes_transferred",
    "media_requests",
}
DROP_COUNTERS = {"telemetry_records_dropped", "dropped_records"}
INTERVENTION_EVENTS = {
    "recovery_started",
    "playback_nudged",
    "live_edge_resync_started",
    "stability_mode_entered",
}
FILE_PATTERN = re.compile(r"^playback-(?P<session>.+)-(?P<part>\d+)\.jsonl$")
INCIDENT_PATTERN = re.compile(r"^incident-(?P<session>[0-9a-fA-F-]{36})\.json$")
INCIDENT_RECORD_KEYS = (
    "sessionStarted", "firstIncident", "firstFailure", "latestIncident",
    "latestFailure", "latestRecovery", "latestSample", "sessionEnded",
)
TIMESTAMP_PATTERN = re.compile(
    r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d+(?:Z|[+-]\d{2}:\d{2})$"
)


class DiagnosticsError(Exception):
    """A user-facing diagnostics input or command error."""


def parse_timestamp(value: Any, context: str) -> datetime:
    if not isinstance(value, str):
        raise DiagnosticsError(f"{context}: timestamp must be an ISO-8601 string")
    if not TIMESTAMP_PATTERN.fullmatch(value):
        raise DiagnosticsError(
            f"{context}: timestamp must include fractional seconds and a timezone"
        )
    try:
        return datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError as error:
        raise DiagnosticsError(f"{context}: invalid ISO-8601 timestamp {value!r}") from error


def require_mapping(
    record: dict[str, Any], key: str, value_type: type, context: str
) -> dict[str, Any]:
    value = record.get(key)
    if not isinstance(value, dict):
        raise DiagnosticsError(f"{context}: {key} must be an object")
    for item_key, item_value in value.items():
        if not isinstance(item_key, str) or not isinstance(item_value, value_type):
            raise DiagnosticsError(
                f"{context}: {key} must contain string keys and {value_type.__name__} values"
            )
    return value


def validate_record(value: Any, context: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise DiagnosticsError(f"{context}: record must be a JSON object")
    required = {
        "schemaVersion",
        "timestamp",
        "uptimeSeconds",
        "sessionID",
        "sequence",
        "kind",
        "name",
        "level",
        "channel",
        "playbackMode",
        "attributes",
        "metrics",
        "counters",
        "flags",
    }
    missing = sorted(required - value.keys())
    if missing:
        raise DiagnosticsError(f"{context}: missing required fields: {', '.join(missing)}")
    if value["schemaVersion"] != SCHEMA_VERSION:
        raise DiagnosticsError(
            f"{context}: unsupported schemaVersion {value['schemaVersion']!r}; "
            f"expected {SCHEMA_VERSION}"
        )
    parse_timestamp(value["timestamp"], context)
    if (
        isinstance(value["uptimeSeconds"], bool)
        or not isinstance(value["uptimeSeconds"], (int, float))
        or not math.isfinite(value["uptimeSeconds"])
    ):
        raise DiagnosticsError(f"{context}: uptimeSeconds must be finite")
    if (
        isinstance(value["sequence"], bool)
        or not isinstance(value["sequence"], int)
        or value["sequence"] < 1
    ):
        raise DiagnosticsError(f"{context}: sequence must be a positive integer")
    for key in ("sessionID", "kind", "name", "level", "channel", "playbackMode"):
        if not isinstance(value[key], str):
            raise DiagnosticsError(f"{context}: {key} must be a string")
    try:
        uuid.UUID(value["sessionID"])
    except ValueError as error:
        raise DiagnosticsError(f"{context}: sessionID must be a UUID") from error
    if value["kind"] not in KINDS:
        raise DiagnosticsError(f"{context}: unsupported record kind {value['kind']!r}")
    if value["level"] not in LEVELS:
        raise DiagnosticsError(f"{context}: unsupported level {value['level']!r}")
    if value["playbackMode"] not in {"live", "vod"}:
        raise DiagnosticsError(
            f"{context}: unsupported playbackMode {value['playbackMode']!r}"
        )
    require_mapping(value, "attributes", str, context)
    counters = require_mapping(value, "counters", int, context)
    flags = require_mapping(value, "flags", bool, context)
    for counter_value in counters.values():
        if isinstance(counter_value, bool):
            raise DiagnosticsError(f"{context}: counters must contain integer values")
    for flag_value in flags.values():
        if not isinstance(flag_value, bool):
            raise DiagnosticsError(f"{context}: flags must contain boolean values")
    metrics = value["metrics"]
    if not isinstance(metrics, dict):
        raise DiagnosticsError(f"{context}: metrics must be an object")
    for metric_key, metric_value in metrics.items():
        if (
            not isinstance(metric_key, str)
            or isinstance(metric_value, bool)
            or not isinstance(metric_value, (int, float))
            or not math.isfinite(metric_value)
        ):
            raise DiagnosticsError(
                f"{context}: metrics must contain string keys and finite numeric values"
            )
    return value


def read_jsonl(path: Path) -> tuple[list[dict[str, Any]], list[str]]:
    try:
        data = path.read_bytes()
    except OSError as error:
        raise DiagnosticsError(f"cannot read {path}: {error}") from error
    records: list[dict[str, Any]] = []
    warnings: list[str] = []
    lines = data.splitlines(keepends=True)
    for index, raw_line in enumerate(lines, start=1):
        has_terminator = raw_line.endswith((b"\n", b"\r"))
        payload = raw_line.rstrip(b"\r\n")
        context = f"{path}:{index}"
        if not payload:
            raise DiagnosticsError(f"{context}: blank JSONL line")
        try:
            decoded = payload.decode("utf-8")
            value = json.loads(decoded)
        except (UnicodeDecodeError, json.JSONDecodeError) as error:
            if index == len(lines) and not has_terminator:
                warnings.append(
                    f"{context}: ignored incomplete final JSON line copied while logging was active"
                )
                break
            raise DiagnosticsError(f"{context}: malformed completed JSON line: {error}") from error
        records.append(validate_record(value, context))
    return records, warnings


def read_manifest(path: Path) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as error:
        raise DiagnosticsError(f"cannot read manifest {path}: {error}") from error
    if not isinstance(value, dict):
        raise DiagnosticsError(f"{path}: manifest must be a JSON object")
    required = {"schemaVersion", "sessionID", "fileName", "channel", "playbackMode", "startedAt"}
    missing = sorted(required - value.keys())
    if missing:
        raise DiagnosticsError(f"{path}: manifest missing fields: {', '.join(missing)}")
    if value["schemaVersion"] != SCHEMA_VERSION:
        raise DiagnosticsError(
            f"{path}: unsupported manifest schemaVersion {value['schemaVersion']!r}"
        )
    for key in ("sessionID", "fileName", "channel", "playbackMode", "startedAt"):
        if not isinstance(value[key], str):
            raise DiagnosticsError(f"{path}: manifest {key} must be a string")
    try:
        uuid.UUID(value["sessionID"])
    except ValueError as error:
        raise DiagnosticsError(f"{path}: manifest sessionID must be a UUID") from error
    parse_timestamp(value["startedAt"], str(path))
    if "endedAt" in value:
        if not isinstance(value["endedAt"], str):
            raise DiagnosticsError(f"{path}: manifest endedAt must be a string")
        parse_timestamp(value["endedAt"], str(path))
    return value


def discover_files(source: Path) -> tuple[list[Path], list[tuple[Path, dict[str, Any]]]]:
    if not source.exists():
        raise DiagnosticsError(f"input does not exist: {source}")
    if source.is_file():
        if source.suffix != ".jsonl" and not INCIDENT_PATTERN.fullmatch(source.name):
            raise DiagnosticsError("file input must be a .jsonl playback log or incident-UUID.json checkpoint")
        return [source], []
    files = sorted(source.rglob("playback-*.jsonl")) + sorted(source.rglob("incident-*.json"))
    manifests = [(path, read_manifest(path)) for path in sorted(source.rglob("latest-session.json"))]
    if not files:
        raise DiagnosticsError(f"no playback logs or incident checkpoints found under {source}")
    return files, manifests


def session_from_filename(path: Path) -> str | None:
    match = FILE_PATTERN.match(path.name) or INCIDENT_PATTERN.fullmatch(path.name)
    return match.group("session") if match else None


def read_incident(path: Path) -> dict[str, Any]:
    try:
        if path.stat().st_size > 256 * 1024:
            raise DiagnosticsError(f"{path}: incident checkpoint exceeds size limit")
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as error:
        raise DiagnosticsError(f"cannot read incident checkpoint {path}: {error}") from error
    if not isinstance(value, dict) or value.get("schemaVersion") != 1:
        raise DiagnosticsError(f"{path}: unsupported incident checkpoint")
    session_id = value.get("sessionID")
    if session_id != session_from_filename(path) or not isinstance(session_id, str):
        raise DiagnosticsError(f"{path}: incident session does not match its filename")
    history = value.get("precedingEvents", [])
    if not isinstance(history, list):
        raise DiagnosticsError(f"{path}: precedingEvents must be an array")
    if value.get("firstIncident") is None:
        raise DiagnosticsError(f"{path}: missing firstIncident")
    records = [value[key] for key in INCIDENT_RECORD_KEYS if value.get(key) is not None] + history
    by_sequence = {}
    for record in records:
        validate_record(record, str(path))
        if record["sessionID"] != session_id:
            raise DiagnosticsError(f"{path}: checkpoint mixes stream sessions")
        previous = by_sequence.get(record["sequence"])
        if previous is not None and previous != record:
            raise DiagnosticsError(f"{path}: conflicting checkpoint records share a sequence")
        by_sequence[record["sequence"]] = record
    return value


def load_records(
    source: Path, requested_session: str | None, all_sessions: bool
) -> tuple[
    dict[str, list[dict[str, Any]]],
    dict[str, dict[str, Any]],
    dict[str, list[str]],
    list[str],
    str,
    dict[str, dict[str, Any]],
]:
    files, manifest_entries = discover_files(source)
    manifests = {manifest["sessionID"]: manifest for _, manifest in manifest_entries}
    selection = "all"
    session_id = requested_session
    if requested_session:
        try:
            session_id = str(uuid.UUID(requested_session))
        except ValueError as error:
            raise DiagnosticsError("--session must be a UUID") from error
        selection = "explicit"
    elif not all_sessions and manifest_entries:
        _, latest = max(
            manifest_entries,
            key=lambda entry: (
                parse_timestamp(entry[1]["startedAt"], str(entry[0])),
                str(entry[0]),
            ),
        )
        session_id = latest["sessionID"]
        selection = "latest-session.json"

    candidate_files = files
    if session_id and source.is_dir():
        named = [path for path in files if session_from_filename(path) == session_id]
        if named:
            candidate_files = named

    loaded: list[dict[str, Any]] = []
    incidents: dict[str, dict[str, Any]] = {}
    warnings_by_session: dict[str, list[str]] = defaultdict(list)
    global_warnings: list[str] = []
    for path in candidate_files:
        if INCIDENT_PATTERN.fullmatch(path.name):
            checkpoint = read_incident(path)
            session = checkpoint["sessionID"]
            if session in incidents and incidents[session] != checkpoint:
                raise DiagnosticsError(f"{path}: conflicting checkpoints for session {session}")
            incidents[session] = checkpoint
            continue
        records, file_warnings = read_jsonl(path)
        loaded.extend(records)
        warning_session = session_from_filename(path)
        if warning_session is None and records:
            record_sessions = {record["sessionID"] for record in records}
            if len(record_sessions) == 1:
                warning_session = record_sessions.pop()
        if warning_session is None:
            global_warnings.extend(file_warnings)
        else:
            warnings_by_session[warning_session].extend(file_warnings)
    raw_sessions = {record["sessionID"] for record in loaded}
    for session, checkpoint in incidents.items():
        if session not in raw_sessions:
            # A small failure-only pull is useful, but not a continuous playback trace.
            records = [checkpoint[key] for key in INCIDENT_RECORD_KEYS if checkpoint.get(key) is not None]
            records += checkpoint.get("precedingEvents", [])
            unique = {record["sequence"]: record for record in records}
            loaded.extend(unique.values())
            warnings_by_session[session].append(
                "Only a sparse incident checkpoint is available; counts and timing are not a complete session."
            )
    if not loaded:
        raise DiagnosticsError("no complete playback records found")

    if session_id is None and not all_sessions:
        newest = max(
            loaded,
            key=lambda record: (
                parse_timestamp(record["timestamp"], "record"),
                record["uptimeSeconds"],
                record["sequence"],
            ),
        )
        session_id = newest["sessionID"]
        selection = "newest-record"

    grouped: dict[str, list[dict[str, Any]]] = defaultdict(list)
    for record in loaded:
        if all_sessions or record["sessionID"] == session_id:
            grouped[record["sessionID"]].append(record)
    if session_id and session_id not in grouped:
        raise DiagnosticsError(f"session {session_id} was not found in {source}")
    return dict(grouped), manifests, dict(warnings_by_session), global_warnings, selection, incidents


def percentile(values: Iterable[float], fraction: float) -> float:
    ordered = sorted(values)
    if len(ordered) == 1:
        return float(ordered[0])
    position = (len(ordered) - 1) * fraction
    lower = math.floor(position)
    upper = math.ceil(position)
    if lower == upper:
        return float(ordered[lower])
    return float(ordered[lower] + (ordered[upper] - ordered[lower]) * (position - lower))


def distribution(values: list[float]) -> dict[str, float | int]:
    return {
        "count": len(values),
        "min": min(values),
        "p50": percentile(values, 0.50),
        "p95": percentile(values, 0.95),
        "max": max(values),
    }


def counter_boundary(record: dict[str, Any], counter: str) -> tuple[str, ...]:
    attributes = record["attributes"]
    item = attributes.get("item_id", "unknown-item")
    if counter in AVPLAYER_COUNTERS:
        return item, attributes.get("access_entry", "unknown-access-entry")
    # The proxy survives item/quality replacements; it resets only per session.
    return ("session",)


def summarize_counters(
    records: list[dict[str, Any]], warnings: list[str]
) -> tuple[dict[str, int], dict[str, int]]:
    previous: dict[tuple[str, tuple[str, ...]], int] = {}
    totals: Counter[str] = Counter()
    latest: dict[str, int] = {}
    has_start = any(record["name"] == "session_started" for record in records)
    seen_names: set[str] = set()
    created_items: set[str] = set()
    for record in records:
        if record["name"] in {"item_changed", "player_item_created"}:
            created_items.add(record["attributes"].get("item_id", "unknown-item"))
        if record["kind"] == "summary" or record["name"] == "counter_increased":
            continue
        for name, value in record["counters"].items():
            latest[name] = value
            if name in DROP_COUNTERS:
                totals[name] += max(0, value)
                continue
            if name not in CUMULATIVE_COUNTERS:
                continue
            key = (name, counter_boundary(record, name))
            if key not in previous:
                fresh_item = (
                    name in AVPLAYER_COUNTERS
                    and record["attributes"].get("item_id") in created_items
                )
                # A retained tail may begin hours into a cumulative entry. Its
                # first value is a baseline, not a delta inside this log window.
                totals[name] += max(0, value) if has_start or name in seen_names or fresh_item else 0
            elif value >= previous[key]:
                totals[name] += value - previous[key]
            else:
                totals[name] += max(0, value)
                warnings.append(
                    f"counter {name} reset inside boundary {'/'.join(key[1])}; "
                    "the post-reset value was counted from zero"
                )
            previous[key] = value
            seen_names.add(name)
    return dict(sorted(totals.items())), dict(sorted(latest.items()))


def timeline_entry(record: dict[str, Any]) -> dict[str, Any]:
    entry: dict[str, Any] = {
        "sequence": record["sequence"],
        "timestamp": record["timestamp"],
        "uptime_seconds": record["uptimeSeconds"],
        "kind": record["kind"],
        "name": record["name"],
        "level": record["level"],
    }
    for source_key, output_key in (
        ("attributes", "attributes"),
        ("metrics", "metrics"),
        ("counters", "counters"),
        ("flags", "flags"),
    ):
        if record[source_key]:
            entry[output_key] = record[source_key]
    return entry


def error_record(record: dict[str, Any]) -> bool:
    return (
        record["kind"] == "error_log"
        or record["level"] == "error"
        or record["name"].endswith("_failed")
    )


def summarize_session(
    session_id: str,
    raw_records: list[dict[str, Any]],
    manifest: dict[str, Any] | None,
    inherited_warnings: list[str],
) -> dict[str, Any]:
    warnings = list(inherited_warnings)
    by_sequence: dict[int, dict[str, Any]] = {}
    for record in sorted(
        raw_records,
        key=lambda item: (
            item["sequence"],
            parse_timestamp(item["timestamp"], "record"),
        ),
    ):
        existing = by_sequence.get(record["sequence"])
        if existing is not None:
            if existing != record:
                raise DiagnosticsError(
                    f"session {session_id}: conflicting records share sequence {record['sequence']}"
                )
            warnings.append(
                f"session {session_id}: duplicate sequence {record['sequence']} was ignored"
            )
            continue
        by_sequence[record["sequence"]] = record
    records = list(by_sequence.values())
    sequences = list(by_sequence)
    missing_ranges: list[dict[str, int]] = []
    if sequences[0] > 1:
        missing_ranges.append({"after": 0, "before": sequences[0], "missing": sequences[0] - 1})
    for previous, current in zip(sequences, sequences[1:]):
        if current > previous + 1:
            missing_ranges.append(
                {"after": previous, "before": current, "missing": current - previous - 1}
            )
    if missing_ranges:
        warnings.append(
            "record sequence gaps indicate retained rotation, dropped writes, or an incomplete copy"
        )

    event_counts = Counter(
        record["name"] for record in records if record["kind"] in {"event", "error_log"}
    )
    kind_counts = Counter(record["kind"] for record in records)
    metrics: dict[str, list[float]] = defaultdict(list)
    metric_records = [record for record in records if record["kind"] == "sample"]
    if not metric_records:
        metric_records = [record for record in records if record["kind"] == "access_log"]
    for record in metric_records:
        if record["kind"] in {"sample", "access_log"}:
            for name, value in record["metrics"].items():
                metrics[name].append(float(value))
    metric_stats = {name: distribution(values) for name, values in sorted(metrics.items())}
    diagnostic_metrics: dict[str, dict[str, list[float]]] = defaultdict(lambda: defaultdict(list))
    diagnostic_names = {
        "native_hls_delivery_timing", "native_hls_request", "native_hls_segment_timing",
        "playback_scheduler_sample", "playback_scheduler_delay", "playback_main_operation_slow",
    }
    for record in records:
        if record["kind"] != "event" or record["name"] not in diagnostic_names:
            continue
        attributes = record["attributes"]
        stage = attributes.get("stage") or attributes.get("operation") or attributes.get("resource_kind")
        group = record["name"] + (f"/{stage}" if stage else "")
        if attributes.get("requester"):
            group += "/" + attributes["requester"]
        completed = attributes.get("body_complete", attributes.get("completed"))
        if completed in {"true", "false"}:
            group += "/complete" if completed == "true" else "/partial"
        for name, value in record["metrics"].items():
            if not name.endswith("_uptime_seconds"):
                diagnostic_metrics[group][name].append(float(value))
    diagnostic_stats = {
        group: {name: distribution(values) for name, values in sorted(fields.items())}
        for group, fields in sorted(diagnostic_metrics.items())
    }
    counter_totals, counter_latest = summarize_counters(records, warnings)
    proxy_last_failure: dict[str, float | int] = {}
    for record in reversed(records):
        if "status" not in proxy_last_failure and "proxy_last_failure_status" in record["counters"]:
            proxy_last_failure["status"] = record["counters"]["proxy_last_failure_status"]
        if (
            "error_code" not in proxy_last_failure
            and "proxy_last_failure_error_code" in record["counters"]
        ):
            proxy_last_failure["error_code"] = record["counters"][
                "proxy_last_failure_error_code"
            ]
        if (
            "uptime_seconds" not in proxy_last_failure
            and "proxy_last_failure_uptime_seconds" in record["metrics"]
        ):
            proxy_last_failure["uptime_seconds"] = record["metrics"][
                "proxy_last_failure_uptime_seconds"
            ]
        if len(proxy_last_failure) == 3:
            break

    session_end = next(
        (record for record in reversed(records) if record["name"] == "session_ended"), None
    )
    has_session_start = any(record["name"] == "session_started" for record in records)
    manifest_ended = manifest.get("endedAt") if manifest else None
    active = session_end is None and manifest_ended is None
    if session_end and isinstance(session_end["metrics"].get("duration_seconds"), (int, float)):
        duration = float(session_end["metrics"]["duration_seconds"])
        duration_source = "session_ended"
    else:
        duration = max(0.0, records[-1]["uptimeSeconds"] - records[0]["uptimeSeconds"])
        duration_source = "observed_records"
    if active:
        warnings.append(
            "session appears active or did not close cleanly; the final state and tail may be incomplete"
        )
    if not has_session_start:
        warnings.append("session_started is missing, likely because older rotated files were reclaimed")
    if not active and session_end is None:
        warnings.append(
            "the manifest marks the session ended, but session_ended is not retained; "
            "duration and final counters may be incomplete"
        )

    dropped_records = sum(counter_totals.get(name, 0) for name in DROP_COUNTERS)
    if dropped_records:
        warnings.append(
            f"the app reported {dropped_records} dropped telemetry record(s); evidence is incomplete"
        )
    skipped_native_logs = Counter()
    for record in records:
        if record["name"] == "log_entries_skipped":
            for name in ("access_entries", "error_entries"):
                skipped_native_logs[name] += max(0, record["counters"].get(name, 0))
    if skipped_native_logs:
        details = ", ".join(
            f"{name}={value}" for name, value in sorted(skipped_native_logs.items())
        )
        warnings.append(
            f"bounded native-log collection skipped backlog entries ({details}); "
            "access/error-log evidence is incomplete"
        )

    stalls = [
        timeline_entry(record)
        for record in records
        if record["name"] in {"stall_started", "stall_ended"}
    ]
    stream_errors = [timeline_entry(record) for record in records if error_record(record)]
    timeline = [
        timeline_entry(record)
        for record in records
        if record["kind"] != "sample"
        and record["name"] not in {"stall_started", "stall_ended"}
        and not error_record(record)
    ]
    stall_starts = [
        record for record in records if record["name"] == "stall_started"
    ]
    stall_ends = [record for record in records if record["name"] == "stall_ended"]
    stalls_by_kind = Counter(
        record["attributes"].get("stall_kind", "unknown") for record in stall_starts
    )
    stall_outcomes = Counter(
        record["attributes"].get("outcome", "unknown") for record in stall_ends
    )
    total_stall_duration = sum(
        min(
            max(0.0, float(record["metrics"].get("duration_seconds", 0))),
            max(0.0, record["uptimeSeconds"] - records[0]["uptimeSeconds"]),
        )
        for record in stall_ends
    )
    intervention_count = sum(event_counts[name] for name in INTERVENTION_EVENTS)
    thermal_states = sorted(
        {
            record["attributes"]["thermal_state"]
            for record in records
            if record["attributes"].get("thermal_state") in {"serious", "critical"}
        }
    )

    rates: dict[str, float] = {}
    rate_window = max(0.0, records[-1]["uptimeSeconds"] - records[0]["uptimeSeconds"])
    if rate_window > 0:
        hours = rate_window / 3600
        rates["stall_episodes_per_hour"] = len(stall_starts) / hours
        rates["stream_errors_per_hour"] = len(stream_errors) / hours
        rates["controller_interventions_per_hour"] = intervention_count / hours
        for name, value in counter_totals.items():
            if name in CUMULATIVE_COUNTERS:
                rates[f"{name}_per_hour"] = value / hours

    hypotheses: list[str] = []
    stall_notifications = event_counts["avplayer_stall_notification"]
    native_stalls = counter_totals.get("avplayer_stalls", 0)
    if stall_notifications or native_stalls:
        hypotheses.append(
            f"AVPlayer reported {stall_notifications} stall notification(s) and "
            f"{native_stalls} cumulative-counter stall(s). These are separate observations "
            "of potentially overlapping interruptions, not an additive total. Short repeated "
            "hiccups can occur even when no clock-based stall episode reaches four seconds."
        )
    if stalls_by_kind["network_or_buffer"]:
        hypotheses.append(
            "Low-buffer/network-classified waits support a delivery or buffering hypothesis, "
            "but do not prove a network root cause."
        )
    if stalls_by_kind["healthy_buffer_wait"]:
        hypotheses.append(
            "Healthy-buffer waits occurred; buffered media was present, so delivery alone may "
            "not explain the interruption."
        )
    if stalls_by_kind["decode_freeze"] or stalls_by_kind["playhead_not_advancing"]:
        hypotheses.append(
            "Decode/playhead freezes occurred and support a render, decode, or player-state "
            "hypothesis rather than proving one."
        )
    if counter_totals.get("dropped_video_frames", 0) > 0:
        hypotheses.append(
            "Dropped video frames increased during the session; this supports decode/render "
            "pressure as a possibility, not a proven cause."
        )
    observed = metric_stats.get("observed_bitrate_bps")
    indicated = metric_stats.get("indicated_bitrate_bps")
    if observed and indicated and observed["p50"] < indicated["p50"]:
        hypotheses.append(
            "Median observed bitrate was below median indicated bitrate; the coarse cumulative "
            "access-log estimate supports throughput pressure as a possibility."
        )
    if thermal_states:
        hypotheses.append(
            f"Thermal state reached {', '.join(thermal_states)}; thermal pressure may have "
            "contributed but is not proof of causation."
        )
    if intervention_count:
        hypotheses.append(
            f"The playback controller recorded {intervention_count} recovery intervention "
            "event(s); their completion does not prove that rendered pictures recovered."
        )

    partial = bool(
        missing_ranges
        or dropped_records
        or skipped_native_logs
        or active
        or not has_session_start
        or session_end is None
        or inherited_warnings
    )
    return {
        "session_id": session_id,
        "channel": records[0]["channel"],
        "playback_mode": records[0]["playbackMode"],
        "started_at": records[0]["timestamp"],
        "ended_at": session_end["timestamp"] if session_end else manifest_ended,
        "active": active,
        "partial_evidence": partial,
        "duration_seconds": duration,
        "duration_source": duration_source,
        "rate_window_seconds": rate_window,
        "sequence": {
            "first": sequences[0],
            "last": sequences[-1],
            "gaps": missing_ranges,
        },
        "counts": {
            "records": len(records),
            "records_by_kind": dict(sorted(kind_counts.items())),
            "events_by_name": dict(sorted(event_counts.items())),
            "stall_episodes": len(stall_starts),
            "stall_notifications": stall_notifications,
            "stalls_by_kind": dict(sorted(stalls_by_kind.items())),
            "stall_outcomes": dict(sorted(stall_outcomes.items())),
            "stream_errors": len(stream_errors),
            "controller_interventions": intervention_count,
        },
        "rates": dict(sorted(rates.items())),
        "metric_distributions": metric_stats,
        "diagnostic_timing_groups": diagnostic_stats,
        "counter_deltas": counter_totals,
        "latest_counter_values": counter_latest,
        "skipped_native_log_entries": dict(sorted(skipped_native_logs.items())),
        "proxy_last_failure": proxy_last_failure,
        "total_stall_duration_seconds": total_stall_duration,
        "serious_thermal_states": thermal_states,
        "stalls": stalls,
        "stream_errors": stream_errors,
        "timeline": timeline,
        "hypotheses": hypotheses,
        "warnings": list(dict.fromkeys(warnings)),
        "interpretation_notes": [
            "Stalls are counted only from explicit stall_started events; loading, pause, seek, "
            "background, recovery, idle, offline, and terminal errors are not reclassified as stalls.",
            "Stall notifications and reset-aware AVPlayer stall-counter deltas are reported "
            "separately from clock-classified episodes. Zero episodes does not mean uninterrupted "
            "playback; repeated short hiccups can fall below the four-second clock threshold.",
            "A telemetry_records_dropped counter is attached to the next admitted record. "
            "Sequence gaps are additional evidence of missing records.",
            "Playlist/resource-loader timings are not upstream media-transfer timings. Native "
            "delivery diagnostics separate ingress wait, consumer queue delay and remux/publish wall time.",
            "Native events retain native_event_uptime_seconds from their producer. "
            "native_trace_retention_delay_seconds separates intentionally buffered/replayed events "
            "from the dispatch-to-main wait. "
            "main_actor_delivery_delay_seconds measures delayed logging, not network latency. "
            "A large main_queue_delay_seconds with a normal background probe interval supports "
            "a main-thread scheduling/long-running-operation hypothesis. A delayed background "
            "probe also can reflect wider scheduling pressure; neither proves a Wi-Fi/CDN failure. "
            "Missing diagnostic timing groups are not evidence that those stages were healthy.",
            "proxy_last_failure_status, proxy_last_failure_error_code, and "
            "proxy_last_failure_uptime_seconds retain the last proxy failure after later success; "
            "they do not describe the latest request unless a failure just occurred.",
            "AVPlayer access-log throughput values are coarse cumulative estimates, not "
            "instantaneous network tests.",
            "Rates use the retained record window, not the full session duration. Without "
            "session_started, initial cumulative values are baselines; deltas are lower bounds. "
            "Proxy counters span all items in a session. Metric distributions use periodic "
            "samples (access-log records only when no samples exist).",
            "first_clock_progress confirms clock movement. first_video_output_frame is currently "
            "native-Twitch-only, can be delayed by one watchdog interval, and confirms an observed "
            "pixel buffer rather than proof that a picture appeared on screen.",
            "recovery_completed outcome load_returned/load_failed/offline describes completion of "
            "the recovery task. Subsequent clock or frame progress is needed as evidence of health.",
            "seek_deadline_exceeded marks a 15-second pending seek. A later callback_completed "
            "confirms the target callback landed, not that a picture rendered.",
        ],
    }


def analyze(
    source: Path, requested_session: str | None = None, all_sessions: bool = False
) -> dict[str, Any]:
    grouped, manifests, warnings_by_session, global_warnings, selection, incidents = load_records(
        source, requested_session, all_sessions
    )
    capture = source / "capture-manifest.json" if source.is_dir() else source.parent / "capture-manifest.json"
    if capture.exists():
        try:
            collection = json.loads(capture.read_text(encoding="utf-8"))
            if collection.get("failed"):
                global_warnings.append("Device capture was incomplete; see capture-manifest.json for failed files.")
        except (OSError, UnicodeDecodeError, json.JSONDecodeError, AttributeError) as error:
            raise DiagnosticsError(f"invalid capture manifest {capture}: {error}") from error
    sessions = [
        summarize_session(
            session_id,
            grouped[session_id],
            manifests.get(session_id),
            global_warnings + warnings_by_session.get(session_id, []),
        )
        for session_id in sorted(grouped)
    ]
    for session in sessions:
        session["failure_evidence"] = incidents.get(session["session_id"])
    return {
        "tool_schema_version": TOOL_SCHEMA_VERSION,
        "source": str(source),
        "selection": selection,
        "sessions": sessions,
    }


def number(value: float | int) -> str:
    if isinstance(value, int):
        return str(value)
    if abs(value) >= 1000:
        return f"{value:,.0f}"
    return f"{value:.3f}".rstrip("0").rstrip(".")


def print_entries(entries: list[dict[str, Any]], indent: str = "  ") -> None:
    if not entries:
        print(f"{indent}(none)")
        return
    for entry in entries:
        details = []
        attributes = entry.get("attributes", {})
        metrics = entry.get("metrics", {})
        for key in ("stall_kind", "outcome", "phase", "reason", "counter", "error_domain"):
            if key in attributes:
                details.append(f"{key}={attributes[key]}")
        if "duration_seconds" in metrics:
            details.append(f"duration={number(metrics['duration_seconds'])}s")
        suffix = f" ({', '.join(details)})" if details else ""
        print(
            f"{indent}{entry['timestamp']} #{entry['sequence']} "
            f"{entry['kind']}/{entry['name']} [{entry['level']}]{suffix}"
        )


def print_text(report: dict[str, Any]) -> None:
    print("Strozz playback diagnostics")
    print(f"Source: {report['source']}")
    print(f"Selection: {report['selection']}")
    for session in report["sessions"]:
        print()
        print(f"Session {session['session_id']}")
        status = "ACTIVE/INCOMPLETE" if session["active"] else "ended"
        if session["partial_evidence"]:
            status += ", partial evidence"
        print(
            f"  Channel: {session['channel']}  Mode: {session['playback_mode']}  "
            f"Status: {status}"
        )
        print(
            f"  Observed: {session['started_at']} to {session['ended_at'] or 'last record'}  "
            f"Duration: {number(session['duration_seconds'])}s "
            f"({session['duration_source']})"
        )
        counts = session["counts"]
        print(
            f"  Records: {counts['records']}  Stall episodes: {counts['stall_episodes']}  "
            f"Stall notifications: {counts['stall_notifications']}  "
            f"Stream errors: {counts['stream_errors']}  "
            f"Controller interventions: {counts['controller_interventions']}"
        )
        if evidence := session.get("failure_evidence"):
            print("  Pinned failure evidence (independent of verbose log rotation):")
            for key in ["firstIncident", "firstFailure", "latestFailure", "latestRecovery"]:
                if record := evidence.get(key):
                    print(f"    {key}: {record['timestamp']} {record['name']} {record['attributes']}")
            if sample := evidence.get("latestSample"):
                print(f"    Last state: {sample['timestamp']} phase={sample['attributes'].get('phase', 'unknown')} "
                      f"recovery_blocked_by={sample['attributes'].get('recovery_blocked_by', 'unknown')}")
            if evidence.get("oversizedRecordsOmitted"):
                print(f"    Oversized checkpoint records omitted: {evidence['oversizedRecordsOmitted']}")
        if counts["stalls_by_kind"]:
            print(
                "  Stall kinds: "
                + ", ".join(f"{key}={value}" for key, value in counts["stalls_by_kind"].items())
            )
        if session["rates"]:
            print("  Rates:")
            for key, value in session["rates"].items():
                print(f"    {key}: {number(value)}")
        if session["metric_distributions"]:
            print("  Metric distributions:")
            for key, stats in session["metric_distributions"].items():
                print(
                    f"    {key}: n={stats['count']} min={number(stats['min'])} "
                    f"p50={number(stats['p50'])} p95={number(stats['p95'])} "
                    f"max={number(stats['max'])}"
                )
        if session["diagnostic_timing_groups"]:
            print("  Diagnostic stage timings:")
            for group, fields in session["diagnostic_timing_groups"].items():
                print(f"    {group}:")
                for key, stats in fields.items():
                    print(f"      {key}: n={stats['count']} p95={number(stats['p95'])} max={number(stats['max'])}")
        if session["counter_deltas"]:
            print("  Counter deltas (reset-aware):")
            for key, value in session["counter_deltas"].items():
                print(f"    {key}: {value}")
        if session["skipped_native_log_entries"]:
            print(
                "  Skipped native log backlog: "
                + ", ".join(
                    f"{key}={value}"
                    for key, value in session["skipped_native_log_entries"].items()
                )
            )
        if session["proxy_last_failure"]:
            print(
                "  Last retained proxy failure: "
                + ", ".join(
                    f"{key}={number(value)}"
                    for key, value in session["proxy_last_failure"].items()
                )
            )
        print("  Stall timeline:")
        print_entries(session["stalls"], "    ")
        print("  Stream error timeline:")
        print_entries(session["stream_errors"], "    ")
        print("  Other noteworthy timeline:")
        print_entries(session["timeline"], "    ")
        if session["hypotheses"]:
            print("  Cautious observations:")
            for hypothesis in session["hypotheses"]:
                print(f"    - {hypothesis}")
        print("  Interpretation notes:")
        for note in session["interpretation_notes"]:
            print(f"    - {note}")
        if session["warnings"]:
            print("  Warnings:")
            for warning in session["warnings"]:
                print(f"    - {warning}")


def default_output_path() -> Path:
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    root = Path.cwd() / "playback-diagnostics"
    candidate = root / stamp
    suffix = 2
    while candidate.exists():
        candidate = root / f"{stamp}-{suffix}"
        suffix += 1
    return candidate


def pull(device: str | None, bundle: str, output: Path, *,
         incidents_only: bool = False, mobile: bool = False, legacy_cache: bool = False) -> Path:
    if not device:
        raise DiagnosticsError("pass --device <device-id> or set STROZZ_DEVICE_ID")
    if shutil.which("xcrun") is None:
        raise DiagnosticsError("xcrun is required for pull but was not found on PATH")
    if output.exists():
        raise DiagnosticsError(f"refusing to overwrite existing pull destination: {output}")
    output.parent.mkdir(parents=True, exist_ok=True)
    remote = REMOTE_SOURCE
    if mobile:
        remote = "Library/Application Support/MobilePlaybackDiagnostics"
    if legacy_cache:
        remote = remote.replace("Application Support", "Caches")
    domain = ["--device", device, "--domain-type", "appDataContainer", "--domain-identifier", bundle]
    result = subprocess.run([
        "xcrun", "devicectl", "device", "info", "files", *domain,
        "--subdirectory", remote, "--recurse", "--timeout", "60", "--json-output", "-",
    ], text=True, capture_output=True, check=False)
    if result.returncode != 0:
        details = result.stderr.strip() or result.stdout.strip() or "no diagnostic output"
        raise DiagnosticsError(f"device diagnostic listing failed:\n{details}")
    try:
        entries = json.loads(result.stdout)["result"]["files"]
        if not isinstance(entries, list):
            raise TypeError("files is not an array")
    except (ValueError, KeyError, TypeError) as error:
        raise DiagnosticsError(f"invalid device file listing: {error}") from error
    names = []
    for entry in entries:
        if not isinstance(entry, dict) or not isinstance(entry.get("relativePath"), str):
            raise DiagnosticsError("invalid device file listing entry")
        name = entry.get("relativePath", "")
        parts = Path(name).parts
        is_incident = len(parts) == 2 and parts[0] == "Incidents" and INCIDENT_PATTERN.fullmatch(parts[1])
        is_log = len(parts) == 1 and FILE_PATTERN.fullmatch(name)
        if (name == "latest-session.json" and not incidents_only) or is_incident or (is_log and not incidents_only):
            names.append(name)
    if not names or (incidents_only and not any(name.startswith("Incidents/") for name in names)):
        raise DiagnosticsError(f"no {'incident checkpoints' if incidents_only else 'diagnostic files'} in {remote}")
    output.mkdir()
    copied, failed = [], []
    # Preserve the small failure checkpoints first. A large live directory copy
    # can fail midway through a rotating file and lose the useful evidence.
    for name in sorted(set(names), key=lambda name: (not name.startswith("Incidents/"), name)):
        destination = output / name
        destination.parent.mkdir(parents=True, exist_ok=True)
        result = subprocess.run([
            "xcrun", "devicectl", "device", "copy", "from", *domain,
            "--source", f"{remote}/{name}", "--destination", str(destination), "--timeout", "60",
        ], text=True, capture_output=True, check=False)
        if result.returncode != 0 or not destination.is_file() or destination.stat().st_size == 0:
            failed.append({"file": name, "error": result.stderr.strip() or result.stdout.strip()
                           or "copy did not produce a nonempty file"})
        else:
            copied.append(name)
    (output / "capture-manifest.json").write_text(json.dumps({
        "source": remote, "incidents_only": incidents_only,
        "captured_at": datetime.now(timezone.utc).isoformat(),
        "copied": copied, "failed": failed,
    }, indent=2), encoding="utf-8")
    if failed:
        raise DiagnosticsError(
            f"partial capture: {len(copied)} files copied, {len(failed)} failed; "
            f"see {output / 'capture-manifest.json'}. Retained files can still be analyzed."
        )
    return output


def add_selection_arguments(parser: argparse.ArgumentParser) -> None:
    selection = parser.add_mutually_exclusive_group()
    selection.add_argument("--session", metavar="UUID", help="analyze one session UUID")
    selection.add_argument(
        "--all",
        action="store_true",
        help="analyze every retained session separately (never combines sessions)",
    )
    parser.add_argument("--json", action="store_true", help="emit deterministic JSON")


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Pull and cautiously summarize Strozz playback JSONL logs."
    )
    subparsers = parser.add_subparsers(dest="command", required=True)
    analyze_parser = subparsers.add_parser(
        "analyze", help="analyze a local directory, JSONL log, or incident checkpoint"
    )
    analyze_parser.add_argument("path", type=Path, help="log directory, .jsonl file, or incident-<UUID>.json")
    add_selection_arguments(analyze_parser)

    pull_parser = subparsers.add_parser(
        "pull", help="copy scoped diagnostics from a paired device, then analyze them"
    )
    pull_parser.add_argument(
        "--device", default=os.environ.get("STROZZ_DEVICE_ID") or os.environ.get("TWOZZ_DEVICE_ID"),
        help="paired device identifier (or set STROZZ_DEVICE_ID)",
    )
    pull_parser.add_argument("--bundle", default=DEFAULT_BUNDLE, help="app bundle identifier")
    pull_parser.add_argument("--incidents-only", action="store_true",
                             help="copy small pinned failure checkpoints, not the verbose playback logs")
    pull_parser.add_argument("--mobile", action="store_true", help="select mobile playback diagnostics")
    pull_parser.add_argument("--legacy-cache", action="store_true",
                             help="read the old Library/Caches location used by earlier builds")
    pull_parser.add_argument(
        "--output",
        type=Path,
        help="new destination directory (default: playback-diagnostics/<UTC timestamp>)",
    )
    add_selection_arguments(pull_parser)
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    try:
        if args.command == "pull":
            output = args.output or default_output_path()
            source = pull(args.device, args.bundle, output, incidents_only=args.incidents_only,
                          mobile=args.mobile, legacy_cache=args.legacy_cache)
            print(f"Pulled playback diagnostics to {source}", file=sys.stderr)
        else:
            source = args.path
        report = analyze(source, args.session, args.all)
        if args.json:
            json.dump(report, sys.stdout, indent=2, sort_keys=True, allow_nan=False)
            print()
        else:
            print_text(report)
        return 0
    except (DiagnosticsError, OSError) as error:
        print(f"playback-diagnostics.py: error: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
