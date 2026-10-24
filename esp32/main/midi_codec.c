#include "midi_codec.h"

midi_decode_t midi_decode_packet(const uint8_t p[4], midi_frame_t *out)
{
    if (!p || !out) return MIDI_DECODE_INVALID;
    const uint8_t cin = p[0] & 0x0f;
    if (cin != 0x08 && cin != 0x09 && cin != 0x0b && cin != 0x0c)
        return MIDI_DECODE_SKIP;
    if ((p[1] >> 4) != cin || p[2] > 127 ||
        (cin != 0x0c && p[3] > 127)) return MIDI_DECODE_INVALID;
    if (cin == 0x0c) {
        /* USB-MIDI CIN C has two MIDI bytes; the fourth USB byte is padding. */
        *out = (midi_frame_t){{MIDI_PROGRAM_CHANGE,
            (uint8_t)((p[0] & 0xf0) | (p[1] & 0x0f)), p[2], 0, 0, 0}};
        return MIDI_DECODE_OK;
    }
    uint8_t type = MIDI_CONTROL;
    if (cin == 0x08 || (cin == 0x09 && p[3] == 0)) type = MIDI_NOTE_OFF;
    else if (cin == 0x09) type = MIDI_NOTE_ON;
    *out = (midi_frame_t){{type, (uint8_t)((p[0] & 0xf0) | (p[1] & 0x0f)),
                         p[2], p[3], 0, 0}};
    return MIDI_DECODE_OK;
}

midi_decode_stats_t midi_decode_transfer(const uint8_t *data, size_t length,
                                        midi_emit_fn emit, void *context)
{
    midi_decode_stats_t stats = {0};
    if ((!data && length) || !emit || length % 4) {
        stats.invalid = 1;
        return stats;
    }
    for (size_t i = 0; i < length; i += 4) {
        midi_frame_t frame;
        switch (midi_decode_packet(data + i, &frame)) {
        case MIDI_DECODE_OK: emit(&frame, context); ++stats.emitted; break;
        case MIDI_DECODE_SKIP: ++stats.skipped; break;
        case MIDI_DECODE_INVALID: ++stats.invalid; break;
        }
    }
    return stats;
}
