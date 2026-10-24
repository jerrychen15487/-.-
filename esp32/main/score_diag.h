#pragma once
/* Removable score diagnostics. Disabled hooks must not evaluate arguments. */
#ifdef ESP_PLATFORM
#include "sdkconfig.h"
#endif
#if CONFIG_SCORE_DIAGNOSTICS
#include "score_protocol.h"
#define SCORE_DIAG(call) do { call; } while (0)
enum { SCORE_DIAG_DATA_BUDGET = 640, SCORE_DIAG_METRICS = 10 };
enum { SD_RX, SD_QUEUE, SD_QUEUE_MAX, SD_FRAGMENT_GAP, SD_PARSE,
       SD_UART_CALL, SD_UART_RTT, SD_READY_WAIT, SD_NOTIFY, SD_NEXT };
typedef struct {
    uint32_t epoch, session, seq, block, attempt, command;
    uint32_t us[SCORE_DIAG_METRICS];
    uint16_t rx_count, rx_bytes, rx_min, rx_max, tx_count, busy, error, rx_exact;
} score_diag_record_t;
typedef struct {
    uint64_t sum[SCORE_DIAG_METRICS];
    uint32_t max[SCORE_DIAG_METRICS];
    uint32_t completed, rx_bytes, fragments, changed, dropped, abandoned, busy, tx_fragments, confirmed_bytes, errors;
    uint64_t uart_sum;
    uint32_t uart_tx, uart_rx, uart_calls, uart_max;
} score_diag_summary_t;
typedef struct {
    uint32_t epoch;
    uint16_t mtu, max_write, interval, latency, timeout, caps_write;
    bool connected, subscribed, dirty;
} score_diag_link_t;
/* Platform seam: IDF supplies a monotonic clock and short critical section;
 * desktop tests supply a deterministic clock. No transport callbacks here. */
uint64_t score_diag_clock(void);
void score_diag_lock(void);
void score_diag_unlock(void);
void score_diag_start(void);
void score_diag_reset(uint32_t epoch);
void score_diag_link(uint32_t epoch, bool connected, bool subscribed,
                     uint16_t mtu, uint16_t maximum, uint16_t interval,
                     uint16_t latency, uint16_t timeout);
void score_diag_ingress(uint32_t epoch, uint64_t arrival, uint16_t length);
void score_diag_discard_ingress(void);
void score_diag_request(uint32_t epoch, const score_frame_t *frame);
void score_diag_uart_begin(void);
void score_diag_uart_end(void);
void score_diag_uart_io(uint32_t tx, uint32_t rx, uint32_t call_us);
void score_diag_reply(uint32_t epoch, const score_frame_t *frame, uint16_t max_write);
void score_diag_notify_begin(uint32_t epoch, const uint8_t *wire, size_t length);
void score_diag_notify_part(bool accepted, bool last);
bool score_diag_take(score_diag_record_t *record);
void score_diag_snapshot(score_diag_summary_t *summary, score_diag_link_t *link);
size_t score_diag_bytes(void);
#else
#define SCORE_DIAG_DATA_BUDGET 0
#define SCORE_DIAG(call) do { } while (0)
#endif
