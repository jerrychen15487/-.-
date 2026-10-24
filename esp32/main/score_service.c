#include "score_service.h"

#include <inttypes.h>
#include <string.h>
#include "esp_heap_caps.h"
#include "esp_log.h"
#include "esp_timer.h"
#include "freertos/FreeRTOS.h"
#include "freertos/semphr.h"
#include "freertos/task.h"
#include "score_protocol.h"
#include "score_uart.h"
#include "sdkconfig.h"
#include "score_diag.h"
#if CONFIG_SCORE_UART_SELF_TEST && !CONFIG_SCORE_BLE_ENABLED
#include "esp_random.h"
#endif
#if CONFIG_SCORE_BLE_ENABLED
#include "score_ble.h"
#include "score_proxy.h"
#endif

enum { SCORE_CORE = 0, SCORE_PRIORITY = 4, SCORE_STACK_BYTES = 8192 };
static const char *TAG = "score";
static StaticSemaphore_t startup_control;
static SemaphoreHandle_t startup_done;

#if CONFIG_SCORE_BLE_ENABLED
_Static_assert(sizeof(score_proxy_t) + SCORE_BLE_DATA_BUDGET + SCORE_DIAG_DATA_BUDGET <= 8192,
               "Score application data exceeds 8 KiB budget (stacks/RTOS/BT separate)");
static score_proxy_t proxy;
static uint32_t worker_epoch;
static bool send_uart(const uint8_t *bytes, size_t length, void *context)
{
    (void)context;
    return score_uart_send(bytes, length);
}
static bool send_ble(const uint8_t *bytes, size_t length, void *context)
{
    (void)context;
    return score_ble_notify(worker_epoch, bytes, length,
                            (uint32_t)(esp_timer_get_time() / 1000));
}
static void close_ble(void *context)
{
    (void)context;
    score_ble_disconnect(worker_epoch);
}
#else
static score_stream_t uart_stream;
#if CONFIG_SCORE_UART_SELF_TEST
static uint32_t test_session, test_seq, test_sent_ms;
static bool test_waiting;
static void uart_test_start(void)
{
    /* Only the explicit UART test profile opens an autonomous session. A
     * restarted board must not reuse a deterministic session/seq at the FPGA.
     * A random zero maps to 1 so RNG failure cannot cause an unbounded loop. */
    test_session = esp_random();
    if (!test_session) test_session = 1;
    test_seq = test_sent_ms = 0;
    test_waiting = false;
    ESP_LOGI(TAG, "UART_TEST boot session=%" PRIu32, test_session);
}
#endif
static void uart_test_frame(const score_frame_t *frame, void *context)
{
    (void)context;
    ESP_LOGI(TAG, "UART_TEST rx type=%02x session=%" PRIu32 " seq=%" PRIu32 " length=%u",
             frame->type, frame->session, frame->seq, frame->payload_len);
#if CONFIG_SCORE_UART_SELF_TEST
    if ((frame->type == SCORE_ACK || frame->type == SCORE_ERROR) &&
        frame->session == test_session && frame->seq == test_seq) test_waiting = false;
#endif
}
static void uart_test_poll(uint32_t now)
{
#if CONFIG_SCORE_UART_SELF_TEST
    /* Explicit test profile only: exactly three read-only requests, no retry. */
    if (test_waiting && (uint32_t)(now - test_sent_ms) >= 5000) {
        ESP_LOGW(TAG, "UART_TEST seq=%" PRIu32 " timeout (not an ACK)", test_seq);
        test_waiting = false;
    }
    if (!test_waiting && test_seq < 3) {
        uint8_t frame[32], payload[12] = {0};
        test_seq++;
        payload[8] = 1; /* LIST limit=1; initial generation and cursor=0. */
        size_t length = score_encode(frame, sizeof(frame), (uint8_t)test_seq,
                                      test_session, test_seq,
                                      test_seq == SCORE_LIST ? payload : NULL,
                                      test_seq == SCORE_LIST ? sizeof(payload) : 0);
        test_waiting = score_uart_send(frame, length);
        test_sent_ms = now;
        ESP_LOGI(TAG, "UART_TEST tx seq=%" PRIu32 " queued=%d", test_seq, test_waiting);
    }
#endif
    score_stream_feed(&uart_stream, NULL, 0, now, 100, uart_test_frame, NULL);
}
#endif

