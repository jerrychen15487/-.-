#include "score_json.h"

#include <string.h>

/* Fixed-schema parser: no recursion, token arena, heap or persistent state.
 * All integer fields are canonical unsigned JSON integers (no exponent). */
typedef struct { const uint8_t *p, *end; } reader_t;
typedef struct { uint8_t *p; size_t used, cap; bool ok; } writer_t;

static void space(reader_t *r)
{
    while (r->p < r->end && (*r->p == ' ' || *r->p == '\t' || *r->p == '\r' || *r->p == '\n')) ++r->p;
}
static bool take(reader_t *r, uint8_t c)
{
    space(r);
    if (r->p == r->end || *r->p != c) return false;
    ++r->p; return true;
}
static int hex(uint8_t c)
{
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}
static bool hex4(reader_t *r, uint32_t *value)
{
    if ((size_t)(r->end - r->p) < 4) return false;
    uint32_t v = 0;
    for (unsigned i = 0; i < 4; ++i) {
        int h = hex(*r->p++);
        if (h < 0) return false;
        v = (v << 4) | (unsigned)h;
    }
    *value = v; return true;
}
static bool string(reader_t *r, uint8_t *out, size_t cap, size_t *len)
{
    if (!take(r, '"')) return false;
    size_t n = 0;
    bool closed = false;
    while (r->p < r->end) {
        uint8_t c = *r->p++;
        if (c == '"') { closed = true; break; }
        if (c < 0x20) return false;
        if (c == '\\') {
            if (r->p == r->end) return false;
            c = *r->p++;
            if (c == 'u') {
                uint32_t cp;
                if (!hex4(r, &cp)) return false;
                if (cp >= 0xd800 && cp <= 0xdbff) {
                    uint32_t low;
                    if ((size_t)(r->end - r->p) < 6 || r->p[0] != '\\' || r->p[1] != 'u') return false;
                    r->p += 2;
                    if (!hex4(r, &low) || low < 0xdc00 || low > 0xdfff) return false;
                    cp = 0x10000 + ((cp - 0xd800) << 10) + low - 0xdc00;
                } else if (cp >= 0xdc00 && cp <= 0xdfff) return false;
                if (cp < 0x20) return false;
                size_t bytes = cp < 0x80 ? 1 : cp < 0x800 ? 2 : cp < 0x10000 ? 3 : 4;
                if (cap - n < bytes) return false;
                if (bytes == 1) out[n++] = (uint8_t)cp;
                else {
                    out[n++] = (uint8_t)((bytes == 2 ? 0xc0 : bytes == 3 ? 0xe0 : 0xf0) | (cp >> (6 * (bytes - 1))));
                    for (size_t k = bytes - 1; k; --k) out[n++] = (uint8_t)(0x80 | ((cp >> (6 * (k - 1))) & 0x3f));
                }
                continue;
            }
            if (c != '"' && c != '\\' && c != '/') return false;
        }
        if (n == cap) return false;
        out[n++] = c;
    }
    if (!closed || !score_title_valid(out, n)) return false;
    *len = n; return true;
}
static bool number(reader_t *r, uint32_t *value)
{
    space(r);
    if (r->p == r->end || *r->p < '0' || *r->p > '9') return false;
    bool zero = *r->p == '0';
    uint32_t n = 0;
    size_t digits = 0;
    while (r->p < r->end && *r->p >= '0' && *r->p <= '9') {
        unsigned d = *r->p++ - '0';
        if (n > (UINT32_MAX - d) / 10 || (zero && digits)) return false;
        n = n * 10 + d; ++digits;
    }
    *value = n; return true;
}
static bool uuid(const uint8_t *s, size_t n, uint8_t out[16])
{
    if (n != 36) return false;
    size_t k = 0;
    for (size_t i = 0; i < 36;) {
        if (i == 8 || i == 13 || i == 18 || i == 23) {
            if (s[i++] != '-') return false;
        } else {
            uint8_t a = s[i++], b = s[i++];
            if ((a >= 'A' && a <= 'F') || (b >= 'A' && b <= 'F')) return false;
            int hi = hex(a), lo = hex(b);
            if (hi < 0 || lo < 0) return false;
            out[k++] = (uint8_t)((hi << 4) | lo);
        }
    }
    return score_song_id_valid(out);
}
enum field { F_ID, F_TITLE, F_GENERATION, F_CURSOR, F_LIMIT, F_TOTAL_BYTES,
             F_FILE_CRC, F_BLOCK_BYTES, F_PACKAGE_MAJOR, F_TOTAL_BLOCKS, F_CAPABILITIES, F_COUNT };
