#ifndef SCORE_PROXY_H
#define SCORE_PROXY_H
#include "score_protocol.h"

/* Single worker owns this object. Callbacks must not reenter the proxy.
 * uart_send consumes synchronously; notify copies a whole frame or returns busy.
 * A true notify result means queued for GATT, never a durable file ACK. */
typedef struct {
    bool (*uart_send)(const uint8_t *wire, size_t length, void *context);
    bool (*notify)(const uint8_t *wire, size_t length, void *context);
    void (*disconnect)(void *context);
    void *context;
} score_proxy_io_t;

typedef struct {
    uint32_t requests, retries, replies, changed, timeouts, stale, local_errors;
} score_proxy_stats_t;

typedef struct {
    score_proxy_io_t io;
    score_stream_t ble_stream, uart_stream;
    uint8_t last_ble[SCORE_MAX_FRAME];
    uint8_t uart_tx[SCORE_MAX_FRAME];
    uint8_t reply[SCORE_MAX_FRAME];
    uint8_t changed_payload[8];
    size_t last_ble_len, reply_len;
    uint32_t epoch, session, seq, now_ms, started_ms;
    uint16_t max_write;
    uint8_t request_type;
    bool connected, subscribed, waiting, reply_expected, changed_pending;
    score_proxy_stats_t stats;
} score_proxy_t;

void score_proxy_init(score_proxy_t *p, const score_proxy_io_t *io);
void score_proxy_connect(score_proxy_t *p, uint32_t epoch, uint16_t max_write, bool subscribed);
void score_proxy_disconnect(score_proxy_t *p, uint32_t epoch);
void score_proxy_link(score_proxy_t *p, uint16_t max_write, bool subscribed);
void score_proxy_ble_feed(score_proxy_t *p, uint32_t epoch, const uint8_t *bytes,
                          size_t length, uint32_t now_ms);
void score_proxy_uart_feed(score_proxy_t *p, const uint8_t *bytes, size_t length, uint32_t now_ms);
void score_proxy_uart_reset(score_proxy_t *p);
void score_proxy_poll(score_proxy_t *p, uint32_t now_ms);
#endif
