import importlib.util
import io
from pathlib import Path
import socket
import struct
import sys
import threading
import time
import tempfile
import unittest


SPEC = importlib.util.spec_from_file_location(
    "ll_hls_probe", Path(__file__).parents[1] / "ll-hls-probe.py")
probe = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = probe
SPEC.loader.exec_module(probe)


def box(kind, payload):
    return struct.pack(">I4s", len(payload) + 8, kind) + payload


def words(*values):
    return struct.pack(">" + "I" * len(values), *values)


class MP4Tests(unittest.TestCase):
    def test_boxes_validate_boundaries(self):
        self.assertEqual(list(probe.boxes(box(b"free", b"abc"))), [(b"free", b"abc")])
        for data in (b"short", words(7) + b"free", words(32) + b"free"):
            with self.assertRaises(probe.ProbeError):
                list(probe.boxes(data))

    def test_extended_box_and_partial_reads(self):
        data = words(1) + b"free" + struct.pack(">Q", 19) + b"abc"
        self.assertEqual(probe.read_box(io.BytesIO(data)), data)
        self.assertEqual(list(probe.boxes(data)), [(b"free", b"abc")])
        with self.assertRaises(probe.ProbeError):
            probe.read_box(io.BytesIO(data[:-1]))

    def test_video_track_timescale_and_defaults(self):
        mdia = box(b"hdlr", words(0, 0) + b"vide")
        mdia += box(b"mdhd", words(0, 0, 0, 90000))
        trak = box(b"tkhd", words(0, 0, 0, 1)) + box(b"mdia", mdia)
        moov = box(b"trak", trak) + box(b"mvex", box(b"trex", words(0, 1, 1, 3000, 0, 0x10000)))
        self.assertEqual(probe.video_track(moov), (1, 90000, 3000, 0x10000))

    def test_fragment_uses_real_sample_durations_and_sync_flag(self):
        traf = box(b"tfhd", words(0x28, 1, 3000, 0x10000))
        traf += box(b"tfdt", words(0x01000000, 0, 90000))
        traf += box(b"trun", words(0x104, 3, 0, 3000, 6000, 3000))
        start, duration, independent = probe.fragment_timing(box(b"traf", traf), (1, 90000, 0, 0))
        self.assertEqual(start, 1)
        self.assertAlmostEqual(duration, 12000 / 90000)
        self.assertTrue(independent)
        traf = box(b"tfhd", words(0x28, 1, 3000, 0x10000))
        traf += box(b"tfdt", words(0, 12000))
        traf += box(b"trun", words(0, 2))
        self.assertFalse(probe.fragment_timing(box(b"traf", traf), (1, 90000, 0, 0))[2])

    def test_malformed_sample_table_fails(self):
        traf = box(b"tfhd", words(0, 1)) + box(b"tfdt", words(0, 0))
        traf += box(b"trun", words(0x100, 10, 3000))
        with self.assertRaises(probe.ProbeError):
            probe.fragment_timing(box(b"traf", traf), (1, 90000, 0, 0))


class PlaylistTests(unittest.TestCase):
    def test_prefetch_has_contiguous_identity(self):
        text = "#EXTM3U\n#EXT-X-MEDIA-SEQUENCE:8\n#EXTINF:2,\na.ts\n#EXT-X-TWITCH-PREFETCH:b.ts\n"
        self.assertEqual(probe.media_entries(text, "https://example.test/live.m3u8"), [
            (8, "https://example.test/a.ts", False), (9, "https://example.test/b.ts", True),
        ])

    def test_transitions_are_not_silently_removed(self):
        for tag in ("#EXT-X-DISCONTINUITY", '#EXT-X-DATERANGE:ID="ad"',
                    '#EXT-X-KEY:METHOD=AES-128', "#EXT-X-ENDLIST"):
            with self.assertRaises(probe.ProbeError):
                probe.media_entries(f"#EXTM3U\n#EXT-X-MEDIA-SEQUENCE:1\n{tag}\na.ts\n", "https://example.test/")

    def test_non_ad_metadata_and_stable_discontinuity_header_are_allowed(self):
        text = ('#EXTM3U\n#EXT-X-MEDIA-SEQUENCE:1\n#EXT-X-DISCONTINUITY-SEQUENCE:0\n'
                '#EXT-X-DATERANGE:ID="clock",CLASS="timestamp"\n#EXT-X-MAP:URI="init.mp4"\na.mp4\n')
        self.assertEqual(len(probe.media_entries(text, "https://example.test/")), 1)


