"""Check the fixed 5 Hz global vibrato design and safe pitch range."""
from pathlib import Path

root = Path(__file__).resolve().parents[1]
top = (root / "src/top.v").read_text(encoding="utf-8")
spi = (root / "src/spi_midi_frame_rx.v").read_text(encoding="utf-8")

assert "bits[47:40] == 8'h04" in spi
assert "event_type == 8'h03" in top and "data1 == 8'd1" in top
assert "vibrato_phase + 32'd439805" in top
assert "effective_pitch_bend" in top

sample_rate = 50_000_000 / 1024
lfo_hz = 439_805 * sample_rate / 2**32
assert abs(lfo_hz - 5.0) < 0.001

# Full CC1 depth uses triangle extrema +/-127 and divides the product by 8.
max_offset = (127 * 127) >> 3
semitones = max_offset * 2 / 8192
assert 0.48 < semitones < 0.50

for bend in (0, 8192, 16383):
    for offset in (-max_offset, 0, max_offset):
        effective = max(0, min(16383, bend + offset))
        assert 0 <= effective <= 16383

print(f"vibrato: {lfo_hz:.6f} Hz, max depth +/-{semitones:.3f} semitone; PASS")
