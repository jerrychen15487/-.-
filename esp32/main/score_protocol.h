#ifndef SCORE_PROTOCOL_H
#define SCORE_PROTOCOL_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

/* Sole wire specification: trans/PROTOCOL.md, chapter 3 (UART/BLE v2). */
#define SCORE_VERSION 2u
#define SCORE_MAX_PAYLOAD 1024u
#define SCORE_MAX_FRAME 1044u
#define SCORE_BLOCK_BYTES 512u
#define SCORE_MAX_TITLE_BYTES 384u
#define SCORE_MAX_TITLE_SCALARS 128u

enum score_type {
    SCORE_CAPS = 0x01, SCORE_STATUS = 0x02, SCORE_LIST = 0x03,
    SCORE_BEGIN = 0x10, SCORE_DATA = 0x11, SCORE_COMMIT = 0x12,
    SCORE_PAUSE = 0x13, SCORE_DELETE = 0x14, SCORE_ACK = 0x80,
    SCORE_CHANGED = 0x90, SCORE_ERROR = 0xff
};
enum score_error {
    SCORE_BUSY = 1, SCORE_NO_SPACE, SCORE_UNSUPPORTED_VERSION,
    SCORE_UNSUPPORTED_PROFILE, SCORE_BAD_BLOCK, SCORE_BAD_FILE_CRC,
    SCORE_BAD_PACKAGE, SCORE_STORAGE_ERROR, SCORE_CONTENT_MISMATCH,
    SCORE_NOT_FOUND, SCORE_STALE_LIST, SCORE_ALREADY_STORED, SCORE_BAD_REQUEST
};
typedef struct {
    uint8_t type;
    uint32_t session, seq;
    const uint8_t *payload;
    uint16_t payload_len;
} score_frame_t;
typedef void (*score_frame_callback_t)(const score_frame_t *frame, void *ctx);
typedef struct {
    uint8_t buffer[SCORE_MAX_FRAME];
    size_t used;
    uint32_t last_ms;
    uint32_t dropped, bad_frames, timeouts;
} score_stream_t;

uint16_t score_get_u16(const uint8_t *p);
uint32_t score_get_u32(const uint8_t *p);
uint64_t score_get_u64(const uint8_t *p);
void score_put_u16(uint8_t *p, uint16_t value);
void score_put_u32(uint8_t *p, uint32_t value);
void score_put_u64(uint8_t *p, uint64_t value);
uint32_t score_crc32(const uint8_t *data, size_t len);
size_t score_encode(uint8_t *out, size_t cap, uint8_t type, uint32_t session,
                    uint32_t seq, const uint8_t *payload, size_t len);
/* Exact outer-frame validation; payload semantics belong to the codec/proxy.
 * Decoded payload points into input. Caller must consume before reusing it. */
bool score_decode(const uint8_t *data, size_t len, score_frame_t *frame);
/* Zero initialize. callback is synchronous and must not retain payload, mutate
 * this stream or reenter feed. Calling with len=0 polls the gap timer.
 * now_ms arithmetic tolerates uint32 wraparound. */
void score_stream_feed(score_stream_t *s, const uint8_t *data, size_t len,
                       uint32_t now_ms, uint32_t gap_ms,
                       score_frame_callback_t callback, void *ctx);
bool score_is_request(uint8_t type);
/* Nil UUID is reserved for STATUS's no-active-song sentinel, not a song ID. */
bool score_song_id_valid(const uint8_t id[16]);
/* Shared complete CHANGED semantics; callers have already checked frame CRC. */
bool score_changed_valid(const score_frame_t *frame);
/* UTF-8 titles: 1..384 bytes, <=128 Unicode scalars, no C0 controls. */
bool score_title_valid(const uint8_t *data, size_t len);

#endif
