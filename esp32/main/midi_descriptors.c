#include "midi_descriptors.h"

static uint16_t le16(const uint8_t *p) { return (uint16_t)(p[0] | ((uint16_t)p[1] << 8)); }

bool midi_find_endpoint(const uint8_t *data, size_t length, midi_endpoint_t *out)
{
    if (!data || !out || length < 9 || data[0] < 9 || data[1] != 2) return false;
    const size_t total = le16(data + 2);
    if (total < 9 || total > length) return false;
    bool candidate = false, midi1 = false, found = false;
    midi_endpoint_t current = {0}, selected = {0};
    for (size_t i = 0; i < total;) {
        if (total - i < 2 || data[i] < 2 || data[i] > total - i) return false;
        const uint8_t *d = data + i;
        if (d[1] == 4) {
            if (d[0] < 9) return false;
            /* Claim does not issue SET_INTERFACE; v1 uses the default alt 0. */
            candidate = d[3] == 0 && d[5] == 1 && d[6] == 3 && d[7] == 0;
            midi1 = false;
            current = (midi_endpoint_t){.interface_number = d[2], .alternate_setting = d[3]};
        } else if (candidate && d[1] == 0x24 && d[0] >= 3 && d[2] == 1) {
            if (d[0] < 7) return false;
            midi1 = le16(d + 3) == 0x0100;
        } else if (candidate && midi1 && d[1] == 5) {
            if (d[0] < 7) return false;
            uint16_t mps = le16(d + 4);
            /* S3 full-speed bulk endpoints have MPS 8,16,32,64. */
            if (!found && (d[2] & 0x80) && (d[2] & 0x0f) && !(d[2] & 0x70) &&
                (d[3] & 3) == 2 && (mps == 8 || mps == 16 || mps == 32 || mps == 64)) {
                current.endpoint = d[2];
                current.max_packet_size = mps;
                selected = current;
                found = true;
            }
        }
        i += d[0];
    }
    if (found) *out = selected;
    return found;
}
