#include "score_diag.h"
#include <inttypes.h>
#include "esp_timer.h"
#include "esp_log.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"

static portMUX_TYPE diag_lock = portMUX_INITIALIZER_UNLOCKED;
uint64_t score_diag_clock(void) { return (uint64_t)esp_timer_get_time(); }
void score_diag_lock(void) { portENTER_CRITICAL(&diag_lock); }
void score_diag_unlock(void) { portEXIT_CRITICAL(&diag_lock); }
static const char *const names[SCORE_DIAG_METRICS] = {
    "rx_span", "queue_mean", "queue_max", "fragment_gap", "parse",
    "uart_call", "uart_rtt", "ready_wait", "notify_submit_span", "next_gap"
};
static void logger(void *arg)
{
    (void)arg;
    uint64_t previous = score_diag_clock();
    for (;;) {
        vTaskDelay(pdMS_TO_TICKS(5000));
        uint64_t now = score_diag_clock();
        score_diag_summary_t s;
        score_diag_link_t link;
        score_diag_snapshot(&s, &link);
        if (link.dirty) ESP_LOGI("score_diag", "v=1 LINK epoch=%"PRIu32
            " connected=%u subscribed=%u mtu=%u max_write=%u caps_write=%u interval_units=%u latency=%u timeout_units=%u",
            link.epoch, link.connected, link.subscribed, link.mtu, link.max_write,
            link.caps_write, link.interval, link.latency, link.timeout);
        score_diag_record_t r;
        while (score_diag_take(&r)) {
            ESP_LOGI("score_diag", "v=1 DATA epoch=%"PRIu32" session=%"PRIu32
                " seq=%"PRIu32" block=%"PRIu32" attempt=%"PRIu32
                " rx_n=%u rx_bytes=%u rx_min=%u rx_max=%u tx_n=%u busy=%u error=%u rx_exact=%u",
                r.epoch,r.session,r.seq,r.block,r.attempt,r.rx_count,r.rx_bytes,
                r.rx_min,r.rx_max,r.tx_count,r.busy,r.error,r.rx_exact);
            for (unsigned i=0;i<SCORE_DIAG_METRICS;i++)
                ESP_LOGI("score_diag", "DETAIL seq=%"PRIu32" %s_us=%"PRIu32,r.seq,names[i],r.us[i]);
        }
        ESP_LOGI("score_diag", "v=1 WINDOW elapsed_us=%"PRIu64" data_replies=%"PRIu32
            " rx_bytes=%"PRIu32" fragments=%"PRIu32" changed=%"PRIu32
            " dropped=%"PRIu32" abandoned=%"PRIu32" busy=%"PRIu32" tx_fragments=%"PRIu32
            " ack_payload_bytes=%"PRIu32" errors=%"PRIu32,
            now-previous,s.completed,s.rx_bytes,s.fragments,s.changed,s.dropped,s.abandoned,s.busy,s.tx_fragments,s.confirmed_bytes,s.errors);
        if (s.completed) for (unsigned i=0;i<SCORE_DIAG_METRICS;i++)
            ESP_LOGI("score_diag", "METRIC %s mean_us=%"PRIu64" max_us=%"PRIu32,
                names[i],s.sum[i]/s.completed,s.max[i]);
        ESP_LOGI("score_diag", "UART tx=%"PRIu32" rx=%"PRIu32" calls=%"PRIu32
            " write_mean_us=%"PRIu64" write_max_us=%"PRIu32,
            s.uart_tx,s.uart_rx,s.uart_calls,s.uart_calls ? s.uart_sum/s.uart_calls : 0,s.uart_max);
        previous = now;
    }
}
void score_diag_start(void)
{
    /* Stack/RTOS allocation is separate from the bounded application data. */
    if (xTaskCreatePinnedToCore(logger,"score_diag",4096,NULL,1,NULL,0) != pdPASS)
        ESP_LOGW("score_diag", "logger unavailable; transport continues, diagnostic records may drop");
    ESP_LOGI("score_diag", "v=1 enabled data=%u budget=%u logger_stack=4096 core=0 priority=1; submit is NOT delivery",
        (unsigned)score_diag_bytes(), SCORE_DIAG_DATA_BUDGET);
}
