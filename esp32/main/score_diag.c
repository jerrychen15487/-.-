#include "score_diag.h"
#include <string.h>
#include <limits.h>

/* Three complete records, one in-flight request; no payload copies. */
static struct {
    score_diag_record_t current, records[3];
    score_diag_summary_t summary;
    score_diag_link_t link;
    uint64_t first, last, queue_sum, uart_start, ready, notify_first, previous_end;
    uint32_t epoch, tx_session, tx_seq, tx_attempt;
    uint16_t count, bytes, minimum, maximum;
    uint32_t queue_max, gap_max;
    uint8_t head, used, details;
    bool pending, reply, transmitting, next_valid;
} state;
_Static_assert(sizeof(state) <= SCORE_DIAG_DATA_BUDGET, "diagnostic storage budget");

static uint32_t elapsed(uint64_t end, uint64_t start)
{
    uint64_t value = end >= start ? end - start : 0;
    return value > UINT32_MAX ? UINT32_MAX : (uint32_t)value;
}
static void clear_rx(void)
{
    state.first = state.last = state.queue_sum = 0;
    state.count = state.bytes = state.minimum = state.maximum = 0;
    state.queue_max = state.gap_max = 0;
}
void score_diag_reset(uint32_t epoch)
{
    score_diag_lock();
    if (state.pending) ++state.summary.abandoned;
    state.epoch = epoch;
    state.pending = state.reply = state.transmitting = state.next_valid = false;
    state.details = 0;
    memset(&state.current, 0, sizeof(state.current));
    clear_rx();
    score_diag_unlock();
}
void score_diag_link(uint32_t epoch, bool connected, bool subscribed,
                     uint16_t mtu, uint16_t maximum, uint16_t interval,
                     uint16_t latency, uint16_t timeout)
{
    score_diag_lock();
    state.link = (score_diag_link_t){.epoch=epoch, .connected=connected,
        .subscribed=subscribed, .mtu=mtu, .max_write=maximum,
        .interval=interval, .latency=latency, .timeout=timeout,
        .caps_write=state.link.epoch == epoch ? state.link.caps_write : 0, .dirty=true};
    score_diag_unlock();
}
void score_diag_ingress(uint32_t epoch, uint64_t arrival, uint16_t length)
{
    uint64_t now = score_diag_clock();
    score_diag_lock();
    if (epoch == state.epoch) {
        if (!state.count) { state.first = arrival; state.minimum = length; }
        else {
            uint32_t gap = elapsed(arrival, state.last);
            if (gap > state.gap_max) state.gap_max = gap;
        }
        state.last = arrival;
        ++state.count;
        state.bytes += length;
        if (length < state.minimum) state.minimum = length;
        if (length > state.maximum) state.maximum = length;
        uint32_t wait = elapsed(now, arrival);
        state.queue_sum += wait;
        if (wait > state.queue_max) state.queue_max = wait;
    }
    score_diag_unlock();
}
void score_diag_discard_ingress(void)
{
    score_diag_lock(); clear_rx(); score_diag_unlock();
}
void score_diag_request(uint32_t epoch, const score_frame_t *frame)
{
    uint64_t now = score_diag_clock();
    score_diag_lock();
    if (epoch == state.epoch) {
        uint32_t attempt = state.current.session == frame->session &&
            state.current.seq == frame->seq ? state.current.attempt + 1 : 1;
        if (state.pending) ++state.summary.abandoned;
        state.current = (score_diag_record_t){.epoch=epoch, .session=frame->session,
            .seq=frame->seq, .command=frame->type, .attempt=attempt,
            .block=frame->type == SCORE_DATA ? score_get_u32(frame->payload+16) : UINT32_MAX,
            .rx_exact=state.bytes == frame->payload_len + 20u, .rx_count=state.count, .rx_bytes=state.bytes, .rx_min=state.minimum, .rx_max=state.maximum};
        if (state.count) {
            state.current.us[SD_RX] = elapsed(state.last, state.first);
            state.current.us[SD_QUEUE] = (uint32_t)(state.queue_sum/state.count);
            state.current.us[SD_QUEUE_MAX] = state.queue_max;
            state.current.us[SD_FRAGMENT_GAP] = state.gap_max;
            state.current.us[SD_PARSE] = elapsed(now, state.last);
            if (state.next_valid) state.current.us[SD_NEXT] = elapsed(state.first, state.previous_end);
        }
        clear_rx();
        state.pending = true;
        state.reply = false;
        state.uart_start = 0;
    }
    score_diag_unlock();
}
void score_diag_uart_begin(void)
{
    uint64_t now = score_diag_clock();
    score_diag_lock(); state.uart_start = now; score_diag_unlock();
}
void score_diag_uart_end(void)
{
    uint64_t now = score_diag_clock();
    score_diag_lock();
    state.current.us[SD_UART_CALL] = elapsed(now, state.uart_start);
    score_diag_unlock();
}
void score_diag_uart_io(uint32_t tx, uint32_t rx, uint32_t call_us)
{
    score_diag_lock();
    state.summary.uart_tx += tx; state.summary.uart_rx += rx;
    if (tx) {
        ++state.summary.uart_calls; state.summary.uart_sum += call_us;
        if (call_us > state.summary.uart_max) state.summary.uart_max = call_us;
    }
    score_diag_unlock();
}
void score_diag_reply(uint32_t epoch, const score_frame_t *frame, uint16_t max_write)
{
    uint64_t now = score_diag_clock();
    score_diag_lock();
    if (state.pending && epoch == state.epoch && frame->session == state.current.session &&
        frame->seq == state.current.seq) {
        state.current.us[SD_UART_RTT] = elapsed(now, state.uart_start);
        state.ready = now;
        state.current.error = frame->type == SCORE_ERROR ? score_get_u16(frame->payload+2) : 0;
        state.reply = true;
        if (frame->type == SCORE_ACK && frame->payload[0] == SCORE_CAPS) {
            state.link.caps_write = max_write; state.link.dirty = true;
        }
    }
    score_diag_unlock();
}
void score_diag_notify_begin(uint32_t epoch, const uint8_t *wire, size_t length)
{
    score_diag_lock();
    /* GATT transport also accepts short, non-protocol buffers in its unit
     * tests. Observe only complete application-frame headers. */
    if (length < 20) {
        state.transmitting = false;
        score_diag_unlock(); return;
    }
    if (wire[3] == SCORE_CHANGED) ++state.summary.changed;
    state.tx_session = score_get_u32(wire+4); state.tx_seq = score_get_u32(wire+8);
    state.transmitting = epoch == state.epoch && wire[3] != SCORE_CHANGED;
    state.tx_attempt = state.current.attempt;
    state.notify_first = 0;
    score_diag_unlock();
}
void score_diag_notify_part(bool accepted, bool last)
{
    uint64_t now = score_diag_clock();
    score_diag_lock();
    score_diag_record_t *r = &state.current;
    if (state.transmitting && state.pending && state.reply &&
        state.tx_session == r->session && state.tx_seq == r->seq && state.tx_attempt == r->attempt) {
        if (!accepted) ++r->busy;
        else {
            if (!r->tx_count) {
                state.notify_first = now; r->us[SD_READY_WAIT] = elapsed(now, state.ready);
            }
            ++r->tx_count;
            if (last) {
                r->us[SD_NOTIFY] = elapsed(now, state.notify_first);
                state.previous_end = now; state.next_valid = true;
                state.pending = state.reply = state.transmitting = false;
                if (r->command == SCORE_DATA) {
                    ++state.summary.completed;
                    state.summary.busy += r->busy;
                    state.summary.tx_fragments += r->tx_count;
                    if (r->error) ++state.summary.errors;
                    else if (r->rx_exact) state.summary.confirmed_bytes += r->rx_bytes - 40u;
                    state.summary.rx_bytes += r->rx_bytes;
                    state.summary.fragments += r->rx_count;
                    for (unsigned i=0; i<SCORE_DIAG_METRICS; ++i) {
                        state.summary.sum[i] += r->us[i];
                        if (r->us[i] > state.summary.max[i]) state.summary.max[i] = r->us[i];
                    }
                    if (state.details < 3) {
                        ++state.details;
                        if (state.used == 3) ++state.summary.dropped;
                        else { state.records[(state.head+state.used)%3] = *r; ++state.used; }
                    }
                }
            }
        }
    }
    score_diag_unlock();
}
bool score_diag_take(score_diag_record_t *record)
{
    score_diag_lock();
    bool found = state.used != 0;
    if (found) { *record=state.records[state.head]; state.head=(state.head+1)%3; --state.used; }
    score_diag_unlock();
    return found;
}
void score_diag_snapshot(score_diag_summary_t *summary, score_diag_link_t *link)
{
    score_diag_lock();
    *summary = state.summary; *link = state.link;
    memset(&state.summary, 0, sizeof(state.summary)); state.link.dirty = false;
    score_diag_unlock();
}
size_t score_diag_bytes(void) { return sizeof(state); }
