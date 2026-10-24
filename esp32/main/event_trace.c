#include "event_trace.h"
#ifdef CONFIG_BRIDGE_DETAIL_LOG
#include <inttypes.h>
#include <string.h>
#include "esp_log.h"
#include "freertos/FreeRTOS.h"
#include "freertos/queue.h"

typedef struct {
    uint32_t session;
    int64_t received_us;
    int kind, status;
    size_t length, copied;
    uint8_t bytes[64];
} sample_t;
static StaticQueue_t control;
static uint8_t storage[32 * sizeof(sample_t)];
static QueueHandle_t samples;
static portMUX_TYPE lock = portMUX_INITIALIZER_UNLOCKED;
static uint32_t current_session, dropped;
static unsigned counts[2];

void event_trace_init(void)
{
    samples = xQueueCreateStatic(32, sizeof(sample_t), storage, &control);
    configASSERT(samples);
}
void event_trace_session(uint32_t session)
{
    portENTER_CRITICAL(&lock);
    current_session = session;
    counts[0] = counts[1] = 0;
    portEXIT_CRITICAL(&lock);
}
void event_trace_record(int kind, const uint8_t *bytes, size_t length, int64_t received_us, int status)
{
    if (!length) return;
    portENTER_CRITICAL(&lock);
    if (counts[kind] >= 16) { portEXIT_CRITICAL(&lock); return; }
    ++counts[kind];
    uint32_t session = current_session;
    portEXIT_CRITICAL(&lock);
    sample_t sample = {.session=session, .received_us=received_us, .kind=kind,
                       .status=status, .length=length, .copied=length < 64 ? length : 64};
    memcpy(sample.bytes, bytes, sample.copied);
    if (xQueueSend(samples, &sample, 0) != pdTRUE) {
        portENTER_CRITICAL(&lock);
        ++dropped;
        portEXIT_CRITICAL(&lock);
    }
}
void event_trace_dump(void)
{
    sample_t s;
    /* Bounded work even if another connection starts during the dump. */
    for (unsigned i=0; i<32 && xQueueReceive(samples, &s, 0) == pdTRUE; ++i) {
        ESP_LOGI("sample", "session=%"PRIu32" %s rx_us=%"PRId64" length=%u copied=%u status=%d",
                 s.session, s.kind ? "SPI" : "USB/SIM", s.received_us,
                 (unsigned)s.length, (unsigned)s.copied, s.status);
        ESP_LOG_BUFFER_HEX("sample", s.bytes, s.copied);
    }
    portENTER_CRITICAL(&lock);
    uint32_t lost = dropped;
    portEXIT_CRITICAL(&lock);
    if (lost) ESP_LOGW("sample", "dropped=%"PRIu32" (sampling only)", lost);
}
#endif
