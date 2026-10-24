#include "score_protocol.h"
#include "vectors/score_test_vectors.h"

#include <assert.h>
#include <stdio.h>
#include <string.h>

static size_t unhex(const char *s, uint8_t *out)
{
    size_t n = strlen(s) / 2;
    for (size_t i = 0; i < n; ++i) { unsigned v; assert(sscanf(s + 2 * i, "%2x", &v) == 1); out[i] = (uint8_t)v; }
    return n;
}
typedef struct { size_t count; uint32_t seq; size_t bytes; } observed_t;
static void receive(const score_frame_t *f, void *ctx)
{
    observed_t *o = ctx;
    ++o->count; o->seq = f->seq; o->bytes += f->payload_len;
}
static void check_vector(const score_test_vector_t *v)
{
    uint8_t wire[SCORE_MAX_FRAME], out[SCORE_MAX_FRAME]; score_frame_t f;
    size_t n = unhex(v->uart_hex, wire);
    assert(score_decode(wire, n, &f));
    assert(score_encode(out, sizeof(out), f.type, f.session, f.seq, f.payload, f.payload_len) == n);
    assert(!memcmp(out, wire, n));
    for (size_t split = 0; split <= n; ++split) {
        score_stream_t s = {0}; observed_t o = {0};
        score_stream_feed(&s, wire, split, 1, 100, receive, &o);
        score_stream_feed(&s, wire + split, n - split, 2, 100, receive, &o);
        assert(o.count == 1 && s.used == 0);
    }
    assert(!score_decode(wire, n - 1, &f));
    wire[n - 1] ^= 1;
    assert(!score_decode(wire, n, &f));
}
int main(void)
{
    assert(score_crc32((const uint8_t *)"123456789", 9) == UINT32_C(0xcbf43926));
    assert(score_crc32(NULL, 0) == 0);
    for (size_t i = 0; i < sizeof(request_vectors) / sizeof(request_vectors[0]); ++i) check_vector(&request_vectors[i]);
    for (size_t i = 0; i < sizeof(response_vectors) / sizeof(response_vectors[0]); ++i) check_vector(&response_vectors[i]);
    uint8_t payload[SCORE_MAX_PAYLOAD], wire[SCORE_MAX_FRAME], out[SCORE_MAX_FRAME];
    for (size_t i = 0; i < sizeof(payload); ++i) payload[i] = (uint8_t)i;
    payload[500] = 0xa5; payload[501] = 0x5a;
    size_t n = score_encode(wire, sizeof(wire), SCORE_DATA, 0xffffffff, 0xffffffff, payload, sizeof(payload));
    assert(n == SCORE_MAX_FRAME);
    score_frame_t f;
    assert(score_decode(wire, n, &f) && f.payload_len == 1024 && f.session == UINT32_MAX);
    assert(!score_encode(out, n - 1, SCORE_DATA, 1, 1, payload, sizeof(payload)));
    assert(!score_encode(out, sizeof(out), SCORE_DATA, 1, 1, payload, 1025));
    score_stream_t s = {0}; observed_t o = {0};
    for (size_t i = 0; i < n; ++i) score_stream_feed(&s, wire + i, 1, (uint32_t)i, 100, receive, &o);
    assert(o.count == 1 && o.bytes == 1024 && s.used == 0);
    uint8_t noise[] = {0x55, 0xa5, 0xa5, 0x5a, 1, 0, 0};
    score_stream_feed(&s, noise, sizeof(noise), 1100, 100, receive, &o);
    score_stream_feed(&s, wire, n, 1101, 100, receive, &o);
    score_stream_feed(&s, wire, n, 1102, 100, receive, &o);
    assert(o.count == 3 && s.used == 0);
    /* CRC-corrupt frame with embedded magic followed by valid frame. */
    wire[n - 1] ^= 1;
    score_stream_feed(&s, wire, n, 1103, 100, receive, &o);
    wire[n - 1] ^= 1;
    score_stream_feed(&s, wire, n, 1104, 100, receive, &o);
    assert(o.count == 4 && s.used == 0 && s.bad_frames);
    score_stream_feed(&s, wire, 10, UINT32_MAX - 20, 100, receive, &o);
    score_stream_feed(&s, NULL, 0, 90, 100, receive, &o);
    assert(s.used == 0 && s.timeouts == 1);
    score_stream_feed(&s, wire, n, 91, 100, receive, &o);
    assert(o.count == 5);
    /* Reserved data is rejected even with recomputed valid CRC. */
    wire[14] = 1; score_put_u32(wire + n - 4, score_crc32(wire + 2, n - 6));
    assert(!score_decode(wire, n, &f));
    wire[14] = 0; wire[12] = 1; wire[13] = 4;
    score_stream_feed(&s, wire, 16, 92, 100, receive, &o);
    n = score_encode(wire, sizeof(wire), SCORE_CAPS, 1, 8, NULL, 0);
    score_stream_feed(&s, wire, n, 93, 100, receive, &o);
    assert(o.count == 6 && o.seq == 8);
    /* COMMIT may respond after 30 seconds. A gap clears only a partial frame,
     * never an already-consumed request or a fresh complete response. */
    n = unhex(response_vectors[5].uart_hex, wire);
    assert(s.used == 0);
    score_stream_feed(&s, wire, n, 30093, 100, receive, &o);
    assert(o.count == 7 && s.used == 0);
    score_stream_feed(&s, wire, 8, 30100, 100, receive, &o);
    score_stream_feed(&s, wire, n, 60200, 100, receive, &o);
    assert(o.count == 8 && s.used == 0 && s.timeouts == 2);
    /* Sweep every deletion and insertion in a small frame, then allow the
     * specified gap and require that the next complete frame is recovered. */
    n = score_encode(wire, sizeof(wire), SCORE_CAPS, 1, 99, NULL, 0);
    for (size_t pos = 0; pos < n; ++pos) {
        score_stream_t broken = {0}; observed_t recovered = {0};
        memcpy(out, wire, pos); memcpy(out + pos, wire + pos + 1, n - pos - 1);
        score_stream_feed(&broken, out, n - 1, 1, 100, receive, &recovered);
        assert(recovered.count == 0);
        score_stream_feed(&broken, wire, n, 102, 100, receive, &recovered);
        assert(recovered.count == 1 && recovered.seq == 99 && broken.used == 0);
        memset(&broken, 0, sizeof(broken)); memset(&recovered, 0, sizeof(recovered));
        memcpy(out, wire, pos); out[pos] = 0x7e; memcpy(out + pos + 1, wire + pos, n - pos);
        score_stream_feed(&broken, out, n + 1, 1, 100, receive, &recovered);
        size_t before = recovered.count;
        score_stream_feed(&broken, wire, n, 102, 100, receive, &recovered);
        assert(recovered.count == before + 1 && recovered.seq == 99 && broken.used == 0);
    }
    uint8_t endian[8]; score_put_u64(endian, UINT64_MAX - 1);
    assert(score_get_u64(endian) == UINT64_MAX - 1);
    assert(score_title_valid((const uint8_t *)"\xe6\xb5\x8b\xe8\xaf\x95\xf0\x9f\x8e\xb9", 10));
    assert(!score_title_valid((const uint8_t *)"\xed\xa0\x80", 3));
    assert(!score_title_valid((const uint8_t *)"\xc0\xaf", 2));
    assert(!score_title_valid((const uint8_t *)"\xf4\x90\x80\x80", 4));
    assert(!score_title_valid((const uint8_t *)"a\n", 2));
    memset(payload, 'x', 129); assert(!score_title_valid(payload, 129));
    uint8_t song_id[16] = {0};
    assert(!score_song_id_valid(song_id) && !score_song_id_valid(NULL));
    for (size_t i = 0; i < sizeof(song_id); ++i) {
        song_id[i] = 1;
        assert(score_song_id_valid(song_id));
        song_id[i] = 0;
    }
    uint8_t changed[8] = {1,0,0,0,3,2,0,0};
    f = (score_frame_t){SCORE_CHANGED, 0, 0, changed, 8};
    assert(score_changed_valid(&f) && !score_changed_valid(NULL));
    f.type = SCORE_ACK; assert(!score_changed_valid(&f)); f.type = SCORE_CHANGED;
    f.session = 1; assert(!score_changed_valid(&f)); f.session = 0;
    f.seq = 1; assert(!score_changed_valid(&f)); f.seq = 0;
    f.payload_len = 7; assert(!score_changed_valid(&f)); f.payload_len = 8;
    f.payload = NULL; assert(!score_changed_valid(&f)); f.payload = changed;
    changed[0] = 0; assert(!score_changed_valid(&f)); changed[0] = 1;
    changed[4] = 4; assert(!score_changed_valid(&f)); changed[4] = 3;
    changed[5] = 3; assert(!score_changed_valid(&f)); changed[5] = 2;
    changed[6] = 1; assert(!score_changed_valid(&f)); changed[6] = 0;
    changed[7] = 1; assert(!score_changed_valid(&f));
    /* A single externally supplied chunk can exceed storage several times;
     * invalid headers must be consumed before the next byte is appended. */
    uint8_t burst[3 * SCORE_MAX_FRAME];
    memset(burst, 0xa5, sizeof(burst));
    n = score_encode(burst + 2 * SCORE_MAX_FRAME, SCORE_MAX_FRAME, SCORE_DATA,
                     1, 100, payload, SCORE_MAX_PAYLOAD);
    memset(&s, 0, sizeof(s)); memset(&o, 0, sizeof(o));
    score_stream_feed(&s, burst, 2 * SCORE_MAX_FRAME + n, 1, 100, receive, &o);
    assert(o.count == 1 && o.seq == 100 && o.bytes == SCORE_MAX_PAYLOAD && s.used == 0);
    puts("score protocol: all vectors, splits, bounds, CRC, resync and UTF-8 PASS");
    return 0;
}
