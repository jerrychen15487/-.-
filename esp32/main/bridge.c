#include "bridge.h"
#include "bridge_latency_stats.h"
#include "midi_codec.h"
#include "event_trace.h"
#include <inttypes.h>
#include <stdatomic.h>
#include "sdkconfig.h"
#include "driver/gpio.h"
#include "driver/spi_master.h"
#include "esp_log.h"
#include "esp_timer.h"
#include "freertos/FreeRTOS.h"
#include "freertos/queue.h"
#include "freertos/semphr.h"
#include "freertos/task.h"

typedef struct {
    midi_frame_t frame;
    uint32_t session;
    int64_t received_us;
    bool from_usb;
} queued_event_t;
typedef struct {
    uint32_t accepted, skipped, invalid, queue_full, sent, spi_errors, usb_errors;
    uint32_t program_in, program_sent;
    uint8_t last_program, last_program_channel;
    uint32_t canceled, over_5ms, queue_peak, sessions;
    int64_t max_latency_us, first_rx_us, last_tx_us;
    bridge_latency_stats_t usb_note_on_latency;
} bridge_stats_t;

static const char *TAG = "bridge";
static StaticQueue_t queue_control;
static uint8_t queue_storage[BRIDGE_QUEUE_LENGTH * sizeof(queued_event_t)];
static QueueHandle_t event_queue;
static TaskHandle_t tx_task_handle;
static spi_device_handle_t spi;
static StaticSemaphore_t send_lock_control;
static SemaphoreHandle_t send_lock;
static atomic_uint session;
static bridge_stats_t stats;
static portMUX_TYPE stats_lock = portMUX_INITIALIZER_UNLOCKED;
static atomic_int octave_shift;
static int rx_marker, tx_marker;
static bool queue_frame(const midi_frame_t *frame, int64_t received_us, bool from_usb);

void bridge_set_octave_shift(int shift)
{
    if (shift < -4) shift = -4;
    if (shift > 4) shift = 4;
    atomic_store(&octave_shift, shift);
}

#ifndef CONFIG_BRIDGE_READY_BYPASS
static void ready_isr(void *arg)
{
    BaseType_t woken = pdFALSE;
    vTaskNotifyGiveFromISR(tx_task_handle, &woken);
    if (woken) portYIELD_FROM_ISR();
}

#endif

static bool ready_allowed(void)
{
#ifdef CONFIG_BRIDGE_READY_BYPASS
    return true;
#else
    return gpio_get_level(CONFIG_BRIDGE_READY_PIN) != 0;
#endif
}

static void emit_frame(const midi_frame_t *frame, void *context)
{
    queue_frame(frame, *(const int64_t *)context, true);
}

static bool queue_frame(const midi_frame_t *frame, int64_t received_us, bool from_usb)
{
    if (!frame || !event_queue) return false;
    midi_frame_t adjusted = *frame;
    if (from_usb && (adjusted.bytes[0] == MIDI_NOTE_ON || adjusted.bytes[0] == MIDI_NOTE_OFF)) {
        int note = (int)adjusted.bytes[2] + 12 * atomic_load(&octave_shift);
        if (note < 0) note = 0;
        if (note > 127) note = 127;
        adjusted.bytes[2] = (uint8_t)note;
    }
    queued_event_t event = {.frame = adjusted, .session = atomic_load(&session),
                            .received_us = received_us, .from_usb = from_usb};
    BaseType_t queued = xQueueSend(event_queue, &event, 0);
    UBaseType_t depth = uxQueueMessagesWaiting(event_queue);
    portENTER_CRITICAL(&stats_lock);
    if (queued == pdTRUE) {
        ++stats.accepted;
        if (frame->bytes[0] == MIDI_PROGRAM_CHANGE) {
            ++stats.program_in;
            stats.last_program = frame->bytes[2];
            stats.last_program_channel = frame->bytes[1] & 0x0f;
        }
    }
    else ++stats.queue_full;
    if (depth > stats.queue_peak) stats.queue_peak = depth;
    portEXIT_CRITICAL(&stats_lock);
    return queued == pdTRUE;
}

bool bridge_send_local(const midi_frame_t *frame, int64_t received_us)
{
    return queue_frame(frame, received_us, false);
}

void bridge_receive(const uint8_t *bytes, size_t length, int64_t received_us)
{
    event_trace_record(0, bytes, length, received_us, 0);
    if (CONFIG_BRIDGE_RX_MARK_PIN >= 0) gpio_set_level(CONFIG_BRIDGE_RX_MARK_PIN, rx_marker ^= 1);
    midi_decode_stats_t result = midi_decode_transfer(bytes, length, emit_frame, &received_us);
    portENTER_CRITICAL(&stats_lock);
    if (length && !stats.first_rx_us) stats.first_rx_us = received_us;
    stats.skipped += result.skipped;
    stats.invalid += result.invalid;
    portEXIT_CRITICAL(&stats_lock);
}

void bridge_usb_error(void)
{
    portENTER_CRITICAL(&stats_lock);
    ++stats.usb_errors;
    portEXIT_CRITICAL(&stats_lock);
}

