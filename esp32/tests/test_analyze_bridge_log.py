import unittest

from tools.analyze_bridge_log import parse


def sample(in_count, sent, **overrides):
    fields = dict(in_=in_count, sent=sent, skip=0, invalid=0, full=0,
                  cancel=0, usb_err=0, spi_err=0, peak=2, max_us=365,
                  over_5ms=0, sessions=1, span_ms=1000)
    fields.update(overrides)
    return "I (5000) bridge: " + " ".join(
        f"{'in' if key == 'in_' else key}={value}"
        for key, value in fields.items())


class BridgeLogTest(unittest.TestCase):
    def test_consecutive_duplicate_rom_banner_is_one_boot(self):
        log = "\n".join(("ESP-ROM:esp32s3-20210327",
                         "ESP-ROM:esp32s3-20210327",
                         "I (800) midi_usb: address=1 interface=1",
                         sample(420, 420)))
        result = parse(log)
        self.assertEqual(result["boot_count"], 1)
        self.assertEqual(result["last"]["sent"], 420)

    def test_uses_last_enumerated_boot(self):
        log = "\n".join(("ESP-ROM:esp32s3-20210327", "ENUM: CHECK_CONFIG FAILED",
                         "ESP-ROM:esp32s3-20210327",
                         "I (800) midi_usb: address=1 interface=1",
                         sample(67, 67), sample(146, 146)))
        result = parse(log)
        self.assertEqual(result["boot_count"], 2)
        self.assertEqual(result["last"]["in"], 146)
        self.assertEqual(result["sample_count"], 2)

    def test_rejects_unenumerated_log(self):
        with self.assertRaises(ValueError):
            parse("ESP-ROM:esp32s3-20210327\n" + sample(1, 1))

    def test_note_on_stats_are_kept_separate(self):
        log = "\n".join(("ESP-ROM:esp32s3-20210327",
                         "I (800) midi_usb: address=1 interface=1",
                         sample(4, 4),
                         "I (5001) bridge: usb_note_on n=2 min_us=100 "
                         "mean_us=120 max_us=140 jitter_us=40 over_5ms=0"))
        result = parse(log)
        self.assertEqual(result["note_on"]["n"], 2)
        self.assertEqual(result["note_on"]["jitter_us"], 40)


if __name__ == "__main__":
    unittest.main()
