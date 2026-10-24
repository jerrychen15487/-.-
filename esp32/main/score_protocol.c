#include "score_protocol.h"

#include <assert.h>
#include <string.h>

uint16_t score_get_u16(const uint8_t *p)
{ return (uint16_t)((uint16_t)p[0] | (uint16_t)((uint16_t)p[1] << 8)); }
uint32_t score_get_u32(const uint8_t *p)
{ return (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24); }
uint64_t score_get_u64(const uint8_t *p)
{ return (uint64_t)score_get_u32(p) | ((uint64_t)score_get_u32(p + 4) << 32); }
void score_put_u16(uint8_t *p, uint16_t v)
{ p[0] = (uint8_t)v; p[1] = (uint8_t)(v >> 8); }
void score_put_u32(uint8_t *p, uint32_t v)
{ p[0] = (uint8_t)v; p[1] = (uint8_t)(v >> 8); p[2] = (uint8_t)(v >> 16); p[3] = (uint8_t)(v >> 24); }
void score_put_u64(uint8_t *p, uint64_t v)
{ score_put_u32(p, (uint32_t)v); score_put_u32(p + 4, (uint32_t)(v >> 32)); }

uint32_t score_crc32(const uint8_t *data, size_t len)
{
    uint32_t crc = UINT32_MAX;
    for (size_t i = 0; i < len; ++i) {
        crc ^= data[i];
        for (unsigned bit = 0; bit < 8; ++bit)
            crc = (crc >> 1) ^ ((0u - (crc & 1u)) & UINT32_C(0xedb88320));
    }
    return crc ^ UINT32_MAX;
}

size_t score_encode(uint8_t *out, size_t cap, uint8_t type, uint32_t session,
                    uint32_t seq, const uint8_t *payload, size_t len)
{
    if (!out || len > SCORE_MAX_PAYLOAD || cap < len + 20u || (len && !payload)) return 0;
    /* memmove allows a caller to build the payload directly at out + 16. */
    if (len) memmove(out + 16, payload, len);
    out[0] = 0xa5; out[1] = 0x5a; out[2] = SCORE_VERSION; out[3] = type;
    score_put_u32(out + 4, session); score_put_u32(out + 8, seq);
    score_put_u16(out + 12, (uint16_t)len); score_put_u16(out + 14, 0);
    score_put_u32(out + 16 + len, score_crc32(out + 2, len + 14));
    return len + 20;
}

bool score_decode(const uint8_t *data, size_t len, score_frame_t *frame)
{
    if (!data || !frame || len < 20 || len > SCORE_MAX_FRAME ||
        data[0] != 0xa5 || data[1] != 0x5a || data[2] != SCORE_VERSION ||
        score_get_u16(data + 14) != 0) return false;
    uint16_t n = score_get_u16(data + 12);
    if (n > SCORE_MAX_PAYLOAD || len != (size_t)n + 20 ||
        score_get_u32(data + 16 + n) != score_crc32(data + 2, (size_t)n + 14)) return false;
    *frame = (score_frame_t){data[3], score_get_u32(data + 4),
                             score_get_u32(data + 8), data + 16, n};
    return true;
}

static void consume(score_stream_t *s, size_t n)
{
    s->used -= n;
    if (s->used) memmove(s->buffer, s->buffer + n, s->used);
}

static void parse(score_stream_t *s, score_frame_callback_t callback, void *ctx)
{
    while (s->used) {
        if (s->buffer[0] != 0xa5 || (s->used >= 2 && s->buffer[1] != 0x5a)) {
            ++s->dropped; consume(s, 1); continue;
        }
        if (s->used < 16) return;
        uint16_t n = score_get_u16(s->buffer + 12);
        if (s->buffer[2] != SCORE_VERSION || score_get_u16(s->buffer + 14) || n > SCORE_MAX_PAYLOAD) {
            ++s->bad_frames; ++s->dropped; consume(s, 1); continue;
        }
        if (s->used < (size_t)n + 20) return;
        score_frame_t frame;
        if (!score_decode(s->buffer, (size_t)n + 20, &frame)) {
            ++s->bad_frames; ++s->dropped; consume(s, 1); continue;
        }
        if (callback) callback(&frame, ctx);
        consume(s, (size_t)n + 20);
    }
}

void score_stream_feed(score_stream_t *s, const uint8_t *data, size_t len,
                       uint32_t now_ms, uint32_t gap_ms,
                       score_frame_callback_t callback, void *ctx)
{
    if (!s || (len && !data)) return;
    if (s->used && gap_ms && (uint32_t)(now_ms - s->last_ms) >= gap_ms) {
        s->dropped += (uint32_t)s->used; s->used = 0; ++s->timeouts;
    }
    if (len) s->last_ms = now_ms;
    for (size_t i = 0; i < len; ++i) {
        /* Invariant: parse returns only with an incomplete candidate. It
         * rejects lengths >1024 at the header, and consumes every complete
         * frame (valid or invalid) by 1044 bytes, so one byte always fits. */
        assert(s->used < sizeof(s->buffer));
        s->buffer[s->used++] = data[i];
        parse(s, callback, ctx);
    }
}

bool score_is_request(uint8_t type)
{
    return type == SCORE_CAPS || type == SCORE_STATUS || type == SCORE_LIST ||
           (type >= SCORE_BEGIN && type <= SCORE_DELETE);
}

bool score_song_id_valid(const uint8_t id[16])
{
    if (!id) return false;
    for (size_t i = 0; i < 16; ++i) if (id[i]) return true;
    return false;
}

bool score_changed_valid(const score_frame_t *frame)
{
    return frame && frame->type == SCORE_CHANGED && !frame->session && !frame->seq &&
           frame->payload && frame->payload_len == 8 && score_get_u32(frame->payload) &&
           frame->payload[4] <= 3 && frame->payload[5] <= 2 && !score_get_u16(frame->payload + 6);
}

bool score_title_valid(const uint8_t *data, size_t len)
{
    if (!data || !len || len > SCORE_MAX_TITLE_BYTES) return false;
    size_t i = 0, count = 0;
    while (i < len) {
        uint32_t c = data[i++], min = 0;
        unsigned tails = 0;
        if (c >= 0x80) {
            if (c >= 0xc2 && c <= 0xdf) { tails = 1; c &= 0x1f; min = 0x80; }
            else if (c >= 0xe0 && c <= 0xef) { tails = 2; c &= 0x0f; min = 0x800; }
            else if (c >= 0xf0 && c <= 0xf4) { tails = 3; c &= 7; min = 0x10000; }
            else return false;
            if (len - i < tails) return false;
            for (unsigned j = 0; j < tails; ++j) {
                uint8_t t = data[i++];
                if ((t & 0xc0) != 0x80) return false;
                c = (c << 6) | (t & 0x3f);
            }
            if (c < min || c > 0x10ffff || (c >= 0xd800 && c <= 0xdfff)) return false;
        }
        if (c < 0x20 || ++count > SCORE_MAX_TITLE_SCALARS) return false;
    }
    return true;
}
