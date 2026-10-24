"""Desktop checks only; never opens a physical or virtual serial port."""
import json
import contextlib
import io
import os
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

PROJECT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(PROJECT / "tools"))
from project_paths import WEBSITE
from score_pc.protocol import Command as C, Error as E, Frame, StreamDecoder, begin_payload, crc32, decode, id_bytes, id_text, response_dict
from score_pc.simulator import Limits, PackageInvalid, Simulator, ValidatorUnavailable, validate_package
from score_pc.client import Client, JsonLog, ResultUnknown

FIXTURES = WEBSITE / "tests/fixtures/packages"
SONG = id_bytes("12345678-1234-5678-9abc-def012345678")
OTHER = id_bytes("22345678-1234-5678-9abc-def012345678")
DATA = bytes(range(256))*3


def synthetic_validator(data):
    """Storage-state tests only. End-to-end tests below use the real TS parser."""
    return dict(id=id_text(SONG), total_bytes=len(data), file_crc=crc32(data), capabilities=1,
                notes=1, pages=0, sections=4, profiles=[])


class InProcessTransport:
    def __init__(self, sim, lose=None):
        self.sim, self.lose, self.requests = sim, lose, []

    def exchange(self, request, timeout):
        self.requests.append(request)
        result = self.sim.handle(request)
        if request.type == self.lose:
            # Represents all three identical transmissions losing their replies.
            self.lose = None
            assert self.sim.handle(request) == result
            assert self.sim.handle(request) == result
            raise ResultUnknown("test reply loss after committed operation")
        return result


class ProtocolTests(unittest.TestCase):
    def test_logging_short_semantic_frames_cannot_crash_server(self):
        log = JsonLog()
        for command in (C.BEGIN, C.DATA, C.COMMIT, C.PAUSE, C.DELETE):
            for size in range(41):
                frame = Frame(command, 1, 2, bytes(size))
                record = log.emit("receive", frame)
                self.assertEqual(record["hex"], frame.encode().hex())

    def test_shared_c_golden_frames_and_response_fields(self):
        vectors = json.loads((PROJECT / "tests/vectors/uart-v2-golden.json").read_text(encoding="utf-8"))
        for vector in vectors["requests"] + vectors["responses"]:
            with self.subTest(name=vector["name"]):
                raw = bytes.fromhex(vector["uart_hex"])
                frame = decode(raw)
                self.assertEqual(frame.encode(), raw)
                if "json" in vector:
                    result = response_dict(frame)
                    # CLI uses entries/error names; BLE fields use items/code.
                    for key, value in vector["json"].items():
                        if key not in ("protocol", "max_write"):
                            self.assertEqual(result[{"items": "entries", "code": "error"}.get(key, key)], value)

    def test_crc_and_spec_caps_vector(self):
        self.assertEqual(crc32(b"123456789"), 0xcbf43926)
        raw = bytes.fromhex("A5 5A 02 01 01 00 00 00 01 00 00 00 00 00 00 00 1E 28 4C BA")
        self.assertEqual(Frame(C.CAPS, 1, 1).encode(), raw)
        self.assertEqual(decode(raw), Frame(C.CAPS, 1, 1))

    def test_all_splits_noise_crc_concat_and_payload_magic(self):
        frame = Frame(C.DATA, 0x12345678, 9, SONG + struct.pack("<I", 0) + b"\xa5\x5a"*256)
        raw = frame.encode()
        for split in range(len(raw)+1):
            parser = StreamDecoder()
            result = parser.feed(raw[:split], now=0) + parser.feed(raw[split:], now=0.01)
            self.assertEqual(result, [frame])
        bad = bytearray(raw)
        bad[-1] ^= 1
        parser = StreamDecoder()
        self.assertEqual(parser.feed(b"garbage" + bad + raw + raw), [frame, frame])
        self.assertLessEqual(len(parser.buffer), 1)

    def test_oversize_timeout_and_maximum(self):
        max_frame = Frame(C.LIST, 3, 4, b"x"*1024)
        self.assertEqual(len(max_frame.encode()), 1044)
        parser = StreamDecoder()
        oversize = struct.pack("<2sBBIIHH", b"\xa5\x5a", 2, 1, 1, 1, 1025, 0)
        self.assertEqual(parser.feed(oversize + max_frame.encode(), now=0), [max_frame])
        parser.feed(max_frame.encode()[:100], now=0.01)
        self.assertEqual(parser.feed(max_frame.encode(), now=0.2), [max_frame])


class StorageTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.path = Path(self.temp.name) / "fpga.db"
        self.sim = Simulator(self.path, validator=synthetic_validator)
        self.seq = 0
        self.session = 7
        self.ask(C.CAPS)

    def tearDown(self):
        self.sim.close()
        self.temp.cleanup()

    def ask(self, cmd, payload=b""):
        self.seq += 1
        return self.sim.handle(Frame(cmd, self.session, self.seq, payload))

    def result(self, cmd, payload=b""):
        response = response_dict(self.ask(cmd, payload))
        self.assertNotIn("error", response, response)
        return response

    def begin(self, song=SONG, data=DATA, caps=1, title="练习曲"):
        return self.result(C.BEGIN, begin_payload(song, len(data), crc32(data), caps, title))

    def send_blocks(self, song=SONG, data=DATA, first=0):
        for index in range(first, (len(data)+511)//512):
            result = self.result(C.DATA, song + struct.pack("<I", index) + data[index*512:(index+1)*512])
            self.assertEqual(result["next_block"], index+1)
            self.assertEqual(result["saved_bytes"], min((index+1)*512, len(data)))

    def test_resume_after_reopen_and_full_crc_publish(self):
        self.begin()
        generation = self.sim.generation
        self.result(C.DATA, SONG + struct.pack("<I", 0) + DATA[:512])
        self.assertEqual(self.sim.generation, generation)
        self.sim.close()
        self.sim = Simulator(self.path, validator=synthetic_validator)
        self.session, self.seq = 8, 0
        self.result(C.CAPS)
        self.assertIsNone(self.result(C.STATUS)["active_id"])
        self.assertEqual(self.begin()["next_block"], 1)
        self.send_blocks(first=1)
        self.result(C.COMMIT, SONG + struct.pack("<II", len(DATA), crc32(DATA)))
        self.assertEqual(self.sim.export_bytes(SONG), DATA)
        self.assertGreater(self.sim.generation, generation)
        self.assertEqual(response_dict(self.ask(C.BEGIN, begin_payload(SONG, len(DATA), crc32(DATA), 1, "x")))["error"], E.ALREADY_STORED)
        # A fresh-sequence repeated COMMIT remains idempotent.
        self.result(C.COMMIT, SONG + struct.pack("<II", len(DATA), crc32(DATA)))

    def test_dedup_same_seq_changed_bytes_old_seq_retired_session(self):
        self.begin()
        request = Frame(C.DATA, self.session, self.seq+1, SONG + struct.pack("<I", 0) + DATA[:512])
        response = self.sim.handle(request)
        self.seq += 1
        self.assertEqual(self.sim.handle(request).encode(), response.encode())
        changed = Frame(C.DATA, request.session, request.seq, request.payload[:-1] + b"x")
        self.assertEqual(response_dict(self.sim.handle(changed))["error"], E.BAD_REQUEST)
        self.result(C.STATUS)
        self.assertEqual(response_dict(self.sim.handle(request))["error"], E.BAD_REQUEST)
        self.assertEqual(self.sim.handle(Frame(C.CAPS, 99, 1)).type, C.ACK)
        self.assertEqual(response_dict(self.sim.handle(Frame(C.CAPS, self.session, 1)))["error"], E.BAD_REQUEST)
        self.assertEqual(self.sim._song(SONG)["next_block"], 1)

    def test_repeated_block_matches_bytes_and_rejects_skip_and_tail(self):
        self.begin()
        self.result(C.DATA, SONG + struct.pack("<I", 0) + DATA[:512])
        self.result(C.DATA, SONG + struct.pack("<I", 0) + DATA[:512])
        self.assertEqual(response_dict(self.ask(C.DATA, SONG + struct.pack("<I", 0) + b"x"*512))["error"], E.CONTENT_MISMATCH)
        for index, data in ((2, b"x"), (1, b"x"*512)):
            response = response_dict(self.ask(C.DATA, SONG + struct.pack("<I", index) + data))
            self.assertEqual((response["error"], response["next_block"]), (E.BAD_BLOCK, 1))
        self.assertEqual(self.sim._song(SONG)["next_block"], 1)

    def test_mode_pause_multi_partial_and_persistent_generation(self):
        self.begin()
        self.result(C.DATA, SONG + struct.pack("<I", 0) + DATA[:512])
        self.sim.set_mode(3)
        self.assertIsNone(self.result(C.STATUS)["active_id"])
        for cmd, payload in ((C.BEGIN, begin_payload(OTHER, len(DATA), crc32(DATA), 1, "B")),
                             (C.DATA, SONG + struct.pack("<I", 1) + DATA[512:]),
                             (C.DELETE, SONG), (C.COMMIT, SONG + struct.pack("<II", len(DATA), crc32(DATA)))):
            self.assertEqual(response_dict(self.ask(cmd, payload))["error"], E.BUSY)
        self.assertEqual(self.result(C.PAUSE, SONG)["next_block"], 1)
        self.sim.set_mode(0)
        self.begin(OTHER)
        self.result(C.PAUSE, OTHER)
        self.assertEqual(self.begin()["next_block"], 1)
        entries = self.result(C.LIST, struct.pack("<IIHH", 0, 0, 16, 0))["entries"]
        self.assertEqual(len(entries), 2)
        self.assertTrue(all(entry["entry_state"] == 1 for entry in entries))
        notices = self.sim.drain_notifications()
        self.assertTrue(all(n.type == C.CHANGED and n.session == n.seq == 0 for n in notices))

    def test_capacity_slots_content_and_utf8_validation(self):
        self.sim.limits = Limits(storage_bytes=1000, max_partial_songs=1)
        self.begin()
        self.assertEqual(self.result(C.STATUS)["free_bytes"], "232")
        self.result(C.PAUSE, SONG)
        self.assertEqual(response_dict(self.ask(C.BEGIN, begin_payload(OTHER, 768, 1, 1, "B")))["error"], E.NO_SPACE)
        self.assertEqual(response_dict(self.ask(C.BEGIN, begin_payload(SONG, 768, 2, 1, "A")))["error"], E.CONTENT_MISMATCH)
        for title in ("", "x"*129, "bad\x00title", "bad\n"):
            self.assertEqual(response_dict(self.ask(C.BEGIN, begin_payload(OTHER, 64, 1, 1, title)))["error"], E.BAD_REQUEST)
        self.result(C.DELETE, SONG)
        self.assertEqual(self.result(C.STATUS)["free_bytes"], "1000")
        self.begin(OTHER, title="中"*128)
        self.assertEqual(self.result(C.LIST, struct.pack("<IIHH", 0, 0, 1, 0))["entries"][0]["title"], "中"*128)

    def test_list_stale_and_delete_idempotent(self):
        self.begin()
        generation = self.sim.generation
        self.result(C.PAUSE, SONG)
        self.begin(OTHER)
        response = response_dict(self.ask(C.LIST, struct.pack("<IIHH", generation, 1, 1, 0)))
        self.assertEqual(response["error"], E.STALE_LIST)
        self.assertTrue(self.result(C.DELETE, OTHER)["deleted"])
        self.assertFalse(self.result(C.DELETE, OTHER)["deleted"])
        self.assertIsNotNone(self.sim._song(SONG))

    def test_bad_crc_and_missing_validator_never_publish(self):
        self.begin()
        self.send_blocks()
        self.sim.validator = lambda _: (_ for _ in ()).throw(ValidatorUnavailable("missing test runtime"))
        self.assertEqual(response_dict(self.ask(C.COMMIT, SONG + struct.pack("<II", len(DATA), crc32(DATA))))["error"], E.STORAGE_ERROR)
        self.assertEqual(self.sim._song(SONG)["state"], 1)
        self.sim.db.execute("UPDATE blocks SET data=? WHERE id=? AND block_index=0", (b"x"*512, SONG))
        self.sim.db.commit()
        self.assertEqual(response_dict(self.ask(C.COMMIT, SONG + struct.pack("<II", len(DATA), crc32(DATA))))["error"], E.BAD_FILE_CRC)
        self.assertEqual(self.sim._song(SONG)["state"], 1)

    def test_block_and_progress_rollback_together(self):
        self.begin()
        self.sim.db.execute("CREATE TRIGGER reject_progress BEFORE UPDATE OF next_block ON songs BEGIN SELECT RAISE(ABORT, 'injected storage failure'); END")
        response = response_dict(self.ask(C.DATA, SONG + struct.pack("<I", 0) + DATA[:512]))
        self.assertEqual(response["error"], E.STORAGE_ERROR)
        self.assertEqual(self.sim._song(SONG)["next_block"], 0)
        self.assertEqual(self.sim.db.execute("SELECT COUNT(*) FROM blocks").fetchone()[0], 0)

    def test_unknown_delete_queries_without_replaying(self):
        self.begin()
        self.result(C.PAUSE, SONG)
        transport = InProcessTransport(self.sim, lose=C.DELETE)
        client = Client(transport, session=101)
        client.connect()
        result = client.delete(id_text(SONG))
        self.assertTrue(result["absent_after_query"])
        self.assertEqual(sum(r.type == C.DELETE for r in transport.requests), 1)
        self.assertEqual(transport.requests[-1].type, C.LIST)

    def test_wrong_delete_ack_does_not_claim_success_or_replay(self):
        self.begin()
        self.result(C.PAUSE, SONG)
        transport = InProcessTransport(self.sim)
        original = transport.exchange

        def wrong_ack(request, timeout):
            if request.type == C.DELETE:
                transport.requests.append(request)
                return Frame(C.ACK, request.session, request.seq,
                             bytes([C.DELETE, 0, 0, 0]) + struct.pack("<16sB3x", OTHER, 1))
            return original(request, timeout)

        transport.exchange = wrong_ack
        client = Client(transport, session=102)
        client.connect()
        with self.assertRaisesRegex(ResultUnknown, "record still present"):
            client.delete(id_text(SONG))
        self.assertIsNotNone(self.sim._song(SONG))
        self.assertEqual(sum(r.type == C.DELETE for r in transport.requests), 1)

    def test_wrong_commit_ack_is_reconciled_not_treated_as_complete(self):
        source = Path(self.temp.name) / "synthetic.pseq"
        source.write_bytes(DATA)
        for field in ("id", "crc", "state"):
            with self.subTest(field=field):
                transport = InProcessTransport(self.sim)
                original = transport.exchange

                def wrong_ack(request, timeout):
                    if request.type == C.COMMIT:
                        transport.requests.append(request)
                        return Frame(C.ACK, request.session, request.seq, bytes([C.COMMIT, 0, 0, 0]) +
                                     struct.pack("<16sIB3x", OTHER if field == "id" else SONG,
                                                 crc32(DATA) ^ (1 if field == "crc" else 0),
                                                 1 if field == "state" else 2))
                    return original(request, timeout)

                transport.exchange = wrong_ack
                client = Client(transport)
                client.connect()
                with patch("score_pc.client.validate_package", return_value={**synthetic_validator(DATA), "title": "synthetic"}):
                    with self.assertRaisesRegex(ResultUnknown, "COMMIT outcome unresolved"):
                        client.download(source)
                self.assertEqual(self.sim._song(SONG)["state"], 1)
                self.assertEqual(sum(r.type == C.COMMIT for r in transport.requests), 1)

    def test_io_error_and_failed_query_preserve_unknown_without_replay(self):
        self.begin()
        self.result(C.PAUSE, SONG)
        transport = InProcessTransport(self.sim)
        original = transport.exchange
        broken = False

        def disconnect(request, timeout):
            nonlocal broken
            if request.type == C.DELETE or broken:
                broken = True
                transport.requests.append(request)
                raise OSError("injected unplug")
            return original(request, timeout)

        transport.exchange = disconnect
        client = Client(transport)
        client.connect()
        with self.assertRaisesRegex(ResultUnknown, "query failed, no mutation replayed"):
            client.delete(id_text(SONG))
        self.assertEqual(sum(r.type == C.DELETE for r in transport.requests), 1)
        self.assertIsNotNone(self.sim._song(SONG))

    def test_process_exit_after_ack_preserves_block_without_close(self):
        child_db = Path(self.temp.name) / "crashed.db"
        program = """
import os, sys, struct
from score_pc.protocol import Command as C, Frame, begin_payload, crc32
from score_pc.simulator import Simulator
s = Simulator(sys.argv[1])
song = bytes.fromhex('12345678123456789abcdef012345678')
data = bytes(range(256)) * 3
assert s.handle(Frame(C.CAPS, 77, 1)).type == C.ACK
assert s.handle(Frame(C.BEGIN, 77, 2, begin_payload(song, len(data), crc32(data), 1, 'crash-test'))).type == C.ACK
assert s.handle(Frame(C.DATA, 77, 3, song + struct.pack('<I', 0) + data[:512])).type == C.ACK
os._exit(71)
"""
        env = dict(os.environ, PYTHONPATH=str(PROJECT / "tools"))
        result = subprocess.run([sys.executable, "-c", program, str(child_db)],
                                env=env, capture_output=True, timeout=20)
        self.assertEqual(result.returncode, 71, result.stderr)
        recovered = Simulator(child_db)
        try:
            self.assertEqual(recovered._song(SONG)["next_block"], 1)
            self.assertEqual(recovered.export_bytes(SONG, allow_partial=True), DATA[:512])
            self.assertEqual(recovered.generation, 2)
            self.assertIsNone(recovered.active_id)
        finally:
            recovered.close()


class RealPackageTests(unittest.TestCase):
    def test_actual_parser_valid_and_four_semantically_invalid_packages(self):
        manifest = json.loads((FIXTURES / "manifest.json").read_text(encoding="utf-8"))
        raw = (FIXTURES / "engineering.pseq").read_bytes()
        info = validate_package(raw)
        self.assertEqual((info["id"], len(raw), crc32(raw), (len(raw)+511)//512, len(raw)%512),
                         (manifest["id"], manifest["total_bytes"], manifest["file_crc"], 453, 32))
        for name in manifest["invalid"]:
            with self.subTest(name=name), self.assertRaises(PackageInvalid):
                validate_package((FIXTURES / (name+".pseq")).read_bytes())

    def test_complete_real_package_and_unknown_commit_reconciliation(self):
        with tempfile.TemporaryDirectory() as temp:
            sim = Simulator(Path(temp) / "fpga.db")
            try:
                transport = InProcessTransport(sim, lose=C.COMMIT)
                client = Client(transport, session=103)
                client.connect()
                progress = []
                result = client.download(FIXTURES / "engineering.pseq", progress=progress.append)
                self.assertEqual(result["entry_state"], 2)
                self.assertFalse(result["ack_received"])
                self.assertEqual(len(progress), 453)
                self.assertEqual(progress[-1]["saved_bytes"], 231456)
                self.assertEqual(sim.export_bytes(SONG), (FIXTURES / "engineering.pseq").read_bytes())
                self.assertEqual(sum(r.type == C.COMMIT for r in transport.requests), 1)
            finally:
                sim.close()

    def test_adapter_missing_runtime_fails_closed(self):
        with self.assertRaises(ValidatorUnavailable):
            validate_package((FIXTURES / "engineering.pseq").read_bytes(), node="nonexistent-node-binary-for-test")

    def test_cli_requires_port_and_help_never_imports_serial(self):
        with patch("score_pc.__main__.open_serial", side_effect=AssertionError("must not open serial")):
            from score_pc.__main__ import main
            with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit) as caught:
                main(["serve", "--db", "unused.db", "--log", "unused.jsonl"])
            self.assertEqual(caught.exception.code, 2)


if __name__ == "__main__":
    unittest.main()
