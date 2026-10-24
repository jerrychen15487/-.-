#include "midi_codec.h"
#include "midi_descriptors.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>

static midi_frame_t captured[64];
static size_t count;
static void collect(const midi_frame_t *frame, void *arg)
{
    (void)arg;
    assert(count < 64);
    captured[count++] = *frame;
}

static void golden_frames(void)
{
    static const uint8_t input[][4] = {
        {0x09,0x90,0x3c,0x64}, {0x08,0x80,0x3c,0x40},
        {0x09,0x90,0x3c,0x00}, {0x0b,0xb0,0x40,0x7f},
        {0x0b,0xb0,0x40,0x20}, {0x0b,0xb0,0x40,0},
        {0x59,0x97,0,1}, {0xfb,0xbf,0x43,0x7f},
        {0x0c,0xc0,0x02,0x7f},
    };
    static const uint8_t expected[][6] = {
        {1,0,0x3c,0x64,0,0}, {2,0,0x3c,0x40,0,0},
        {2,0,0x3c,0,0,0}, {3,0,0x40,0x7f,0,0},
        {3,0,0x40,0x20,0,0}, {3,0,0x40,0,0,0},
        {1,0x57,0,1,0,0}, {3,0xff,0x43,0x7f,0,0},
        {5,0,2,0,0,0},
    };
    count = 0;
    midi_decode_stats_t s = midi_decode_transfer(&input[0][0], sizeof(input), collect, NULL);
    assert(s.emitted == 9 && !s.skipped && !s.invalid && count == 9);
    for (size_t i = 0; i < count; ++i) assert(memcmp(captured[i].bytes, expected[i], 6) == 0);
}

static void ranges_and_reserves(void)
{
    const uint8_t dynamics[] = {0,1,32,63,64,100,126,127};
    for (unsigned route = 0; route < 256; ++route) {
        for (unsigned key = 0; key < 128; ++key) {
            for (size_t v = 0; v < sizeof(dynamics); ++v) {
                uint8_t p[] = {(uint8_t)((route & 0xf0) | 9),
                               (uint8_t)(0x90 | (route & 15)), (uint8_t)key, dynamics[v]};
                midi_frame_t out = {{0xff,0xff,0xff,0xff,0xff,0xff}};
                assert(midi_decode_packet(p, &out) == MIDI_DECODE_OK);
                assert(out.bytes[0] == (dynamics[v] ? MIDI_NOTE_ON : MIDI_NOTE_OFF));
                assert(out.bytes[1] == route && out.bytes[2] == key && out.bytes[3] == dynamics[v]);
                assert(!out.bytes[4] && !out.bytes[5]);
                p[0] = (p[0] & 0xf0) | 8;
                p[1] = 0x80 | (route & 15);
                assert(midi_decode_packet(p, &out) == MIDI_DECODE_OK && out.bytes[0] == MIDI_NOTE_OFF);
            }
        }
    }
    /* Preserve every controller number and every continuous value, not just pedals. */
    for (unsigned cc = 0; cc < 128; ++cc) for (unsigned value = 0; value < 128; ++value) {
        uint8_t p[] = {0x0b,0xb0,(uint8_t)cc,(uint8_t)value};
        midi_frame_t out;
        assert(midi_decode_packet(p, &out) == MIDI_DECODE_OK);
        assert(out.bytes[0] == 3 && out.bytes[2] == cc && out.bytes[3] == value);
        assert(!out.bytes[4] && !out.bytes[5]);
    }
}