class OriginTests(unittest.TestCase):
    def setUp(self):
        self.origin = probe.Origin()
        self.origin.init = b"init"
        self.origin.target_duration = 2
        for index in range(25):
            self.origin.append(bytes([index]), index * 0.25, 0.25, index % 8 == 0)

    def test_only_real_parts_and_completed_parents_are_published(self):
        text = self.origin.playlist().decode()
        self.assertEqual(text.count("#EXT-X-PART:"), 17)
        self.assertEqual(text.count("#EXTINF:"), 3)
        self.assertIn('URI="part/3/1.mp4"', text)
        self.assertIn("CAN-BLOCK-RELOAD=YES", text)
        self.assertIn("PART-HOLD-BACK=1.5", text)
        self.assertEqual(text.count("INDEPENDENT=YES"), 3)
        self.assertEqual(self.origin.respond("/segment/0.mp4", {})[1], bytes(range(8)))
        self.assertEqual(self.origin.respond("/part/1/0.mp4", {})[1], b"\x08")
        self.assertEqual(self.origin.respond("/segment/3.mp4", {})[0], 404)

    def test_blocking_reload_waits_for_published_part(self):
        results = []
        thread = threading.Thread(target=lambda: results.append(
            self.origin.respond("/live.m3u8", {"_HLS_msn": ["3"], "_HLS_part": ["1"]})))
        thread.start()
        time.sleep(0.03)
        self.assertFalse(results)
        self.origin.append(b"x", 6.25, 0.25, False)
        thread.join(timeout=1)
        self.assertFalse(thread.is_alive())
        self.assertIn(b'URI="part/3/1.mp4"', results[0][1])
        self.assertEqual(self.origin.stats["blocking_requests"], 1)

    def test_preload_is_released_when_bytes_arrive(self):
        results = []
        thread = threading.Thread(target=lambda: results.append(self.origin.respond("/part/3/1.mp4", {})))
        thread.start()
        time.sleep(0.03)
        self.assertFalse(results)
        self.origin.append(b"new", 6.25, 0.25, False)
        thread.join(timeout=1)
        self.assertEqual(results[0][1], b"new")

    def test_invalid_delivery_directive_fails_immediately(self):
        for query in ({"_HLS_msn": ["bad"]}, {"_HLS_msn": ["500"]}, {"_HLS_msn": ["-1"]}):
            self.assertEqual(self.origin.respond("/live.m3u8", query)[0], 400)

    def test_declared_duration_and_timeline_are_enforced(self):
        with self.assertRaises(probe.ProbeError):
            self.origin.append(b"x", 6.25, probe.PART_TARGET + 0.01, False)
        with self.assertRaises(probe.ProbeError):
            self.origin.append(b"x", 4, 0.25, False)

    def test_origin_failure_is_visible(self):
        self.origin.fail("discontinuity")
        self.assertEqual(self.origin.respond("/live.m3u8", {})[0], 503)
        self.assertFalse(probe.summarize([], self.origin)["success"])

    def test_parts_requests_without_decoded_frames_are_not_success(self):
        self.origin.stats["parts_requested"] = 99
        report = probe.summarize([], self.origin)
        self.assertTrue(report["partial_delivery_observed"])
        self.assertFalse(report["success"])

    def test_frozen_baseline_cannot_be_reported_as_a_successful_comparison(self):
        self.origin.stats["parts_requested"] = 10
        self.origin.stats["http2_requests"] = 10
        rows = []
        for index in range(240):
            baseline = {"clock": min(index / 4, 15), "state": "playing" if index < 60 else "paused"}
            if index < 60:
                baseline["fingerprint"] = "AAAA"
            rows.append({"t": index / 4, "baseline": baseline, "candidate": {
                "clock": index / 4, "state": "playing", "fingerprint": "AAAA",
            }})
        report = probe.summarize(rows, self.origin)
        self.assertTrue(report["native_candidate_playback_verified"])
        self.assertFalse(report["comparison_valid"])
        self.assertFalse(report["success"])
        self.assertNotIn("frame_alignment", report)

    def test_playable_whole_segment_fallback_is_not_a_low_latency_success(self):
        self.origin.stats["http2_requests"] = 10
        rows = [{"t": i / 4, **{
            name: {"clock": i / 4, "state": "playing", "fingerprint": "AAAA"}
            for name in ("baseline", "candidate")
        }} for i in range(240)]
        report = probe.summarize(rows, self.origin)
        self.assertTrue(report["native_candidate_playback_verified"])
        self.assertTrue(report["comparison_valid"])
        self.assertFalse(report["partial_delivery_observed"])
        self.assertFalse(report["success"])
        self.assertNotIn("frame_alignment", report, "Static video is not a reliable alignment")

    @unittest.skipUnless(importlib.util.find_spec("hypercorn"), "HTTP/2 test requires the probe venv")
    def test_real_tls_http2_transport_without_system_trust(self):
        from h2.connection import H2Connection
        from h2.events import DataReceived, StreamEnded

        with tempfile.TemporaryDirectory() as directory:
            server = probe.Transport(self.origin, Path(directory))
            try:
                server.check_ready()
                server.context.set_alpn_protocols(["h2"])
                port = probe.urlsplit(server.url).port
                with socket.create_connection(("127.0.0.1", port), timeout=5) as raw:
                    with server.context.wrap_socket(raw, server_hostname="127.0.0.1") as connection:
                        self.assertEqual(connection.selected_alpn_protocol(), "h2")
                        client = H2Connection()
                        client.initiate_connection()
                        client.send_headers(1, [
                            (":method", "GET"), (":scheme", "https"),
                            (":authority", f"127.0.0.1:{port}"), (":path", "/live.m3u8"),
                        ], end_stream=True)
                        connection.sendall(client.data_to_send())
                        body = bytearray()
                        ended = False
                        while not ended:
                            chunk = connection.recv(65536)
                            self.assertTrue(chunk, "HTTP/2 closed before completing the playlist")
                            for event in client.receive_data(chunk):
                                if isinstance(event, DataReceived):
                                    body.extend(event.data)
                                    client.acknowledge_received_data(event.flow_controlled_length, event.stream_id)
                                elif isinstance(event, StreamEnded):
                                    ended = True
                            pending = client.data_to_send()
                            if pending:
                                connection.sendall(pending)
                        self.assertIn(b"#EXT-X-PART:", body)
                self.assertGreater(self.origin.stats["http2_requests"], 0)
                self.assertFalse(server.trust_attempted)
            finally:
                self.origin.stopped.set()
                with self.origin.condition:
                    self.origin.condition.notify_all()
                server.close()
            self.assertFalse(Path(server.temporary.name).exists())
            self.assertFalse(server.thread.is_alive())


if __name__ == "__main__":
    unittest.main()