#define BIT(f) (UINT32_C(1) << (f))
typedef struct {
    uint8_t id[16], title[SCORE_MAX_TITLE_BYTES];
    size_t title_len;
    uint32_t n[F_COUNT - F_GENERATION];
} request_t;
static const char *const keys[F_COUNT] = {
    "id", "title", "generation", "cursor", "limit", "total_bytes", "file_crc",
    "block_bytes", "package_major", "total_blocks", "capabilities"
};
#define NUM(q, f) ((q).n[(f) - F_GENERATION])

static bool object(const score_frame_t *frame, uint32_t required, request_t *q)
{
    reader_t r = {frame->payload, frame->payload + frame->payload_len};
    if (!take(&r, '{')) return false;
    uint32_t seen = 0;
    for (;;) {
        uint8_t key[24]; size_t n;
        if (!string(&r, key, sizeof(key), &n)) return false;
        unsigned f;
        for (f = 0; f < F_COUNT; ++f)
            if (strlen(keys[f]) == n && !memcmp(keys[f], key, n)) break;
        if (f == F_COUNT || !(required & BIT(f)) || (seen & BIT(f)) || !take(&r, ':')) return false;
        seen |= BIT(f);
        if (f == F_ID) {
            uint8_t value[36];
            if (!string(&r, value, sizeof(value), &n) || !uuid(value, n, q->id)) return false;
        } else if (f == F_TITLE) {
            if (!string(&r, q->title, sizeof(q->title), &q->title_len)) return false;
        } else if (!number(&r, &q->n[f - F_GENERATION])) return false;
        space(&r);
        if (r.p == r.end) return false;
        if (*r.p == '}') { ++r.p; break; }
        if (*r.p++ != ',') return false;
    }
    space(&r);
    return r.p == r.end && seen == required;
}