void bridge_end_session(void)
{
    /* Serialize cancellation with the very short SPI transaction, never with
     * the READY wait. An already-started frame may finish before cancellation. */
    xSemaphoreTake(send_lock, portMAX_DELAY);
    /* Invalidate both queued events and an event held by TX waiting on READY. */
    atomic_fetch_add(&session, 1);
    UBaseType_t pending = uxQueueMessagesWaiting(event_queue);
    xQueueReset(event_queue);
    portENTER_CRITICAL(&stats_lock);
    stats.canceled += pending;
    portEXIT_CRITICAL(&stats_lock);
    xSemaphoreGive(send_lock);
    xTaskNotifyGive(tx_task_handle);
}

void bridge_start_session(void)
{
    bridge_end_session();
    event_trace_session(atomic_load(&session));
    portENTER_CRITICAL(&stats_lock);
    ++stats.sessions;
    portEXIT_CRITICAL(&stats_lock);
}

static void tx_task(void *arg)
{
#ifndef CONFIG_BRIDGE_READY_BYPASS
    const gpio_config_t ready_config = {
        .pin_bit_mask = 1ULL << CONFIG_BRIDGE_READY_PIN,
        .mode = GPIO_MODE_INPUT, .pull_down_en = GPIO_PULLDOWN_ENABLE,
        .intr_type = GPIO_INTR_POSEDGE,
    };
    ESP_ERROR_CHECK(gpio_config(&ready_config));
    ESP_ERROR_CHECK(gpio_install_isr_service(0));
    ESP_ERROR_CHECK(gpio_isr_handler_add(CONFIG_BRIDGE_READY_PIN, ready_isr, NULL));
#endif
    const spi_bus_config_t bus = {
        .mosi_io_num = CONFIG_BRIDGE_MOSI_PIN, .miso_io_num = -1,
        .sclk_io_num = CONFIG_BRIDGE_SCLK_PIN, .quadwp_io_num = -1, .quadhd_io_num = -1,
        .max_transfer_sz = MIDI_FRAME_SIZE,
    };
    /* Six bytes fit in the peripheral FIFO: no DMA or per-frame allocation. */
    ESP_ERROR_CHECK(spi_bus_initialize(SPI2_HOST, &bus, SPI_DMA_DISABLED));
    const spi_device_interface_config_t device = {
        .clock_speed_hz = CONFIG_BRIDGE_SPI_HZ, .mode = 0,
        .spics_io_num = CONFIG_BRIDGE_CS_PIN, .queue_size = 1,
    };
    ESP_ERROR_CHECK(spi_bus_add_device(SPI2_HOST, &device, &spi));
    xTaskNotifyGive((TaskHandle_t)arg);
    for (;;) {
        queued_event_t event;
        xQueueReceive(event_queue, &event, portMAX_DELAY);
wait_ready:
        while (event.session == atomic_load(&session) && !ready_allowed()) {
            /* READY rising and cancellation both wake us. Stale notifications
             * are harmless: always recheck level and session before sleeping. */
            ulTaskNotifyTake(pdTRUE, portMAX_DELAY);
        }
        xSemaphoreTake(send_lock, portMAX_DELAY);
        if (event.session != atomic_load(&session)) {
            xSemaphoreGive(send_lock);
            portENTER_CRITICAL(&stats_lock);
            ++stats.canceled;
            portEXIT_CRITICAL(&stats_lock);
            continue;
        }
        if (!ready_allowed()) {
            xSemaphoreGive(send_lock);
            goto wait_ready;
        }
        spi_transaction_t transaction = {.length = MIDI_FRAME_SIZE * 8,
                                         .tx_buffer = event.frame.bytes};
        esp_err_t err = spi_device_polling_transmit(spi, &transaction);
        int64_t completed_us = esp_timer_get_time();
        int64_t elapsed = completed_us - event.received_us;
        if (err == ESP_OK && CONFIG_BRIDGE_TX_MARK_PIN >= 0) {
            gpio_set_level(CONFIG_BRIDGE_TX_MARK_PIN, tx_marker ^= 1);
        }
        portENTER_CRITICAL(&stats_lock);
        if (err == ESP_OK) {
            ++stats.sent;
            if (event.frame.bytes[0] == MIDI_PROGRAM_CHANGE) ++stats.program_sent;
            stats.last_tx_us = completed_us;
            if (elapsed > stats.max_latency_us) stats.max_latency_us = elapsed;
            if (elapsed > 5000) ++stats.over_5ms;
            if (event.from_usb && event.frame.bytes[0] == MIDI_NOTE_ON)
                bridge_latency_record(&stats.usb_note_on_latency, elapsed);
        } else ++stats.spi_errors;
        portEXIT_CRITICAL(&stats_lock);
        event_trace_record(1, event.frame.bytes, MIDI_FRAME_SIZE, event.received_us, err);
        xSemaphoreGive(send_lock);
    }
}

