#include "score_json.h"
#include "vectors/score_test_vectors.h"

#include <assert.h>
#include <stdio.h>
#include <string.h>

#define ID "00112233-4455-6677-8899-aabbccddeeff"
#define NIL_ID "00000000-0000-0000-0000-000000000000"
static size_t unhex(const char *s, uint8_t *out)
{
    size_t n = strlen(s) / 2;
    for (size_t i = 0; i < n; ++i) { unsigned v; assert(sscanf(s + 2 * i, "%2x", &v) == 1); out[i] = (uint8_t)v; }
    return n;
}
static bool request(uint8_t type, const char *json, uint8_t *out, size_t *len)
{
    score_frame_t f = {type, 1, 1, (const uint8_t *)json, (uint16_t)strlen(json)};
    return score_request_from_ble(&f, out, SCORE_MAX_FRAME, len);
}
static void no_request(uint8_t type, const char *json)
{
    uint8_t out[SCORE_MAX_FRAME]; size_t n = 123;
    assert(!request(type, json, out, &n) && n == 0);
}
static void vectors(bool emit)
{
    uint8_t input[SCORE_MAX_FRAME], output[SCORE_MAX_FRAME], expected[SCORE_MAX_FRAME];
    size_t len;
    score_frame_t f, converted;
    for (size_t i = 0; i < sizeof(request_vectors) / sizeof(request_vectors[0]); ++i) {
        size_t n = unhex(request_vectors[i].ble_hex, input);
        assert(score_decode(input, n, &f));
        assert(score_request_from_ble(&f, output, sizeof(output), &len));
        size_t expected_len = unhex(request_vectors[i].uart_hex, expected);
        assert(len == expected_len && !memcmp(expected, output, len));
        assert(!score_request_from_ble(&f, output, expected_len - 1, &len) && !len);
    }
    if (emit) putchar('{');
    for (size_t i = 0; i < sizeof(response_vectors) / sizeof(response_vectors[0]); ++i) {
        size_t n = unhex(response_vectors[i].uart_hex, input);
        assert(score_decode(input, n, &f));
        assert(score_response_to_ble(&f, 128, output, sizeof(output), &len));
        assert(score_decode(output, len, &converted));
        assert(converted.type == f.type && converted.session == f.session && converted.seq == f.seq);
        assert(converted.payload_len <= SCORE_MAX_PAYLOAD);
        if (emit) {
            if (i) putchar(',');
            printf("\"%s\":", response_vectors[i].name);
            assert(fwrite(converted.payload, 1, converted.payload_len, stdout) == converted.payload_len);
        }
        size_t good_len = len;
        assert(!score_response_to_ble(&f, 128, output, good_len - 1, &len) && !len);
    }
    if (emit) puts("}");
}