bool score_request_from_ble(const score_frame_t *frame, uint8_t *out,
                            size_t cap, size_t *out_len)
{
    if (out_len) *out_len = 0;
    if (!frame || !out || !out_len || cap < 20 || !frame->session || !frame->seq ||
        frame->payload_len > SCORE_MAX_PAYLOAD || (frame->payload_len && !frame->payload) || !score_is_request(frame->type)) return false;
    if (frame->type == SCORE_CAPS || frame->type == SCORE_STATUS) {
        if (frame->payload_len) return false;
        *out_len = score_encode(out, cap, frame->type, frame->session, frame->seq, NULL, 0);
        return *out_len != 0;
    }
    if (frame->type == SCORE_DATA) {
        if (frame->payload_len < 21 || frame->payload_len > 20 + SCORE_BLOCK_BYTES ||
            !score_song_id_valid(frame->payload)) return false;
        *out_len = score_encode(out, cap, frame->type, frame->session, frame->seq, frame->payload, frame->payload_len);
        return *out_len != 0;
    }
    if (!frame->payload_len) return false;
    uint32_t required = BIT(F_ID);
    if (frame->type == SCORE_LIST) required = BIT(F_GENERATION) | BIT(F_CURSOR) | BIT(F_LIMIT);
    if (frame->type == SCORE_COMMIT) required |= BIT(F_TOTAL_BYTES) | BIT(F_FILE_CRC);
    if (frame->type == SCORE_BEGIN) required |= BIT(F_TITLE) | BIT(F_TOTAL_BYTES) | BIT(F_FILE_CRC) |
        BIT(F_BLOCK_BYTES) | BIT(F_PACKAGE_MAJOR) | BIT(F_TOTAL_BLOCKS) | BIT(F_CAPABILITIES);
    request_t q = {0};
    if (!object(frame, required, &q)) return false;
    uint8_t *p = out + 16;
    size_t n;
    switch (frame->type) {
    case SCORE_LIST:
        n = 12;
        if (NUM(q, F_LIMIT) != 1 || (!NUM(q, F_GENERATION) && NUM(q, F_CURSOR))) return false;
        if (cap < n + 20) return false;
        score_put_u32(p, NUM(q, F_GENERATION)); score_put_u32(p + 4, NUM(q, F_CURSOR));
        score_put_u16(p + 8, 1); score_put_u16(p + 10, 0);
        break;
    case SCORE_BEGIN: {
        uint32_t bytes = NUM(q, F_TOTAL_BYTES);
        n = 40 + q.title_len;
        if (bytes < 64 || NUM(q, F_BLOCK_BYTES) != SCORE_BLOCK_BYTES || NUM(q, F_PACKAGE_MAJOR) != 2 ||
            NUM(q, F_TOTAL_BLOCKS) != (uint32_t)(((uint64_t)bytes + 511) / 512) ||
            !NUM(q, F_CAPABILITIES) || (NUM(q, F_CAPABILITIES) & ~7u) || cap < n + 20) return false;
        memcpy(p, q.id, 16); score_put_u32(p + 16, bytes); score_put_u32(p + 20, NUM(q, F_FILE_CRC));
        score_put_u16(p + 24, SCORE_BLOCK_BYTES); score_put_u16(p + 26, 2);
        score_put_u32(p + 28, NUM(q, F_TOTAL_BLOCKS)); score_put_u32(p + 32, NUM(q, F_CAPABILITIES));
        score_put_u16(p + 36, (uint16_t)q.title_len); score_put_u16(p + 38, 0);
        memcpy(p + 40, q.title, q.title_len);
        break;
    }
    case SCORE_COMMIT:
        n = 24;
        if (NUM(q, F_TOTAL_BYTES) < 64 || cap < n + 20) return false;
        memcpy(p, q.id, 16); score_put_u32(p + 16, NUM(q, F_TOTAL_BYTES));
        score_put_u32(p + 20, NUM(q, F_FILE_CRC)); break;
    default:
        n = 16;
        if (cap < n + 20) return false;
        memcpy(p, q.id, n); break;
    }
    *out_len = score_encode(out, cap, frame->type, frame->session, frame->seq, p, n);
    return *out_len != 0;
}

