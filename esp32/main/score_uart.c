#include "score_uart.h"

#include "driver/gpio.h"
#include "driver/uart.h"
#include "esp_log.h"
#include "freertos/FreeRTOS.h"
#include "freertos/queue.h"
#include "score_protocol.h"
#include "sdkconfig.h"
#include "score_diag.h"

enum { SCORE_UART = UART_NUM_1, RX_RING_BYTES = 2048, EVENT_COUNT = 16 };
static const char *TAG = "score_uart";
static QueueHandle_t events;
static bool ready;
static score_uart_stats_t stats;

static bool reserved_pin(int pin)
{
    /* ESP32-S3-WROOM-1 N16R8: flash/PSRAM, boot straps and board RGB are reserved. */
    return pin == 0 || pin == 3 || pin == 45 || pin == 46 ||
           pin == 48 ||
           (pin >= 22 && pin <= 37) || pin == 19 || pin == 20 ||
           pin == 43 || pin == 44 || pin == CONFIG_BRIDGE_SCLK_PIN ||
           pin == CONFIG_BRIDGE_MOSI_PIN || pin == CONFIG_BRIDGE_CS_PIN ||
           pin == CONFIG_BRIDGE_READY_PIN || pin == CONFIG_BRIDGE_RX_MARK_PIN ||
           pin == CONFIG_BRIDGE_TX_MARK_PIN;
}

static bool usable_pin(int pin, bool output)
{
    /* Keep -1 outside IDF's mask macros. With a literal sdkconfig=-1 those
     * macros expand a negative shift even in a short-circuited condition. */
    if (pin < 0 || pin > 48 || reserved_pin(pin)) return false;
    return GPIO_IS_VALID_GPIO(pin) && (!output || GPIO_IS_VALID_OUTPUT_GPIO(pin));
}

esp_err_t score_uart_init(void)
{
    const int tx = CONFIG_SCORE_UART_TX_PIN, rx = CONFIG_SCORE_UART_RX_PIN;
    if (tx == -1 && rx == -1) {
        ESP_LOGW(TAG, "UART1 disabled: TX/RX not assigned; no downstream ACK possible");
        return ESP_ERR_INVALID_STATE;
    }
    if (tx == rx || !usable_pin(tx, true) || !usable_pin(rx, false)) {
        ESP_LOGE(TAG, "unsafe/conflicting UART1 pins TX=%d RX=%d; disabled", tx, rx);
        return ESP_ERR_INVALID_ARG;
    }
    const uart_config_t config = {
        .baud_rate = 1000000,
        .data_bits = UART_DATA_8_BITS,
        .parity = UART_PARITY_DISABLE,
        .stop_bits = UART_STOP_BITS_1,
        .flow_ctrl = UART_HW_FLOWCTRL_DISABLE,
        .source_clk = UART_SCLK_DEFAULT,
    };
    esp_err_t err = uart_param_config(SCORE_UART, &config);
    if (err == ESP_OK) err = uart_set_pin(SCORE_UART, tx, rx,
                                         UART_PIN_NO_CHANGE, UART_PIN_NO_CHANGE);
    if (err == ESP_OK) err = uart_driver_install(SCORE_UART, RX_RING_BYTES, 0,
                                                EVENT_COUNT, &events, 0);
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "UART1 initialization failed: %s", esp_err_to_name(err));
        return err;
    }
    ready = true;
    ESP_LOGI(TAG, "UART1 1000000/8N1 TX=%d RX=%d driver_core=0 rx_ring=%d tx_ring=0",
             tx, rx, RX_RING_BYTES);
    return ESP_OK;
}

bool score_uart_send(const uint8_t *bytes, size_t length)
{
    if (!ready || !bytes || length == 0 || length > SCORE_MAX_FRAME) return false;
    /* No TX ring: driver consumes caller bytes before returning. */
#if CONFIG_SCORE_DIAGNOSTICS
    uint64_t diagnostic_start = score_diag_clock();
#endif
    int sent = uart_write_bytes(SCORE_UART, bytes, length);
    SCORE_DIAG(score_diag_uart_io(sent > 0 ? (uint32_t)sent : 0, 0,
                                 (uint32_t)(score_diag_clock() - diagnostic_start)));
    if (sent != (int)length) {
        stats.io_error++;
        return false;
    }
    stats.tx_bytes += (uint32_t)sent;
    return true;
}

size_t score_uart_read(uint8_t *bytes, size_t capacity, bool *reset_stream)
{
    *reset_stream = false;
    if (!ready) return 0;
    uart_event_t event;
    /* Event length is not trusted as the size of our small read buffer. */
    for (unsigned i = 0; i < EVENT_COUNT && xQueueReceive(events, &event, 0); ++i) {
        switch (event.type) {
        case UART_FIFO_OVF: stats.fifo_overflow++; *reset_stream = true; break;
        case UART_BUFFER_FULL: stats.buffer_full++; *reset_stream = true; break;
        case UART_FRAME_ERR: stats.frame_error++; *reset_stream = true; break;
        case UART_PARITY_ERR: stats.parity_error++; *reset_stream = true; break;
        case UART_BREAK: stats.breaks++; *reset_stream = true; break;
        default: break;
        }
    }
    if (*reset_stream) {
        uart_flush_input(SCORE_UART);
        xQueueReset(events);
        return 0;
    }
    int count = uart_read_bytes(SCORE_UART, bytes, capacity, 0);
    if (count < 0) {
        stats.io_error++;
        *reset_stream = true;
        return 0;
    }
    stats.rx_bytes += (uint32_t)count;
    SCORE_DIAG(score_diag_uart_io(0, (uint32_t)count, 0));
    return (size_t)count;
}

const score_uart_stats_t *score_uart_stats(void)
{
    return &stats;
}