static void worker(void *arg)
{
    (void)arg;
    /* Created first so allocation failure cannot leave an unserviced BLE RX
     * characteristic. app_main releases us after synchronous NVS/RF startup. */
    ulTaskNotifyTake(pdTRUE, portMAX_DELAY);
    esp_err_t uart_result = score_uart_init();
#if CONFIG_SCORE_BLE_ENABLED
    const score_proxy_io_t io = { .uart_send = send_uart, .notify = send_ble,
                                  .disconnect = close_ble };
    score_proxy_init(&proxy, &io);
    ESP_LOGI(TAG, "business_buffers=%u (proxy=%u BLE=%u), stack=%u; RTOS/UART/BT allocations separate",
             (unsigned)(sizeof(proxy) + score_ble_buffer_bytes()), (unsigned)sizeof(proxy),
             (unsigned)score_ble_buffer_bytes(), SCORE_STACK_BYTES);
#else
#if CONFIG_SCORE_UART_SELF_TEST
    uart_test_start();
    ESP_LOGI(TAG, "UART-only profile; explicit finite query self-test enabled; no BLE");
#else
    ESP_LOGI(TAG, "UART-only profile; no automatic queries and no BLE");
#endif
#endif
    if (uart_result != ESP_OK) ESP_LOGW(TAG, "downstream UART unavailable; no storage success will be generated");
    xSemaphoreGive(startup_done);
    uint32_t last_stats = 0;
    for (;;) {
        uint32_t now = (uint32_t)(esp_timer_get_time() / 1000);
        /* Scratch lifetimes do not overlap; only one callback owns proxy. */
        union {
            uint8_t uart_bytes[128];
#if CONFIG_SCORE_BLE_ENABLED
            score_ble_fragment_t fragment;
#endif
        } scratch;
#if CONFIG_SCORE_BLE_ENABLED
        score_ble_link_t link;
        score_ble_link(&link);
        if (worker_epoch != 0 && (!link.connected || worker_epoch != link.epoch)) {
            score_proxy_disconnect(&proxy, worker_epoch);
            worker_epoch = 0;
        }
        /* A proxy fault requests asynchronous GAP termination. Never revive
         * that same physical connection just because proxy.connected=false. */
        if (link.connected && worker_epoch != link.epoch) {
            worker_epoch = link.epoch;
            score_proxy_connect(&proxy, worker_epoch, link.max_write, link.subscribed);
        }
        if (link.connected) score_proxy_link(&proxy, link.max_write, link.subscribed);
        for (unsigned i = 0; i < 2 && score_ble_receive(&scratch.fragment); ++i) {
            /* RX refreshed the ATT limit before enqueueing. Take a fresh
             * snapshot so a fast CAPS reply cannot use this turn's old limit. */
            score_ble_link(&link);
            if (link.connected && link.epoch == worker_epoch)
                score_proxy_link(&proxy, link.max_write, link.subscribed);
            SCORE_DIAG(score_diag_ingress(scratch.fragment.epoch, scratch.fragment.arrival_us, scratch.fragment.length));
            score_proxy_ble_feed(&proxy, scratch.fragment.epoch, scratch.fragment.bytes,
                                  scratch.fragment.length, now);
        }
#endif
        /* Drain at most one driver ring each turn; never trust event.size. */
        for (unsigned i = 0; i < 16; ++i) {
            bool reset;
            size_t length = score_uart_read(scratch.uart_bytes, sizeof(scratch.uart_bytes), &reset);
            if (reset) {
#if CONFIG_SCORE_BLE_ENABLED
                score_proxy_uart_reset(&proxy);
#else
                memset(&uart_stream, 0, sizeof(uart_stream));
#endif
            }
            if (length == 0) break;
#if CONFIG_SCORE_BLE_ENABLED
            score_proxy_uart_feed(&proxy, scratch.uart_bytes, length, now);
#else
            score_stream_feed(&uart_stream, scratch.uart_bytes, length, now, 100, uart_test_frame, NULL);
#endif
        }
#if CONFIG_SCORE_BLE_ENABLED
        score_proxy_poll(&proxy, now);
        score_ble_poll();
#else
        uart_test_poll(now);
#endif
        if ((uint32_t)(now - last_stats) >= 5000) {
            last_stats = now;
            const score_uart_stats_t *u = score_uart_stats();
            ESP_LOGI(TAG, "UART rx=%" PRIu32 " tx=%" PRIu32 " fifo=%" PRIu32
                     " full=%" PRIu32 " frame=%" PRIu32 " parity=%" PRIu32
                     " break=%" PRIu32 " io=%" PRIu32 " heap_min=%u largest=%u stack_free=%u",
                     u->rx_bytes, u->tx_bytes, u->fifo_overflow, u->buffer_full,
                     u->frame_error, u->parity_error, u->breaks, u->io_error,
                     (unsigned)heap_caps_get_minimum_free_size(MALLOC_CAP_8BIT),
                     (unsigned)heap_caps_get_largest_free_block(MALLOC_CAP_8BIT),
                     (unsigned)uxTaskGetStackHighWaterMark(NULL));
#if CONFIG_SCORE_BLE_ENABLED
            score_ble_stats_t b;
            score_ble_stats(&b);
            ESP_LOGI(TAG, "PROXY req=%" PRIu32 " retry=%" PRIu32 " reply=%" PRIu32
                     " changed=%" PRIu32 " timeout=%" PRIu32 " stale=%" PRIu32
                     " local=%" PRIu32 " reject=%" PRIu32 " notify_fail=%" PRIu32
                     " uart_bad=%" PRIu32 " uart_gap=%" PRIu32 " ble_bad=%" PRIu32,
                     proxy.stats.requests, proxy.stats.retries, proxy.stats.replies,
                     proxy.stats.changed, proxy.stats.timeouts, proxy.stats.stale,
                     proxy.stats.local_errors, b.rejected_writes, b.notify_failures,
                     proxy.uart_stream.bad_frames, proxy.uart_stream.timeouts,
                     proxy.ble_stream.bad_frames);
#endif
        }
        TickType_t poll_delay = pdMS_TO_TICKS(1);
        vTaskDelay(poll_delay ? poll_delay : 1);
    }
}

void score_service_start(void)
{
    SCORE_DIAG(score_diag_start());
    startup_done = xSemaphoreCreateBinaryStatic(&startup_control);
    TaskHandle_t worker_task;
    if (xTaskCreatePinnedToCore(worker, "score", SCORE_STACK_BYTES, NULL,
                                SCORE_PRIORITY, &worker_task, SCORE_CORE) != pdPASS) {
        ESP_LOGE(TAG, "worker allocation failed; MIDI remains available");
        return;
    }
#if CONFIG_SCORE_BLE_ENABLED
    /* Keep synchronous NVS/RF initialization in app startup, before any MIDI
     * task exists. Only the later host-sync wait has a bounded 5s timeout. */
    esp_err_t ble_result = score_ble_start();
    if (ble_result != ESP_OK)
        ESP_LOGE(TAG, "BLE startup failed: %s; MIDI will still start", esp_err_to_name(ble_result));
#endif
    xTaskNotifyGive(worker_task);
    /* UART setup only; no remaining NVS/RF writes, central or FPGA wait. */
    if (xSemaphoreTake(startup_done, pdMS_TO_TICKS(10000)) != pdTRUE)
        ESP_LOGE(TAG, "score startup exceeded 10s; MIDI starting, inspect startup fault");
}