static void malformed_and_unsupported(void)
{
    uint8_t input[] = {
        9,0x90,60,100, /* valid */
        8,0x90,60,100, /* CIN/status mismatch */
        9,0x90,128,100, /* bad key */
        9,0x90,60,128, /* bad data */
        0xe,0xe0,0,64, /* pitch bend, reserved for later */
        4,0xf0,1,2,   /* SysEx */
        0xf,0xf8,0,0, /* realtime */
        0xc,0xb0,0,0, /* CIN/status mismatch */
        0xb,0xb0,64,32,
    };
    count = 0;
    midi_decode_stats_t s = midi_decode_transfer(input, sizeof(input), collect, NULL);
    assert(s.emitted == 2 && s.invalid == 4 && s.skipped == 3 && count == 2);
    assert(captured[1].bytes[2] == 64 && captured[1].bytes[3] == 32);
    for (unsigned program = 0; program < 128; ++program) {
        uint8_t pc[] = {0x0c, 0xc0, (uint8_t)program, 0xff};
        midi_frame_t out;
        assert(midi_decode_packet(pc, &out) == MIDI_DECODE_OK);
        assert(out.bytes[0] == MIDI_PROGRAM_CHANGE && out.bytes[2] == program);
        assert(out.bytes[3] == 0 && out.bytes[4] == 0 && out.bytes[5] == 0);
    }
    for (size_t length = 1; length < sizeof(input); ++length) if (length % 4) {
        count = 0;
        s = midi_decode_transfer(input, length, collect, NULL);
        assert(s.invalid == 1 && count == 0);
    }
    assert(midi_decode_transfer(NULL, 4, collect, NULL).invalid == 1);
    assert(midi_decode_transfer(input, 4, NULL, NULL).invalid == 1);
    assert(midi_decode_transfer(NULL, 0, collect, NULL).invalid == 0);
}

static void burst(void)
{
    uint8_t packets[64 * 4];
    for (unsigned i = 0; i < 64; ++i) {
        packets[i * 4] = 9; packets[i * 4 + 1] = 0x90;
        packets[i * 4 + 2] = (uint8_t)i; packets[i * 4 + 3] = 127;
    }
    count = 0;
    assert(midi_decode_transfer(packets, sizeof(packets), collect, NULL).emitted == 64);
    for (unsigned i = 0; i < 64; ++i) assert(captured[i].bytes[2] == i);
}

static void piano_pedal_regression(void)
{
    /* session-02 MIDI-OX: five press/release cycles, each transition is
     * B0 followed by E2/E3/E4/E5. USB headers below are SYNTHETIC Cable 0,
     * not a capture of this piano's USB transport. */
    static const uint8_t cycle[][4] = {
        {0x0b,0xb0,0x40,0x60}, {0x0e,0xe2,0x40,0x60},
        {0x0e,0xe3,0x40,0x60}, {0x0e,0xe4,0x40,0x60},
        {0x0e,0xe5,0x40,0x60}, {0x0b,0xb0,0x40,0x00},
        {0x0e,0xe2,0x40,0x00}, {0x0e,0xe3,0x40,0x00},
        {0x0e,0xe4,0x40,0x00}, {0x0e,0xe5,0x40,0x00},
    };
    uint8_t packets[5 * sizeof(cycle)];
    for (size_t i = 0; i < 5; ++i) memcpy(packets + i * sizeof(cycle), cycle, sizeof(cycle));

    /* Every event-aligned split, including splitting an action group.
     * Prefix output must be immediate; don't wait for its following bends. */
    for (size_t split = 0; split <= sizeof(packets); split += 4) {
        count = 0;
        midi_decode_stats_t first = midi_decode_transfer(packets, split, collect, NULL);
        size_t prefix_events = (split / 4 + 4) / 5;
        assert(first.emitted == prefix_events && count == prefix_events && !first.invalid);
        midi_decode_stats_t rest = midi_decode_transfer(packets + split, sizeof(packets) - split,
                                                        collect, NULL);
        assert(first.emitted + rest.emitted == 10 && count == 10);
        assert(first.skipped + rest.skipped == 40 && !rest.invalid);
        for (size_t i = 0; i < count; ++i) {
            const uint8_t expected[] = {3,0,0x40,(uint8_t)(i % 2 ? 0 : 0x60),0,0};
            assert(memcmp(captured[i].bytes, expected, sizeof(expected)) == 0);
        }
    }

    /* Deliberately constructed edge case, NOT observed in the capture:
     * interleaved notes and missing group members must not get swallowed.
     * Cable 5 also demonstrates that the source cable is not hardcoded. */
    static const uint8_t interleaved[][4] = {
        {0x5b,0xb0,0x40,0x60},
        {0x5e,0xe2,0x40,0x60},
        {0x59,0x90,0x6b,0x08},
        {0x5e,0xe4,0x40,0x60}, /* E3/E5 intentionally absent */
        {0x5b,0xb0,0x40,0x00},
        {0x5e,0xe3,0x40,0x00},
        {0x58,0x80,0x6b,0x00},
    };
    static const uint8_t expected[][6] = {
        {3,0x50,0x40,0x60,0,0}, {1,0x50,0x6b,0x08,0,0},
        {3,0x50,0x40,0x00,0,0}, {2,0x50,0x6b,0x00,0,0},
    };
    static const size_t prefix_counts[] = {0,1,1,2,2,3,3,4};
    const uint8_t *bytes = &interleaved[0][0];
    for (size_t split = 0; split <= sizeof(interleaved); split += 4) {
        count = 0;
        midi_decode_stats_t first = midi_decode_transfer(bytes, split, collect, NULL);
        assert(first.emitted == prefix_counts[split / 4] && count == first.emitted && !first.invalid);
        midi_decode_stats_t rest = midi_decode_transfer(bytes + split, sizeof(interleaved) - split,
                                                        collect, NULL);
        assert(first.emitted + rest.emitted == 4 && count == 4);
        assert(first.skipped + rest.skipped == 3 && !rest.invalid);
        for (size_t i = 0; i < count; ++i) assert(memcmp(captured[i].bytes, expected[i], 6) == 0);
    }
}