static void stats_task(void *arg)
{
    for (;;) {
        vTaskDelay(pdMS_TO_TICKS(5000));
        portENTER_CRITICAL(&stats_lock);
        bridge_stats_t s = stats;
        portEXIT_CRITICAL(&stats_lock);
        ESP_LOGI(TAG, "in=%"PRIu32" sent=%"PRIu32" skip=%"PRIu32" invalid=%"PRIu32
                 " full=%"PRIu32" cancel=%"PRIu32" usb_err=%"PRIu32" spi_err=%"PRIu32
                 " peak=%"PRIu32" max_us=%"PRId64" over_5ms=%"PRIu32
                 " sessions=%"PRIu32" span_ms=%"PRId64,
                 s.accepted, s.sent, s.skipped, s.invalid, s.queue_full, s.canceled,
                 s.usb_errors, s.spi_errors, s.queue_peak, s.max_latency_us, s.over_5ms, s.sessions,
                 s.last_tx_us > s.first_rx_us ? (s.last_tx_us - s.first_rx_us) / 1000 : 0);
        ESP_LOGI(TAG, "program in=%"PRIu32" sent=%"PRIu32" last=%u channel=%u",
                 s.program_in, s.program_sent,
                 (unsigned)s.last_program, (unsigned)s.last_program_channel);
        ESP_LOGI(TAG, "usb_note_on n=%"PRIu32" min_us=%"PRId64" mean_us=%"PRIu64
                 " max_us=%"PRId64" jitter_us=%"PRId64" over_5ms=%"PRIu32,
                 s.usb_note_on_latency.count, s.usb_note_on_latency.min_us,
                 bridge_latency_mean_us(&s.usb_note_on_latency),
                 s.usb_note_on_latency.max_us,
                 s.usb_note_on_latency.count ?
                     s.usb_note_on_latency.max_us - s.usb_note_on_latency.min_us : 0,
                 s.usb_note_on_latency.over_5ms);
        event_trace_dump();
    }
}

static void validate_pins(void)
{
    const int pins[] = {CONFIG_BRIDGE_SCLK_PIN, CONFIG_BRIDGE_MOSI_PIN, CONFIG_BRIDGE_CS_PIN,
                       CONFIG_BRIDGE_READY_PIN, CONFIG_BRIDGE_RX_MARK_PIN, CONFIG_BRIDGE_TX_MARK_PIN};
    for (size_t i = 0; i < sizeof(pins) / sizeof(pins[0]); ++i) {
        int pin = pins[i];
        if (pin < 0) continue;
        bool valid = i == 3 ? GPIO_IS_VALID_GPIO(pin) : GPIO_IS_VALID_OUTPUT_GPIO(pin);
        /* USB, console, octal PSRAM/flash, boot straps and on-board RGB stay reserved. */
        if (!valid || pin == 19 || pin == 20 || (pin >= 26 && pin <= 37) ||
            pin == 43 || pin == 44 || pin == 0 || pin == 3 || pin == 45 || pin == 46 || pin == 48) {
            ESP_LOGE(TAG, "Unavailable/reserved GPIO %d", pin);
            ESP_ERROR_CHECK(ESP_ERR_INVALID_ARG);
        }
        for (size_t j = 0; j < i; ++j) if (pins[j] == pin) ESP_ERROR_CHECK(ESP_ERR_INVALID_ARG);
    }
}

void bridge_init(void)
{
    validate_pins();
    event_trace_init();
#ifdef CONFIG_BRIDGE_READY_BYPASS
    ESP_LOGW(TAG, "READY=BYPASS (software test; GPIO not driven; no FPGA confirmation)");
#else
    ESP_LOGI(TAG, "READY=GPIO%d (active high)", CONFIG_BRIDGE_READY_PIN);
#endif
#ifdef CONFIG_BRIDGE_DETAIL_LOG
    ESP_LOGW(TAG, "log=DETAIL (not for latency acceptance)");
#else
    ESP_LOGI(TAG, "log=ACCEPT (5-second summary)");
#endif
    const int markers[] = {CONFIG_BRIDGE_RX_MARK_PIN, CONFIG_BRIDGE_TX_MARK_PIN};
    for (size_t i = 0; i < 2; ++i) if (markers[i] >= 0) {
        ESP_ERROR_CHECK(gpio_reset_pin(markers[i]));
        ESP_ERROR_CHECK(gpio_set_direction(markers[i], GPIO_MODE_OUTPUT));
        ESP_ERROR_CHECK(gpio_set_level(markers[i], 0));
    }
    event_queue = xQueueCreateStatic(BRIDGE_QUEUE_LENGTH, sizeof(queued_event_t),
                                     queue_storage, &queue_control);
    configASSERT(event_queue);
    send_lock = xSemaphoreCreateMutexStatic(&send_lock_control);
    configASSERT(send_lock);
    BaseType_t ok = xTaskCreatePinnedToCore(tx_task, "midi_spi", 4096, xTaskGetCurrentTaskHandle(),
                                           BRIDGE_TX_PRIORITY, &tx_task_handle, BRIDGE_CORE);
    configASSERT(ok == pdPASS);
    ulTaskNotifyTake(pdTRUE, portMAX_DELAY);
    ok = xTaskCreatePinnedToCore(stats_task, "midi_stats", 3072, NULL, 3, NULL, 0);
    configASSERT(ok == pdPASS);
}
