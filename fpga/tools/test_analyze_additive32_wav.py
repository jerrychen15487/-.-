import tempfile
import unittest
import wave
from pathlib import Path

import numpy as np

from analyze_additive32_wav import analyze, parse_midi_ox_data1, pitch_warnings, read_pcm


class Additive32WavTest(unittest.TestCase):
    def test_midi_ox_hex_data1(self):
        self.assertEqual(parse_midi_ox_data1("3C"), 60)
        self.assertEqual(parse_midi_ox_data1("30"), 48)
        self.assertEqual(parse_midi_ox_data1("0x3c"), 60)
        for invalid in ("80", "3G", "123", ""):
            with self.assertRaises(Exception):
                parse_midi_ox_data1(invalid)

    def test_synthetic_32_harmonics(self):
        rate = 48000
        note = 48
        f0 = 440.0 * 2.0 ** ((note - 69) / 12.0)
        time = np.arange(rate * 3) / rate
        signal = sum(np.sin(2 * np.pi * f0 * n * time) / n for n in range(1, 33))
        pcm = (signal * 0.15 * 32767).astype("<i2")
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / "test.wav"
            with wave.open(str(path), "wb") as output:
                output.setnchannels(1)
                output.setsampwidth(2)
                output.setframerate(rate)
                output.writeframes(pcm.tobytes())
            actual_rate, samples = read_pcm(path, 0.5, 2.0, "auto")
            measured_f0, rows = analyze(actual_rate, samples, note)
        self.assertLess(abs(measured_f0 - f0), 0.6)
        self.assertEqual(len(rows), 32)
        self.assertGreater(rows[31]["above_floor_db"], 15)
        self.assertLess(rows[31]["relative_db"], -20)
        self.assertLess(abs(rows[31]["peak_hz"] - f0 * 32), 1)

    def test_rejects_h32_above_nyquist(self):
        with self.assertRaisesRegex(ValueError, "Nyquist"):
            analyze(44100, np.ones(44100), 96)

    def test_flags_likely_wrong_note(self):
        rows = [{"relative_db": 0.0}, {"relative_db": -6.0}]
        self.assertEqual(pitch_warnings(60, 261.63, rows), [])
        self.assertIn("check the played note", pitch_warnings(60, 274.75, rows)[0])
        rows[1]["relative_db"] = 53.4
        self.assertIn("octave mismatch", pitch_warnings(48, 130.84, rows)[0])


if __name__ == "__main__":
    unittest.main()
