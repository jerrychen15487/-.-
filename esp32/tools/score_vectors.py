"""Independent struct/zlib vectors for PROTOCOL.md chapter 3.

Run --write only after reviewing a protocol/sample change. --check is read-only;
--verify-json PATH checks C response JSON semantically against the web fixture.
"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import struct
import subprocess
import zlib

from project_paths import PROJECT, WEBSITE
ROOT = PROJECT.parent
FIXTURE = WEBSITE / "tests/fixtures/v2-golden.json"
DEST = PROJECT / "tests/vectors"
ID = bytes.fromhex("00112233445566778899aabbccddeeff")


def frame(kind: int, data: bytes = b"", session: int = 1, seq: int = 1) -> bytes:
    header = struct.pack("<BBIIHH", 2, kind, session, seq, len(data), 0)
    return b"\xa5\x5a" + header + data + struct.pack("<I", zlib.crc32(header + data))


def build() -> dict:
    raw = FIXTURE.read_bytes()
    golden = json.loads(raw)
    assert frame(1).hex() == golden["caps_frame_hex"]
    song_id = "00112233-4455-6677-8899-aabbccddeeff"
    title = "测试"
    requests = [
        ("caps", 1, None, b""), ("status", 2, None, b""),
        ("list", 3, {"generation": 0, "cursor": 0, "limit": 1}, struct.pack("<IIHH", 0, 0, 1, 0)),
        ("begin", 16, {"id": song_id, "total_bytes": 516, "file_crc": 0x12345678,
                       "block_bytes": 512, "package_major": 2, "total_blocks": 2,
                       "capabilities": 1, "title": title},
         ID + struct.pack("<IIHHIIHH", 516, 0x12345678, 512, 2, 2, 1, len(title.encode()), 0) + title.encode()),
        ("data", 17, None, bytes.fromhex(golden["data_payload_hex"])),
        ("commit", 18, {"id": song_id, "total_bytes": 516, "file_crc": 0x12345678}, ID + struct.pack("<II", 516, 0x12345678)),
        ("pause", 19, {"id": song_id}, ID), ("delete", 20, {"id": song_id}, ID),
    ]
    caps = struct.pack("<HHHHIIIIIIHHH", 2, 2, 1024, 512, 4194304, 20000, 16, 4, 128, 64, 1, 1, 1)
    status = struct.pack("<BBHIQ", 0, 1, 0, 7, 9007199254740993) + ID + struct.pack("<II", 1, 2)
    entry = ID + struct.pack("<B3xIIIIIHH", 1, 516, 0x12345678, 1, 1, 2, len(title.encode()), 0) + title.encode()
    responses = [
        ("caps", 1, caps), ("status", 2, status),
        ("list", 3, struct.pack("<IIHH", 7, 0xffffffff, 1, 0) + entry),
        ("begin_ack", 16, ID + struct.pack("<III", 1, 2, 512)),
        ("data_ack", 17, ID + struct.pack("<III", 2, 2, 516)),
        ("commit_ack", 18, ID + struct.pack("<IB3x", 0x12345678, 2)),
        ("pause_ack", 19, ID + struct.pack("<III", 1, 2, 512)),
        ("delete_ack", 20, ID + struct.pack("<B3x", 1)),
    ]
    result = {"spec": "trans/PROTOCOL.md chapter 3, UART/BLE v2", "source": "piano-score-library/tests/fixtures/v2-golden.json",
              "source_sha256": hashlib.sha256(raw).hexdigest(), "requests": [], "responses": []}
    for name, kind, obj, payload in requests:
        ble = payload if obj is None else json.dumps(obj, ensure_ascii=False, separators=(",", ":")).encode()
        result["requests"].append({"name": name, "uart_hex": frame(kind, payload).hex(), "ble_hex": frame(kind, ble).hex()})
    for name, kind, payload in responses:
        result["responses"].append({"name": name, "uart_hex": frame(0x80, bytes((kind, 0, 0, 0)) + payload).hex(), "json": golden[name]})
    result["responses"].extend([
        {"name": "error", "uart_hex": frame(0xff, struct.pack("<BBHI", 17, 0, 5, 1)).hex(), "json": golden["error"]},
        {"name": "changed", "uart_hex": frame(0x90, struct.pack("<IBBH", 8, 3, 0, 0), 0, 0).hex(), "json": golden["changed"]},
    ])
    # Boundary cases are independent expectations, not additions to the website.
    boundaries = [
        ("status_u64_max", 2, struct.pack("<BBHIQ", 3, 2, 0, 0xffffffff, 0xffffffffffffffff) + ID + struct.pack("<II", 8388608, 8388608),
         {**golden["status"], "mode": 3, "phase": 2, "generation": 0xffffffff, "free_bytes": "18446744073709551615", "next_block": 8388608, "total_blocks": 8388608}),
        ("status_idle", 2, struct.pack("<BBHIQ", 0, 0, 0, 1, 0) + bytes(24),
         {**golden["status"], "mode": 0, "phase": 0, "generation": 1, "free_bytes": "0", "active_id": None, "next_block": 0, "total_blocks": 0}),
        ("list_empty", 3, struct.pack("<IIHH", 1, 0xffffffff, 0, 0),
         {"request_type": 3, "generation": 1, "next_cursor": None, "items": []}),
        ("progress_u32_max", 17, ID + struct.pack("<III", 8388608, 8388608, 0xffffffff),
         {"request_type": 17, "id": song_id, "next_block": 8388608, "total_blocks": 8388608, "saved_bytes": 0xffffffff}),
        ("delete_absent", 20, ID + bytes(4), {"request_type": 20, "id": song_id, "deleted": False}),
    ]
    for name, kind, payload, expected in boundaries:
        result["responses"].append({"name": name, "uart_hex": frame(0x80, bytes((kind, 0, 0, 0)) + payload).hex(), "json": expected})
    result["responses"].append({"name": "error_null", "uart_hex": frame(0xff, struct.pack("<BBHI", 18, 0, 6, 0xffffffff)).hex(),
                                "json": {"request_type": 18, "code": 6, "next_block": None}})
    return result


def header(data: dict) -> str:
    lines = ["/* Generated by tools/score_vectors.py; independent struct/zlib frames. */",
             "#ifndef SCORE_TEST_VECTORS_H", "#define SCORE_TEST_VECTORS_H",
             "typedef struct { const char *name, *uart_hex, *ble_hex; } score_test_vector_t;",
             "static const score_test_vector_t request_vectors[] = {"]
    for v in data["requests"]:
        lines.append(f'    {{"{v["name"]}", "{v["uart_hex"]}", "{v["ble_hex"]}"}},')
    lines.extend(["};", "static const score_test_vector_t response_vectors[] = {"])
    for v in data["responses"]:
        lines.append(f'    {{"{v["name"]}", "{v["uart_hex"]}", ""}},')
    lines.extend(["};", "#endif", ""])
    return "\n".join(lines)


def main() -> None:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--write", action="store_true")
    p.add_argument("--check", action="store_true")
    p.add_argument("--verify-json", type=Path)
    args = p.parse_args()
    data = build()
    artifacts = {"uart-v2-golden.json": json.dumps(data, indent=2, ensure_ascii=False) + "\n", "score_test_vectors.h": header(data)}
    if args.write:
        DEST.mkdir(parents=True, exist_ok=True)
        for name, text in artifacts.items():
            (DEST / name).write_text(text, encoding="utf-8", newline="\n")
    if args.check or not args.write:
        for name, text in artifacts.items():
            if (DEST / name).read_text(encoding="utf-8") != text:
                raise SystemExit(f"stale vector: {name}; review fixture/spec changes before --write")
        print("C/Python/web golden source and generated frames: PASS")
    if args.verify_json:
        actual = json.loads(subprocess.check_output([str(args.verify_json.resolve()), "--vectors"], text=True, encoding="utf-8"))
        expected = {v["name"]: v["json"] for v in data["responses"]}
        if actual != expected:
            raise SystemExit("C response JSON differs from the existing web golden fixture")
        print("C response JSON vs web golden fixture and independent boundary vectors: PASS")


if __name__ == "__main__":
    main()
