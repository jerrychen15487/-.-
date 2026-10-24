"""Fault-injection reference for the dedicated-card layout, not FPGA RTL.

Models sector-level interruption only. A real microSD may tear or remap a
sector, so FPGA hardware power-cut tests remain mandatory.
"""

from __future__ import annotations

import json
import struct
import zlib

SECTOR = 512
DIRECTORY_A = 16384
DIRECTORY_B = 16392
SLOT_BASE = 32768
SLOT_SECTORS = 8192
LOG_OFFSET = 4096
EMPTY = bytes(SECTOR)


class PowerCut(Exception):
    pass


class Card:
    def __init__(self) -> None:
        self.sectors: dict[int, bytes] = {}
        self.writes_left: int | None = None

    def read(self, lba: int) -> bytes:
        return self.sectors.get(lba, EMPTY)

    def write(self, lba: int, data: bytes) -> None:
        assert len(data) == SECTOR
        if self.writes_left == 0:
            raise PowerCut
        self.sectors[lba] = data
        if self.writes_left is not None:
            self.writes_left -= 1


def encode_directory(generation: int, entries: list[dict]) -> list[bytes]:
    payload = json.dumps(
        {"generation": generation, "entries": entries},
        sort_keys=True,
        separators=(",", ":"),
    ).encode("utf-8")
    assert len(payload) <= 7 * SECTOR
    body = payload.ljust(7 * SECTOR, b"\0")
    crc = zlib.crc32(body)
    marker = struct.pack("<4sIII", b"PSC2", 1, generation, crc)
    return [body[i * SECTOR : (i + 1) * SECTOR] for i in range(7)] + [
        marker.ljust(SECTOR, b"\0")
    ]


def read_directory(card: Card, base: int) -> dict | None:
    body = b"".join(card.read(base + i) for i in range(7))
    marker = card.read(base + 7)
    magic, version, generation, crc = struct.unpack_from("<4sIII", marker)
    if magic != b"PSC2" or version != 1 or zlib.crc32(body) != crc:
        return None
    try:
        value = json.loads(body.rstrip(b"\0"))
    except (ValueError, UnicodeDecodeError):
        return None
    if value.get("generation") != generation or not isinstance(value.get("entries"), list):
        return None
    return value


def mount(card: Card) -> tuple[int, dict] | None:
    candidates = [(base, item) for base in (DIRECTORY_A, DIRECTORY_B)
                  if (item := read_directory(card, base)) is not None]
    return max(candidates, key=lambda pair: pair[1]["generation"]) if candidates else None


def publish(card: Card, base: int, generation: int, entries: list[dict]) -> None:
    for offset, sector in enumerate(encode_directory(generation, entries)):
        card.write(base + offset, sector)


def data_lba(slot: int, block: int) -> int:
    assert 0 <= slot < 6 and 0 <= block < 4096
    return SLOT_BASE + slot * SLOT_SECTORS + block


def log_lba(slot: int, block: int) -> int:
    return data_lba(slot, block) + LOG_OFFSET


def append_block(card: Card, slot: int, epoch: int, block: int, data: bytes) -> None:
    assert 1 <= len(data) <= SECTOR
    padded = data.ljust(SECTOR, b"\0")
    card.write(data_lba(slot, block), padded)
    # The RTL must verify this readback before writing the progress record.
    assert card.read(data_lba(slot, block)) == padded
    header = struct.pack("<4sQIII", b"PROG", epoch, block, len(data), zlib.crc32(data))
    record = header + struct.pack("<I", zlib.crc32(header))
    card.write(log_lba(slot, block), record.ljust(SECTOR, b"\0"))
    assert card.read(log_lba(slot, block)) == record.ljust(SECTOR, b"\0")


def resume_block(card: Card, slot: int, epoch: int, total_blocks: int,
                 final_bytes: int) -> int:
    for block in range(total_blocks):
        raw = card.read(log_lba(slot, block))
        if raw[:4] != b"PROG":
            return block
        magic, saved_epoch, saved_block, length, crc = struct.unpack_from("<4sQIII", raw)
        record_crc = struct.unpack_from("<I", raw, 24)[0]
        expected_length = final_bytes if block == total_blocks - 1 else SECTOR
        if (magic != b"PROG" or saved_epoch != epoch or saved_block != block
                or length != expected_length or zlib.crc32(raw[:24]) != record_crc
                or zlib.crc32(card.read(data_lba(slot, block))[:length]) != crc):
            return block
    return total_blocks


def verify() -> None:
    card = Card()
    assert mount(card) is None
    publish(card, DIRECTORY_A, 1, [])
    assert mount(card) == (DIRECTORY_A, {"generation": 1, "entries": []})

    # Inactive-copy publication: any cut before marker keeps old catalog.
    for successful_writes in range(9):
        trial = Card()
        trial.sectors = card.sectors.copy()
        trial.writes_left = successful_writes
        try:
            publish(trial, DIRECTORY_B, 2, [{"slot": 0, "epoch": 10}])
        except PowerCut:
            pass
        active = mount(trial)
        assert active is not None
        assert active[1]["generation"] == (2 if successful_writes == 8 else 1)

    # DATA write only must not advance next_block; journal write can advance.
    for successful_writes in range(3):
        trial = Card()
        trial.writes_left = successful_writes
        try:
            append_block(trial, 0, 10, 0, b"A" * SECTOR)
        except PowerCut:
            pass
        assert resume_block(trial, 0, 10, 1, SECTOR) == (1 if successful_writes == 2 else 0)

    append_block(card, 0, 10, 0, b"A" * SECTOR)
    append_block(card, 0, 10, 1, b"tail")
    assert resume_block(card, 0, 10, 2, 4) == 2
    assert resume_block(card, 0, 11, 2, 4) == 0  # slot reused with new epoch
    card.sectors[data_lba(0, 1)] = b"wrong".ljust(SECTOR, b"\0")
    assert resume_block(card, 0, 10, 2, 4) == 1
    assert 8192 not in card.sectors
    print("PASS: directory cuts, DATA/ACK cuts, epoch reuse, corrupt data, diagnostic LBA untouched")


if __name__ == "__main__":
    verify()