static void descriptors(void)
{
    /* Composite config: an unrelated HID interface precedes MIDI interface 3. */
    uint8_t config[] = {
        9,2,0,0,2,1,0,0x80,50,
        9,4,0,0,0,3,1,1,0,
        9,4,3,0,1,1,3,0,0,
        7,0x24,1,0,1,7,0,
        9,5,0x83,2,64,0,0,0,0,
        5,0x25,1,1,1,
    };
    config[2] = sizeof(config);
    midi_endpoint_t ep;
    assert(midi_find_endpoint(config, sizeof(config), &ep));
    assert(ep.interface_number == 3 && ep.alternate_setting == 0 && ep.endpoint == 0x83 && ep.max_packet_size == 64);
    config[21] = 1; /* Alternate settings need SET_INTERFACE, not supported in v1. */
    assert(!midi_find_endpoint(config, sizeof(config), &ep));
    config[21] = 0;
    for (size_t length = 0; length < sizeof(config); ++length) assert(!midi_find_endpoint(config, length, &ep));
    config[31] = 2; /* bcdMSC 2.0 */
    assert(!midi_find_endpoint(config, sizeof(config), &ep));
    config[31] = 1;
    config[36] = 3; /* OUT instead of IN */
    assert(!midi_find_endpoint(config, sizeof(config), &ep));
    config[36] = 0x83;
    config[37] = 3; /* interrupt instead of bulk */
    assert(!midi_find_endpoint(config, sizeof(config), &ep));
    config[37] = 2;
    const uint8_t sizes[] = {8,16,32,64};
    for (size_t i = 0; i < sizeof(sizes); ++i) {
        config[38] = sizes[i];
        assert(midi_find_endpoint(config, sizeof(config), &ep) && ep.max_packet_size == sizes[i]);
    }
    config[38] = 63;
    assert(!midi_find_endpoint(config, sizeof(config), &ep));
    config[38] = 64;
    config[34] = 0; /* bad descriptor length */
    assert(!midi_find_endpoint(config, sizeof(config), &ep));
    config[34] = 9;
    config[43] = 100; /* truncated class endpoint descriptor, after selected EP */
    assert(!midi_find_endpoint(config, sizeof(config), &ep));
}

int main(void)
{
    golden_frames(); puts("PASS golden frames and batched messages");
    ranges_and_reserves(); puts("PASS all routes/notes, velocity boundaries, all CC values, reserves");
    malformed_and_unsupported(); puts("PASS invalid and unsupported messages");
    burst(); puts("PASS 64-event order");
    piano_pedal_regression(); puts("PASS piano pedal cycles, split transfers, immediate output, interleaved notes and nonzero cable");
    descriptors(); puts("PASS composite descriptors, endpoint selection, invalid descriptors");
    puts("All desktop tests passed (no hardware timing assertion).");
    return 0;
}