static void bytes(writer_t *w, const void *data, size_t len)
{
    if (!w->ok || len > w->cap - w->used) { w->ok = false; return; }
    memcpy(w->p + w->used, data, len); w->used += len;
}
static void literal(writer_t *w, const char *s) { bytes(w, s, strlen(s)); }
static void integer(writer_t *w, uint64_t n)
{
    char b[20]; size_t i = sizeof(b);
    do { b[--i] = (char)('0' + n % 10); n /= 10; } while (n);
    bytes(w, b + i, sizeof(b) - i);
}
static void field(writer_t *w, const char *name, uint64_t n)
{ literal(w, ",\""); literal(w, name); literal(w, "\":"); integer(w, n); }
static void id(writer_t *w, const uint8_t *p)
{
    static const char digits[] = "0123456789abcdef";
    literal(w, "\"");
    for (unsigned i = 0; i < 16; ++i) {
        if (i == 4 || i == 6 || i == 8 || i == 10) literal(w, "-");
        char pair[2] = {digits[p[i] >> 4], digits[p[i] & 15]}; bytes(w, pair, 2);
    }
    literal(w, "\"");
}
static bool zeros(const uint8_t *p, size_t n)
{ for (size_t i = 0; i < n; ++i) if (p[i]) return false; return true; }
static void title(writer_t *w, const uint8_t *p, size_t n)
{
    literal(w, "\"");
    for (size_t i = 0; i < n; ++i) {
        if (p[i] == '\\' || p[i] == '"') literal(w, "\\");
        bytes(w, p + i, 1);
    }
    literal(w, "\"");
}
static bool progress(writer_t *w, const uint8_t *p, size_t n)
{
    if (n != 28 || !score_song_id_valid(p)) return false;
    uint32_t next = score_get_u32(p + 16), total = score_get_u32(p + 20), saved = score_get_u32(p + 24);
    uint64_t top = (uint64_t)next * 512;
    if (!total || total > (UINT32_MAX / 512u + 1u) || next > total || saved > top ||
        (next < total && saved != top) || (next == total && (saved <= top - 512 || saved < 64))) return false;
    literal(w, ",\"id\":"); id(w, p);
    field(w, "next_block", next); field(w, "total_blocks", total); field(w, "saved_bytes", saved);
    return true;
}
static bool caps(writer_t *w, const uint8_t *p, size_t n, uint16_t max_write)
{
    if (n < 36 || score_get_u16(p) != 2 || score_get_u16(p + 2) != 2 || score_get_u16(p + 4) != 1024 ||
        score_get_u16(p + 6) != 512 || max_write < 20 || max_write > 512) return false;
    uint16_t count = score_get_u16(p + 32), flags = score_get_u16(p + 34);
    if (count > 32 || n != (size_t)36 + count * 2 || !(flags & 1)) return false;
    for (unsigned i = 0; i < 6; ++i) if (!score_get_u32(p + 8 + 4 * i)) return false;
    for (unsigned i = 0; i < count; ++i) {
        if (!score_get_u16(p + 36 + 2 * i)) return false;
        for (unsigned j = 0; j < i; ++j)
            if (score_get_u16(p + 36 + 2 * j) == score_get_u16(p + 36 + 2 * i)) return false;
    }
    literal(w, ",\"protocol\":2,\"uart_version\":2,\"package_major\":2,\"max_payload\":1024,\"block_bytes\":512");
    field(w, "max_write", max_write);
    static const char *const names[] = {"max_file_bytes", "max_notes", "max_complete_songs", "max_partial_songs", "max_sections", "max_pages"};
    for (unsigned i = 0; i < 6; ++i) field(w, names[i], score_get_u32(p + 8 + 4 * i));
    field(w, "profile_count", count); field(w, "storage_flags", flags);
    literal(w, ",\"profiles\":[");
    for (unsigned i = 0; i < count; ++i) { if (i) literal(w, ","); integer(w, score_get_u16(p + 36 + 2 * i)); }
    literal(w, "]"); return true;
}
static bool status(writer_t *w, const uint8_t *p, size_t n)
{
    if (n != 40 || p[0] > 3 || p[1] > 2 || !zeros(p + 2, 2) || !score_get_u32(p + 4)) return false;
    uint32_t next = score_get_u32(p + 32), total = score_get_u32(p + 36);
    bool idle = zeros(p + 16, 16);
    if (next > total || (idle && (next || total))) return false;
    field(w, "mode", p[0]); field(w, "phase", p[1]); field(w, "generation", score_get_u32(p + 4));
    literal(w, ",\"free_bytes\":\""); integer(w, score_get_u64(p + 8)); literal(w, "\",\"active_id\":");
    if (idle) literal(w, "null"); else id(w, p + 16);
    field(w, "next_block", next); field(w, "total_blocks", total); return true;
}
static bool list(writer_t *w, const uint8_t *p, size_t n)
{
    if (n < 12 || !score_get_u32(p) || !zeros(p + 10, 2)) return false;
    uint16_t count = score_get_u16(p + 8);
    uint32_t cursor = score_get_u32(p + 4);
    if (count > 1 || (!count && cursor != UINT32_MAX) || (cursor != UINT32_MAX && !cursor)) return false;
    field(w, "generation", score_get_u32(p)); literal(w, ",\"next_cursor\":");
    if (cursor == UINT32_MAX) literal(w, "null"); else integer(w, cursor);
    literal(w, ",\"items\":[");
    if (count) {
        if (n < 56) return false;
        p += 12; n -= 12;
        uint32_t total_bytes = score_get_u32(p + 20), capabilities = score_get_u32(p + 28);
        uint32_t next = score_get_u32(p + 32), total = score_get_u32(p + 36);
        uint16_t len = score_get_u16(p + 40);
        if (!score_song_id_valid(p) || (p[16] != 1 && p[16] != 2) || !zeros(p + 17, 3) || !zeros(p + 42, 2) ||
            n != (size_t)44 + len || total_bytes < 64 || !capabilities || (capabilities & ~7u) ||
            total != ((uint64_t)total_bytes + 511) / 512 || next > total ||
            (p[16] == 2 && next != total) || !score_title_valid(p + 44, len)) return false;
        literal(w, "{\"id\":"); id(w, p); field(w, "entry_state", p[16]);
        field(w, "total_bytes", total_bytes); field(w, "file_crc", score_get_u32(p + 24));
        field(w, "capabilities", capabilities); field(w, "next_block", next); field(w, "total_blocks", total);
        literal(w, ",\"title\":"); title(w, p + 44, len); literal(w, "}");
    } else if (n != 12) return false;
    literal(w, "]"); return true;
}

