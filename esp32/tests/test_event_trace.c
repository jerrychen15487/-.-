/* Production recorder with a bounded FIFO mock: ownership, limits and overflow. */
#include <stdio.h>
#include <string.h>
#include "../main/event_trace.c"
static unsigned hex_lines;
void test_log(const char *tag, const char *format, ...) { (void)tag; (void)format; }
void test_hex(const char *tag, const void *bytes, size_t length)
{ (void)tag; (void)bytes; assert(length <= 64); ++hex_lines; }
QueueHandle_t xQueueCreateStatic(unsigned capacity, unsigned size, uint8_t *storage, StaticQueue_t *c)
{ *c = (StaticQueue_t){.storage=storage, .capacity=capacity, .size=size}; return c; }
BaseType_t xQueueSend(QueueHandle_t q, const void *item, TickType_t wait)
{
    assert(wait == 0);
    if (q->count == q->capacity) return 0;
    memcpy(q->storage + ((q->head + q->count) % q->capacity) * q->size, item, q->size);
    ++q->count; return pdTRUE;
}
BaseType_t xQueueReceive(QueueHandle_t q, void *item, TickType_t wait)
{
    assert(wait == 0);
    if (!q->count) return 0;
    memcpy(item, q->storage + q->head * q->size, q->size);
    q->head = (q->head + 1) % q->capacity; --q->count; return pdTRUE;
}
int main(void)
{
    uint8_t bytes[256]; memset(bytes, 0x90, sizeof(bytes));
    event_trace_init(); event_trace_session(7);
    event_trace_record(0, bytes, 0, 123, 0);
    assert(samples->count == 0);
    event_trace_record(0, bytes, sizeof(bytes), 123, 0);
    memset(bytes, 0, sizeof(bytes)); /* USB transfer buffer can immediately be reused. */
    sample_t s; assert(xQueueReceive(samples, &s, 0) == pdTRUE);
    assert(s.session == 7 && s.length == 256 && s.copied == 64 && s.received_us == 123);
    for (unsigned i=0; i<64; ++i) assert(s.bytes[i] == 0x90);
    for (unsigned i=0; i<32; ++i) {
        event_trace_record(0, bytes, 4, 124, 0);
        event_trace_record(1, bytes, 6, 124, -1);
    }
    assert(samples->count == 31 && counts[0] == 16 && counts[1] == 16);
    event_trace_dump(); assert(hex_lines == 31 && samples->count == 0);
    event_trace_session(8);
    for (unsigned i=0; i<16; ++i) {
        event_trace_record(0, bytes, 4, 125, 0);
        event_trace_record(1, bytes, 6, 125, 0);
    }
    event_trace_session(9); /* Reconnect before old samples were printed. */
    event_trace_record(0, bytes, 4, 126, 0);
    assert(dropped == 1 && samples->count == 32);
    assert(xQueueReceive(samples, &s, 0) == pdTRUE && s.session == 8);
    event_trace_record(1, bytes, 6, 126, -1);
    assert(samples->count == 32);
    event_trace_dump(); assert(samples->count == 0 && hex_lines == 63);
    puts("PASS trace snapshot ownership, truncation, per-session budgets, bounded drain, overflow and reconnect");
    return 0;
}
