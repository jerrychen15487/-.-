#pragma once
#include <stddef.h>
#include <stdint.h>

enum {
    MIDI_FRAME_SIZE = 6,
    MIDI_NOTE_ON = 1,
    MIDI_NOTE_OFF = 2,
    MIDI_CONTROL = 3,
    MIDI_PITCH_BEND = 4,
    MIDI_PROGRAM_CHANGE = 5,
};
typedef struct { uint8_t bytes[MIDI_FRAME_SIZE]; } midi_frame_t;
typedef enum { MIDI_DECODE_OK, MIDI_DECODE_SKIP, MIDI_DECODE_INVALID } midi_decode_t;
typedef struct { size_t emitted, skipped, invalid; } midi_decode_stats_t;
typedef void (*midi_emit_fn)(const midi_frame_t *frame, void *context);

midi_decode_t midi_decode_packet(const uint8_t packet[4], midi_frame_t *frame);
/* Length must be a multiple of four. A malformed transfer emits nothing.
 * emit must copy the frame before returning; the pointer is transient. */
midi_decode_stats_t midi_decode_transfer(const uint8_t *data, size_t length,
                                        midi_emit_fn emit, void *context);
