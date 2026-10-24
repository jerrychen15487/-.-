"""Small offline checks for the F4 PSC2 page extraction path."""

from pathlib import Path
import struct
import unittest

from prepare_f4_demo import parse_pages, preview_png


ROOT = Path(__file__).resolve().parents[2]
SAMPLE = ROOT / "团队资料/piano-score-library/piano-score-library/public/scores/burgmuller-02.pseq"


class F4PagePreparationTests(unittest.TestCase):
    def test_real_score_has_nonblank_staff_page(self) -> None:
        pages = parse_pages(SAMPLE.read_bytes())
        page_id, notation, pixels = pages[0]
        self.assertEqual((page_id, notation, len(pixels)), (0, 1, 57600))
        self.assertGreater(sum(byte.bit_count() for byte in pixels), 1000)
        self.assertTrue(preview_png(pixels).startswith(b"\x89PNG\r\n\x1a\n"))

    def test_corrupt_bitmap_is_rejected(self) -> None:
        data = bytearray(SAMPLE.read_bytes())
        pages = parse_pages(data)
        self.assertTrue(pages)
        # The first bitmap byte is in a verified section; any change must
        # invalidate its section CRC before it can be offered to the display.
        section_count = struct.unpack_from("<H", data, 36)[0]
        bitmap_offset = None
        for index in range(section_count):
            kind, profile = struct.unpack_from("<IH", data, 64 + index * 32)
            if (kind, profile) == (6, 1):
                bitmap_offset = struct.unpack_from("<I", data, 64 + index * 32 + 8)[0]
                break
        self.assertIsNotNone(bitmap_offset)
        data[bitmap_offset] ^= 1
        with self.assertRaisesRegex(ValueError, "CRC mismatch"):
            parse_pages(data)


if __name__ == "__main__":
    unittest.main()
