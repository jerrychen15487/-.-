#include "score_proxy.h"
#include "score_json.h"
#include "score_diag.h"
#include <string.h>

static void fault(score_proxy_t *p)
{
    if (!p->connected) return;
    ++p->stats.local_errors;
    p->connected = false;
    p->waiting = p->reply_expected = p->changed_pending = false;
    p->reply_len = 0;
    /* Do not reset parsers here: this may be called from their synchronous
     * callbacks. The next explicit connection resets all stream ownership. */
    if (p->io.disconnect) p->io.disconnect(p->io.context);
}

static void flush_notifications(score_proxy_t *p)
{
    if (!p->connected || !p->subscribed || !p->io.notify) return;
    if (p->reply_len) {
        if (!p->io.notify(p->reply, p->reply_len, p->io.context)) return;
        p->reply_len = 0;
    }
    if (p->changed_pending) {
        score_frame_t f = {.type = SCORE_CHANGED, .payload = p->changed_payload,
                           .payload_len = sizeof(p->changed_payload)};
        size_t length;
        if (!score_response_to_ble(&f, p->max_write, p->uart_tx, sizeof(p->uart_tx), &length)) {
            fault(p); return;
        }
        if (p->io.notify(p->uart_tx, length, p->io.context)) p->changed_pending = false;
    }
}

static bool same_request(const score_proxy_t *p, const score_frame_t *f)
{
    /* last_ble is produced by score_encode after a validated request and is
     * owned exclusively by this worker. Its CRC need not be recomputed.
     * Header fields uniquely determine the framing bytes; compare payload
     * bytes exactly, not parsed JSON equivalence. */
    return p->last_ble_len == (size_t)f->payload_len + 20 && p->request_type == f->type &&
        p->session == f->session && p->seq == f->seq &&
        (!f->payload_len || !memcmp(p->last_ble + 16, f->payload, f->payload_len));
}

static void on_ble(const score_frame_t *f, void *context)
{
    score_proxy_t *p = context;
    if (!p->connected) return;
    if (!p->subscribed || !f->session || !f->seq || !score_is_request(f->type)) {
        fault(p); return;
    }
    bool retry = p->last_ble_len && f->session == p->session && f->seq == p->seq;
    if (retry) {
        if (!same_request(p, f)) { fault(p); return; }
        ++p->stats.retries;
        /* A validated response not yet copied to GATT is sufficient. Never
         * fabricate a new response or discard it just because a retry arrived. */
        if (p->reply_len) {
            SCORE_DIAG(score_diag_discard_ingress());
            flush_notifications(p); return;
        }
    } else {
        if (p->waiting || p->reply_len) { fault(p); return; }
        if (!p->last_ble_len || f->session != p->session) {
            if (f->type != SCORE_CAPS || f->seq != 1) { fault(p); return; }
        } else if (f->seq <= p->seq) { fault(p); return; }
    }
    size_t length;
    if (!score_request_from_ble(f, p->uart_tx, sizeof(p->uart_tx), &length)) {
        fault(p); return;
    }
    SCORE_DIAG(score_diag_request(p->epoch, f));
    if (!retry) {
        p->last_ble_len = score_encode(p->last_ble, sizeof(p->last_ble), f->type,
            f->session, f->seq, f->payload, f->payload_len);
        if (!p->last_ble_len) { fault(p); return; }
    }
    /* Register BEFORE handing bytes to the transport. Response processing
     * belongs to a later worker turn; callbacks must not reenter this object. */
    p->session = f->session; p->seq = f->seq; p->request_type = f->type;
    p->waiting = p->reply_expected = true;
    p->started_ms = p->now_ms;
    ++p->stats.requests;
    SCORE_DIAG(score_diag_uart_begin());
    if (!p->io.uart_send || !p->io.uart_send(p->uart_tx, length, p->io.context)) fault(p);
    SCORE_DIAG(score_diag_uart_end());
}

