#pragma once
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

typedef struct {
    uint8_t interface_number, alternate_setting, endpoint;
    uint16_t max_packet_size;
} midi_endpoint_t;
/* Finds first MIDI 1.0 streaming interface at alt 0 containing a bulk IN EP.
 * Accepts composite devices; never relies on VID/PID or fixed EP addresses. */
bool midi_find_endpoint(const uint8_t *configuration, size_t length, midi_endpoint_t *out);
