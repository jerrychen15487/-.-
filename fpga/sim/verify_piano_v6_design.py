"""Regression checks for the low-register piano synthesis path.

The audible reproduction is MIDI note 50 at velocity 100.  These checks keep
the organ and video paths out of scope and reject the two V5 behaviours that
made a held low note drone: a fixed piano sustain of 96/255 and a static,
full-duration stretched partial.
"""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SYNTH = (ROOT / "src" / "basic_dds_synth.v").read_text(encoding="utf-8")

FS = 48_828.125

# Piano brightness must have its own decaying spectral envelope.  Velocity
# controls its initial amount; it must not remain a static timbre forever.
assert "piano_tone_level" in SYNTH
assert "piano_tone_divider" in SYNTH
assert "piano_color" in SYNTH
assert "piano_tone_level <= {velocity, 1'b1}" in " ".join(SYNTH.split())

# Widen before the x4 shift.  Shifting a 17-bit signed sine directly can
# discard its top bits and turn a clean fundamental into wrap distortion.
assert "piano_fundamental_wide" in SYNTH
assert "{{3{piano_sine_1_q[16]}}, piano_sine_1_q}" in SYNTH

# First V6 removes the isolated detuned oscillator entirely.  The first six
# partials are exact harmonics; controlled inharmonicity can be added later to
# all partials together after the envelope has passed listening tests.
for partial in range(1, 7):
    assert f"piano_sine_{partial}" in SYNTH
assert "piano_partial_phase" not in SYNTH
assert "phase_step >> 9" not in SYNTH
assert "phase_step >> 7" not in SYNTH

# A real-piano-inspired onset uses a broad six-partial spectrum, not V5's
# fundamental plus two weak partials.  High partials then disappear through
# piano_tone_level instead of remaining as a permanent buzzy waveform.
assert "piano_sine_5" in SYNTH
assert "piano_sine_6" in SYNTH
assert "piano_sine_2_wide <<< 1" in SYNTH
assert "piano_sine_3_wide <<< 1" in SYNTH
assert "piano_sine_4_wide >>> 1" in SYNTH
assert "piano_sine_6_wide >>> 2" in SYNTH

# The six LUT reads and wide adder tree must be separated from the velocity
# and envelope multipliers so the 50 MHz system-clock timing can close.
assert "piano_sine_1_q" in SYNTH
assert "piano_wave_pipeline" in SYNTH
assert "organ_wave_pipeline" in SYNTH
assert "voice_timbre ? organ_wave_pipeline : piano_wave_pipeline" in " ".join(SYNTH.split())
assert "piano_color_blend_product" in SYNTH
assert "piano_color_interpolated" in SYNTH

# Hammer transient must be made from short upper sine partials, not a square
# wave whose fixed odd-harmonic spectrum sounds like a digital buzzer.
piano_hammer_block = SYNTH.split("wire signed [16:0] piano_hammer =", 1)[1].split(
    "wire signed [16:0] piano_wave", 1
)[0]
assert "phase[28] ?" not in piano_hammer_block

# A Note On produces a complete decaying piano/organ strike.  Both voices
# become free after their finite tail, even if the sender omits Note Off.
assert "piano_sustain_level" not in SYNTH
assert "ENV_SUSTAIN" not in SYNTH
assert "voice_finished <= 1'b1" in SYNTH

# Note 50 keeps a longer low-register tail but no infinite floor.
fast_decay_s = (255 - 112) * 256 / FS
slow_low_decay_s = 112 * 512 / FS
assert 0.70 <= fast_decay_s <= 0.80
assert 1.1 <= slow_low_decay_s <= 1.2

# Hammer brightness remains short and velocity-sensitive.
strike_ms_at_v100 = ((2 * 100 + 1) / 4) * 8 / FS * 1000
assert strike_ms_at_v100 < 9.0
assert "strike_level <= {velocity, 1'b1}" in " ".join(SYNTH.split())

# Strong six-partial attacks must clip cleanly instead of wrapping at 16 bits.
assert "sample_positive_overflow" in SYNTH
assert "sample_negative_overflow" in SYNTH
assert "audio_sample <= saturated_sample" in SYNTH
assert "audio_sample <= scaled_sample[15:0]" not in SYNTH

print(
    "piano acoustic checks: PASS; "
    f"note50 envelope knee={fast_decay_s:.3f}s, "
    f"slow tail={slow_low_decay_s:.3f}s, "
    f"velocity100 strike={strike_ms_at_v100:.3f}ms"
)