int main(int argc, char **argv)
{
    if (argc == 2 && !strcmp(argv[1], "--vectors")) { vectors(true); return 0; }
    vectors(false);
    uint8_t out[SCORE_MAX_FRAME], raw[SCORE_MAX_FRAME], payload[SCORE_MAX_PAYLOAD] = {0};
    size_t n; score_frame_t f, result;
    assert(request(SCORE_LIST, " \t{\"limit\":1,\"cursor\":0,\"generation\":0}\r\n", out, &n));
    assert(request(SCORE_LIST, "{\"generation\":4294967295,\"cursor\":4294967295,\"limit\":1}", out, &n));
    assert(request(SCORE_PAUSE, "{\"\\u0069d\":\"" ID "\"}", out, &n));
    const char *bad_list[] = {
        "{}", "[]", "null", "{\"generation\":0,\"cursor\":0}",
        "{\"generation\":0,\"cursor\":0,\"limit\":2}",
        "{\"generation\":0,\"cursor\":1,\"limit\":1}",
        "{\"generation\":0,\"cursor\":0,\"limit\":1,\"other\":0}",
        "{\"generation\":0,\"cursor\":0,\"limit\":1,\"limit\":1}",
        "{\"generation\":0,\"cursor\":0,\"limit\":1,}",
        "{\"generation\":0,\"cursor\":0,\"limit\":1}{}",
        "{\"generation\":4294967296,\"cursor\":0,\"limit\":1}",
        "{\"generation\":01,\"cursor\":0,\"limit\":1}",
        "{\"generation\":-1,\"cursor\":0,\"limit\":1}",
        "{\"generation\":0.0,\"cursor\":0,\"limit\":1}",
        "{\"generation\":0e0,\"cursor\":0,\"limit\":1}",
        "{\"generation\":\"0\",\"cursor\":0,\"limit\":1}",
        "{\"generation\":true,\"cursor\":0,\"limit\":1}",
        "{\"generation\":[],\"cursor\":0,\"limit\":1}",
        "{\"generation\":0/*x*/,\"cursor\":0,\"limit\":1}"
    };
    for (size_t i = 0; i < sizeof(bad_list) / sizeof(bad_list[0]); ++i) no_request(SCORE_LIST, bad_list[i]);
    no_request(SCORE_CAPS, "{}"); no_request(SCORE_STATUS, "null");
    no_request(SCORE_PAUSE, "{\"id\":\"00112233-4455-6677-8899-AABBCCDDEEFF\"}");
    no_request(SCORE_DELETE, "{\"id\":\"00112233-4455-6677-8899-aabbccddeef\"}");
    no_request(SCORE_DELETE, "{\"id\":\"" ID "\",\"\\u0069d\":\"" ID "\"}");
    no_request(SCORE_PAUSE, "{\"id\":\"" NIL_ID "\"}");
    no_request(SCORE_DELETE, "{\"id\":\"" NIL_ID "\"}");
    no_request(SCORE_COMMIT, "{\"id\":\"" NIL_ID "\",\"total_bytes\":64,\"file_crc\":0}");
    no_request(SCORE_BEGIN, "{\"id\":\"" NIL_ID "\",\"total_bytes\":64,\"file_crc\":0,\"block_bytes\":512,\"package_major\":2,\"total_blocks\":1,\"capabilities\":1,\"title\":\"x\"}");
    const char *prefix = "{\"id\":\"" ID "\",\"total_bytes\":516,\"file_crc\":4294967295,\"block_bytes\":512,\"package_major\":2,\"total_blocks\":2,\"capabilities\":7,\"title\":\"";
    char json[SCORE_MAX_PAYLOAD + 1];
    snprintf(json, sizeof(json), "%s%s\"}", prefix, "\\u6d4b\\u8bd5\\ud83c\\udfb9\\\"\\\\");
    assert(request(SCORE_BEGIN, json, out, &n));
    assert(score_decode(out, n, &result));
    assert(result.payload_len == 52 && score_get_u16(result.payload + 36) == 12);
    assert(!memcmp(result.payload + 40, "\xe6\xb5\x8b\xe8\xaf\x95\xf0\x9f\x8e\xb9\"\\", 12));
    const char *bad_titles[] = {"", "\\ud800", "\\udc00", "\\ud800\\u0041", "\\u0000", "\\u001f", "\\n", "\\q", "\xed\xa0\x80", "\xc0\xaf", "\xff", "x\n"};
    for (size_t i = 0; i < sizeof(bad_titles) / sizeof(bad_titles[0]); ++i) {
        snprintf(json, sizeof(json), "%s%s\"}", prefix, bad_titles[i]); no_request(SCORE_BEGIN, json);
    }
    /* Longest title by both encoded bytes and Unicode scalar count. */
    size_t at = strlen(prefix); memcpy(json, prefix, at);
    for (size_t i = 0; i < 128; ++i) { memcpy(json + at, "\xe6\xb5\x8b", 3); at += 3; }
    memcpy(json + at, "\"}", 3);
    assert(request(SCORE_BEGIN, json, out, &n) && n == 444);
    json[at++] = 'x'; memcpy(json + at, "\"}", 3); no_request(SCORE_BEGIN, json);
    assert(request(SCORE_BEGIN, "{\"id\":\"" ID "\",\"total_bytes\":4294967295,\"file_crc\":0,\"block_bytes\":512,\"package_major\":2,\"total_blocks\":8388608,\"capabilities\":1,\"title\":\"x\"}", out, &n));
    no_request(SCORE_BEGIN, "{\"id\":\"" ID "\",\"total_bytes\":64,\"file_crc\":0,\"block_bytes\":512,\"package_major\":2,\"total_blocks\":2,\"capabilities\":1,\"title\":\"x\"}");
    no_request(SCORE_COMMIT, "{\"id\":\"" ID "\",\"total_bytes\":63,\"file_crc\":0}");
    f = (score_frame_t){SCORE_DATA, 1, 1, payload, 20};
    assert(!score_request_from_ble(&f, out, sizeof(out), &n));
    f.payload_len = 21;
    assert(!score_request_from_ble(&f, out, sizeof(out), &n)); /* nil DATA UUID */
    payload[15] = 1; /* The minimum non-nil UUID is a valid song identity. */
    f.payload_len = 532; assert(score_request_from_ble(&f, out, sizeof(out), &n));
    assert(score_decode(out, n, &result) && result.payload_len == 532 && !memcmp(payload, result.payload, 532));
    f.payload_len = 533; assert(!score_request_from_ble(&f, out, sizeof(out), &n));
    f.payload_len = 21; f.session = 0; assert(!score_request_from_ble(&f, out, sizeof(out), &n));
    f.session = 1; f.seq = 0; assert(!score_request_from_ble(&f, out, sizeof(out), &n));
    /* Every ACK requires its zero reserved prefix and its complete record. */
    for (size_t i = 0; i < 8; ++i) {
        size_t size = unhex(response_vectors[i].uart_hex, raw);
        assert(score_decode(raw, size, &f));
        --f.payload_len; assert(!score_response_to_ble(&f, 128, out, sizeof(out), &n));
        ++f.payload_len; raw[17] = 1;
        assert(!score_response_to_ble(&f, 128, out, sizeof(out), &n));
    }
    /* All song-bearing ACKs reject nil IDs, including a LIST item. STATUS
     * below deliberately preserves nil as the no-active-song sentinel. */
    for (size_t i = 2; i < 8; ++i) {
        size_t size = unhex(response_vectors[i].uart_hex, raw);
        assert(score_decode(raw, size, &f));
        size_t id_offset = 16 + 4 + (i == 2 ? 12 : 0);
        memset(raw + id_offset, 0, 16);
        assert(!score_response_to_ble(&f, 128, out, sizeof(out), &n));
        assert(n == 0);
        raw[id_offset + 15] = 1;
        assert(score_response_to_ble(&f, 128, out, sizeof(out), &n));
    }
    /* u64 remains a decimal string, no floating point. */
    size_t size = unhex(response_vectors[1].uart_hex, raw);
    assert(score_decode(raw, size, &f)); score_put_u64(raw + 16 + 4 + 8, UINT64_MAX);
    assert(score_response_to_ble(&f, 128, out, sizeof(out), &n));
    assert(score_decode(out, n, &result)); memcpy(json, result.payload, result.payload_len); json[result.payload_len] = 0;
    assert(strstr(json, "\"free_bytes\":\"18446744073709551615\"") != NULL);
    memset(raw + 16 + 4 + 16, 0, 16); /* zero active id but nonzero progress */
    assert(!score_response_to_ble(&f, 128, out, sizeof(out), &n));
    memset(raw + 16 + 4 + 32, 0, 8);
    assert(score_response_to_ble(&f, 128, out, sizeof(out), &n));
    assert(score_decode(out, n, &result)); memcpy(json, result.payload, result.payload_len); json[result.payload_len] = 0;
    assert(strstr(json, "\"active_id\":null") != NULL);
    /* Progress cannot claim partial full-sized non-tail blocks. */
    size = unhex(response_vectors[3].uart_hex, raw); assert(score_decode(raw, size, &f));
    score_put_u32(raw + 16 + 4 + 24, 511);
    assert(!score_response_to_ble(&f, 128, out, sizeof(out), &n));
    score_put_u32(raw + 16 + 4 + 24, 513);
    assert(!score_response_to_ble(&f, 128, out, sizeof(out), &n));
    score_put_u32(raw + 16 + 4 + 16, 3);
    assert(!score_response_to_ble(&f, 128, out, sizeof(out), &n));
    /* Largest LIST title round-trips without truncation. */
    size = unhex(response_vectors[2].uart_hex, raw); assert(score_decode(raw, size, &f));
    score_put_u16(raw + 16 + 4 + 12 + 40, 384);
    for (unsigned i = 0; i < 128; ++i) memcpy(raw + 16 + 4 + 12 + 44 + 3 * i, "\xe6\xb5\x8b", 3);
    f.payload_len = 4 + 12 + 44 + 384;
    assert(score_response_to_ble(&f, 128, out, sizeof(out), &n));
    score_put_u16(raw + 16 + 4 + 12 + 40, 385); ++f.payload_len;
    assert(!score_response_to_ble(&f, 128, out, sizeof(out), &n));
    /* No multi-item response can masquerade as a BLE limit=1 page. */
    size = unhex(response_vectors[2].uart_hex, raw); assert(score_decode(raw, size, &f));
    score_put_u16(raw + 16 + 4 + 8, 2);
    assert(!score_response_to_ble(&f, 128, out, sizeof(out), &n));
    /* Capacity/profile bounds, actual ATT write limit. */
    size = unhex(response_vectors[0].uart_hex, raw); assert(score_decode(raw, size, &f));
    assert(!score_response_to_ble(&f, 19, out, sizeof(out), &n));
    assert(!score_response_to_ble(&f, 513, out, sizeof(out), &n));
    score_put_u16(raw + 16 + 4 + 32, 32); f.payload_len = 4 + 36 + 64;
    for (unsigned i = 0; i < 32; ++i) score_put_u16(raw + 16 + 4 + 36 + 2 * i, (uint16_t)(65000 + i));
    assert(score_response_to_ble(&f, 512, out, sizeof(out), &n));
    score_put_u16(raw + 16 + 4 + 38, 65000);
    assert(!score_response_to_ble(&f, 512, out, sizeof(out), &n));
    /* All protocol error codes and null progress. */
    f = (score_frame_t){SCORE_ERROR, 1, 1, payload, 8}; payload[0] = SCORE_DATA;
    score_put_u32(payload + 4, UINT32_MAX);
    for (unsigned i = 1; i <= 13; ++i) {
        score_put_u16(payload + 2, (uint16_t)i);
        assert(score_response_to_ble(&f, 128, out, sizeof(out), &n));
    }
    score_put_u16(payload + 2, 14); assert(!score_response_to_ble(&f, 128, out, sizeof(out), &n));
    f = (score_frame_t){SCORE_CHANGED, 0, 0, payload, 8};
    memset(payload, 0, 8); score_put_u32(payload, 1);
    assert(score_response_to_ble(&f, 128, out, sizeof(out), &n));
    f.seq = 1; assert(!score_response_to_ble(&f, 128, out, sizeof(out), &n));
    f.seq = 0; payload[4] = 4; assert(!score_response_to_ble(&f, 128, out, sizeof(out), &n));
    /* Mutate every byte/bit of a real BEGIN JSON under output capacity pressure.
     * Accepted mutations may change valid data, but must still produce a valid
     * complete frame; all writes must stay within the caller's advertised cap. */
    size = unhex(request_vectors[3].ble_hex, raw);
    assert(score_decode(raw, size, &f));
    for (size_t pos = 0; pos < f.payload_len; ++pos) {
        for (unsigned bit = 0; bit < 8; ++bit) {
            uint8_t guarded[SCORE_MAX_FRAME + 32]; memset(guarded, 0x5c, sizeof(guarded));
            size_t capacity = (pos + bit) % 3 ? SCORE_MAX_FRAME : (pos + bit) % 80;
            raw[16 + pos] ^= (uint8_t)(1u << bit);
            bool ok = score_request_from_ble(&f, guarded + 16, capacity, &n);
            if (ok) assert(n <= capacity && score_decode(guarded + 16, n, &result));
            else assert(n == 0);
            for (size_t k = 0; k < 16; ++k) assert(guarded[k] == 0x5c);
            for (size_t k = 16 + capacity; k < sizeof(guarded); ++k) assert(guarded[k] == 0x5c);
            raw[16 + pos] ^= (uint8_t)(1u << bit);
        }
    }
    puts("score JSON: all commands, strict JSON/UTF-8, bounds, null/u64 and invalid replies PASS");
    return 0;
}