static void on_uart(const score_frame_t *f, void *context)
{
    score_proxy_t *p = context;
    if (!p->connected) { ++p->stats.stale; return; }
    if (f->type == SCORE_CHANGED) {
        if (!score_changed_valid(f)) {
            ++p->stats.stale; return;
        }
        memcpy(p->changed_payload, f->payload, 8);
        p->changed_pending = true;
        ++p->stats.changed;
        return; /* flush only outside parser callback */
    }
    if (!p->reply_expected || f->session != p->session || f->seq != p->seq) {
        ++p->stats.stale; return;
    }
    if ((f->type != SCORE_ACK && f->type != SCORE_ERROR) || !f->payload_len ||
        f->payload[0] != p->request_type || p->reply_len ||
        !score_response_to_ble(f, p->max_write, p->reply, sizeof(p->reply), &p->reply_len)) {
        fault(p); return;
    }
    SCORE_DIAG(score_diag_reply(p->epoch, f, p->max_write));
    p->waiting = p->reply_expected = false;
    ++p->stats.replies;
}

void score_proxy_init(score_proxy_t *p, const score_proxy_io_t *io)
{
    memset(p, 0, sizeof(*p));
    if (io) p->io = *io;
    p->max_write = 20;
}

void score_proxy_connect(score_proxy_t *p, uint32_t epoch, uint16_t max_write, bool subscribed)
{
    score_proxy_io_t io = p->io;
    score_proxy_stats_t stats = p->stats;
    score_proxy_init(p, &io);
    p->stats = stats; p->epoch = epoch; p->connected = true;
    score_proxy_link(p, max_write, subscribed);
}

void score_proxy_disconnect(score_proxy_t *p, uint32_t epoch)
{
    if (epoch != p->epoch) return;
    p->connected = p->subscribed = p->waiting = p->reply_expected = p->changed_pending = false;
    p->last_ble_len = p->reply_len = 0;
    p->ble_stream.used = p->uart_stream.used = 0;
}

void score_proxy_link(score_proxy_t *p, uint16_t max_write, bool subscribed)
{
    p->max_write = max_write < 20 ? 20 : max_write > 512 ? 512 : max_write;
    p->subscribed = subscribed;
    if (!subscribed && (p->waiting || p->reply_len || p->ble_stream.used)) fault(p);
}

void score_proxy_poll(score_proxy_t *p, uint32_t now_ms)
{
    p->now_ms = now_ms;
    if (!p->connected) return;
    if (p->ble_stream.used && (uint32_t)(now_ms - p->ble_stream.last_ms) >= 5000) {
        ++p->stats.timeouts; fault(p); return;
    }
    score_stream_feed(&p->uart_stream, NULL, 0, now_ms, 100, on_uart, p);
    uint32_t timeout = p->request_type == SCORE_COMMIT ? 30000 : 5000;
    if (p->waiting && (uint32_t)(now_ms - p->started_ms) >= timeout) {
        p->waiting = false;
        ++p->stats.timeouts;
        /* Keep reply identity for a late response until the next request.
         * The browser owns retries and unknown COMMIT/DELETE reconciliation. */
    }
    flush_notifications(p);
}

void score_proxy_ble_feed(score_proxy_t *p, uint32_t epoch, const uint8_t *bytes,
                          size_t length, uint32_t now_ms)
{
    if (!p->connected || epoch != p->epoch) { ++p->stats.stale; return; }
    score_proxy_poll(p, now_ms);
    if (p->connected) score_stream_feed(&p->ble_stream, bytes, length, now_ms, 5000, on_ble, p);
    flush_notifications(p);
}

void score_proxy_uart_feed(score_proxy_t *p, const uint8_t *bytes, size_t length, uint32_t now_ms)
{
    p->now_ms = now_ms;
    if (!p->connected) return;
    score_stream_feed(&p->uart_stream, bytes, length, now_ms, 100, on_uart, p);
    flush_notifications(p);
}

void score_proxy_uart_reset(score_proxy_t *p)
{
    p->uart_stream.used = 0;
    ++p->stats.local_errors;
    /* No trusted request identity in corrupt UART bytes. Await upstream retry. */
}