bool score_response_to_ble(const score_frame_t *frame, uint16_t max_write,
                           uint8_t *out, size_t cap, size_t *out_len)
{
    if (out_len) *out_len = 0;
    if (!frame || !out || !out_len || cap < 20 || frame->payload_len > SCORE_MAX_PAYLOAD || !frame->payload) return false;
    size_t capacity = cap - 20;
    if (capacity > SCORE_MAX_PAYLOAD) capacity = SCORE_MAX_PAYLOAD;
    writer_t w = {out + 16, 0, capacity, true};
    const uint8_t *p = frame->payload;
    size_t n = frame->payload_len;
    if (frame->type == SCORE_CHANGED) {
        if (!score_changed_valid(frame)) return false;
        literal(&w, "{\"generation\":"); integer(&w, score_get_u32(p));
        field(&w, "mode", p[4]); field(&w, "phase", p[5]);
    } else {
        if (!frame->session || !frame->seq) return false;
        if (frame->type == SCORE_ERROR) {
            if (n != 8 || p[1] || score_get_u16(p + 2) < 1 || score_get_u16(p + 2) > 13) return false;
            literal(&w, "{\"request_type\":"); integer(&w, p[0]);
            field(&w, "code", score_get_u16(p + 2)); literal(&w, ",\"next_block\":");
            if (score_get_u32(p + 4) == UINT32_MAX) literal(&w, "null"); else integer(&w, score_get_u32(p + 4));
        } else if (frame->type == SCORE_ACK) {
            if (n < 4 || !zeros(p + 1, 3) || !score_is_request(p[0])) return false;
            uint8_t request = p[0];
            literal(&w, "{\"request_type\":"); integer(&w, request);
            p += 4; n -= 4;
            switch (request) {
            case SCORE_CAPS: if (!caps(&w, p, n, max_write)) return false; break;
            case SCORE_STATUS: if (!status(&w, p, n)) return false; break;
            case SCORE_LIST: if (!list(&w, p, n)) return false; break;
            case SCORE_BEGIN: case SCORE_DATA: case SCORE_PAUSE:
                if (!progress(&w, p, n)) return false;
                break;
            case SCORE_COMMIT:
                if (n != 24 || !score_song_id_valid(p) || p[20] != 2 || !zeros(p + 21, 3)) return false;
                literal(&w, ",\"id\":"); id(&w, p); field(&w, "file_crc", score_get_u32(p + 16));
                literal(&w, ",\"entry_state\":2"); break;
            case SCORE_DELETE:
                if (n != 20 || !score_song_id_valid(p) || p[16] > 1 || !zeros(p + 17, 3)) return false;
                literal(&w, ",\"id\":"); id(&w, p); literal(&w, ",\"deleted\":");
                literal(&w, p[16] ? "true" : "false"); break;
            default: return false;
            }
        } else return false;
    }
    literal(&w, "}");
    if (!w.ok) return false;
    *out_len = score_encode(out, cap, frame->type, frame->session, frame->seq, out + 16, w.used);
    return *out_len != 0;
}
