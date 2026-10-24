"""Validate a PSC2 profile-1 page and prepare a read-only FPGA demo ROM.

This is deliberately an offline F4 display fixture, not a score downloader or
storage implementation. It never modifies the source .pseq file.
"""

from __future__ import annotations

import argparse
from pathlib import Path
import struct
import zlib


SECTION = struct.Struct("<IHHIIIHHII")
PAGE = struct.Struct("<IHBBHHHHII")
PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ValueError(message)


def parse_pages(data: bytes) -> list[tuple[int, int, bytes]]:
    require(len(data) >= 64 and data[:4] == b"PSC2", "not a PSC2 file")
    major, minor = struct.unpack_from("<HH", data, 4)
    require((major, minor) == (2, 0), "unsupported PSC2 version")
    total_bytes = struct.unpack_from("<I", data, 8)[0]
    require(total_bytes == len(data), "PSC2 length mismatch")
    section_count, header_bytes = struct.unpack_from("<HH", data, 36)
    directory_offset = struct.unpack_from("<I", data, 40)[0]
    require(header_bytes == 64 and directory_offset == 64, "unsupported PSC2 header")
    require(section_count <= 32, "section count exceeds PSC2 maximum")
    directory_end = directory_offset + section_count * SECTION.size
    require(directory_end <= len(data), "truncated section directory")

    page_section = bitmap_section = None
    intervals = []
    for index in range(section_count):
        kind, profile, flags, offset, length, count, record_bytes, reserved, crc, reserved2 = (
            SECTION.unpack_from(data, directory_offset + index * SECTION.size)
        )
        require(reserved == 0 and reserved2 == 0, "nonzero section reserved field")
        require(flags == 1, "unsupported section flags")
        require(offset % 4 == 0 and offset >= directory_end, "invalid section offset")
        require(length <= len(data) - offset, "section exceeds file")
        require(zlib.crc32(data[offset : offset + length]) == crc, "section CRC mismatch")
        intervals.append((offset, offset + length))
        if kind == 5 and profile == 1:
            require(page_section is None, "duplicate profile-1 PAGE section")
            require(record_bytes == PAGE.size and length == count * PAGE.size, "bad PAGE size")
            page_section = (offset, count)
        if kind == 6 and profile == 1:
            require(bitmap_section is None, "duplicate profile-1 BITMAP section")
            require(record_bytes == 0 and count == 1, "bad BITMAP descriptor")
            bitmap_section = (offset, length)
    ordered = sorted(intervals)
    require(all(left[1] <= right[0] for left, right in zip(ordered, ordered[1:])),
            "overlapping sections")
    require(page_section is not None and bitmap_section is not None, "profile-1 page missing")

    bitmap_start, bitmap_length = bitmap_section
    pages = []
    page_start, page_count = page_section
    for index in range(page_count):
        page_id, profile, notation, fmt, width, height, stride, reserved, offset, length = (
            PAGE.unpack_from(data, page_start + index * PAGE.size)
        )
        require(profile == 1 and notation in (1, 2) and fmt == 1,
                "unsupported page profile/notation/format")
        require(width == 960 and height == 480 and stride == 120 and reserved == 0,
                "page is not profile-1 960x480 MONO1")
        require(length == stride * height, "page pixel length mismatch")
        require(bitmap_start <= offset and offset + length <= bitmap_start + bitmap_length,
                "page pixels lie outside BITMAP section")
        pages.append((page_id, notation, data[offset : offset + length]))
    require(len({page[0] for page in pages}) == len(pages), "duplicate page ID")
    return pages


def png_chunk(kind: bytes, payload: bytes) -> bytes:
    return struct.pack(">I", len(payload)) + kind + payload + struct.pack(
        ">I", zlib.crc32(kind + payload)
    )


def preview_png(page: bytes) -> bytes:
    """Render the exact 640x480 HDMI sampling map: source x=floor(3*x/2)."""
    rows = bytearray()
    for y in range(480):
        rows.append(0)  # PNG filter None
        for x in range(640):
            source_x = (3 * x) // 2
            source_byte = page[y * 120 + source_x // 8]
            black = (source_byte >> (7 - source_x % 8)) & 1
            rows.append(0 if black else 255)
    ihdr = struct.pack(">IIBBBBB", 640, 480, 8, 0, 0, 0, 0)
    return (PNG_SIGNATURE + png_chunk(b"IHDR", ihdr)
            + png_chunk(b"IDAT", zlib.compress(bytes(rows), 9))
            + png_chunk(b"IEND", b""))


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path, help="legal PSC2 .pseq sample")
    parser.add_argument("output_prefix", type=Path, help="writes .hex and .png here")
    parser.add_argument("--notation", type=int, choices=(1, 2), default=1,
                        help="1=staff, 2=numbered notation")
    parser.add_argument("--page-index", type=int, default=0,
                        help="zero-based page index within the selected notation")
    args = parser.parse_args()
    require(args.page_index >= 0, "negative page index")
    pages = [p for p in parse_pages(args.source.read_bytes()) if p[1] == args.notation]
    require(args.page_index < len(pages), "requested notation/page does not exist")
    page_id, _, pixels = pages[args.page_index]
    hex_path = args.output_prefix.with_suffix(".hex")
    png_path = args.output_prefix.with_suffix(".png")
    require(not hex_path.exists() and not png_path.exists(), "output already exists")
    hex_path.parent.mkdir(parents=True, exist_ok=True)
    hex_path.write_text("".join(f"{byte:02X}\n" for byte in pixels), encoding="ascii")
    png_path.write_bytes(preview_png(pixels))
    print(f"page_id={page_id} notation={args.notation} bytes={len(pixels)}")
    print(f"ROM={hex_path}")
    print(f"preview={png_path}")


if __name__ == "__main__":
    main()
