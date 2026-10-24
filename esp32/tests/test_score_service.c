#include <assert.h>
#include <setjmp.h>
#include <stdio.h>
#include <string.h>

#ifndef CONFIG_SCORE_UART_SELF_TEST
#define CONFIG_SCORE_UART_SELF_TEST 1
#endif
#define CONFIG_SCORE_BLE_ENABLED 0
#include "score_service_stub.h"
#include "../main/score_service.c"

/* Execute the production worker's startup and one loop, then return at its
 * first RTOS delay. No task, serial port or radio is created by these stubs. */
static jmp_buf worker_return;
static uint32_t random_value,clock_ms;
static unsigned random_calls,uart_init_calls,sent_count;
static struct { uint8_t bytes[32]; size_t length; } sent[3];

uint32_t esp_random(void) { ++random_calls; return random_value; }
int64_t esp_timer_get_time(void) { return (int64_t)clock_ms*1000; }
unsigned ulTaskNotifyTake(int clear,unsigned wait)
{ assert(clear==pdTRUE && wait==portMAX_DELAY); return 1; }
int xTaskCreatePinnedToCore(void (*task)(void*),const char *name,unsigned stack,
                            void *arg,unsigned priority,TaskHandle_t *handle,int core)
{
    (void)task; (void)name; (void)stack; (void)arg; (void)priority; (void)handle; (void)core;
    return 0;
}
void xTaskNotifyGive(TaskHandle_t task) { (void)task; }
void vTaskDelay(TickType_t delay) { assert(delay>=1); longjmp(worker_return,1); }
unsigned uxTaskGetStackHighWaterMark(TaskHandle_t task) { (void)task; return 4096; }
size_t heap_caps_get_minimum_free_size(unsigned caps) { (void)caps; return 65536; }
size_t heap_caps_get_largest_free_block(unsigned caps) { (void)caps; return 32768; }
esp_err_t score_uart_init(void) { ++uart_init_calls; return ESP_OK; }
bool score_uart_send(const uint8_t *bytes,size_t length)
{
    assert(sent_count<3 && length<=sizeof(sent[0].bytes));
    memcpy(sent[sent_count].bytes,bytes,length); sent[sent_count++].length=length;
    return true;
}
size_t score_uart_read(uint8_t *bytes,size_t capacity,bool *reset)
{ (void)bytes; (void)capacity; *reset=false; return 0; }
const score_uart_stats_t *score_uart_stats(void)
{ static const score_uart_stats_t empty={0}; return &empty; }

static void run_boot(uint32_t next_random)
{
    random_value=next_random; clock_ms=1;
    random_calls=uart_init_calls=sent_count=0;
    memset(&uart_stream,0,sizeof(uart_stream));
    memset(sent,0,sizeof(sent));
    startup_done=xSemaphoreCreateBinaryStatic(&startup_control);
    if (setjmp(worker_return)==0) worker(NULL);
    assert(uart_init_calls==1);
}

#if CONFIG_SCORE_UART_SELF_TEST
static score_frame_t decoded(unsigned index)
{
    score_frame_t frame;
    assert(index<sent_count && score_decode(sent[index].bytes,sent[index].length,&frame));
    return frame;
}

static void reply(uint32_t session,uint32_t seq)
{
    uint8_t payload[4]={(uint8_t)seq,0,0,0};
    score_frame_t frame={.type=SCORE_ACK,.session=session,.seq=seq,
                         .payload=payload,.payload_len=sizeof(payload)};
    uart_test_frame(&frame,NULL);
}

static void test_fresh_boot_identity_and_zero(void)
{
    run_boot(UINT32_C(0x13572468));
    score_frame_t first=decoded(0);
    assert(random_calls==1 && first.session==UINT32_C(0x13572468));
    assert(first.type==SCORE_CAPS && first.seq==1 && first.payload_len==0);
    uint32_t previous=first.session;
    run_boot(UINT32_C(0x89abcdef));
    score_frame_t second=decoded(0);
    assert(second.session!=previous && second.session==UINT32_C(0x89abcdef));
    assert(second.type==SCORE_CAPS && second.seq==1 && random_calls==1);
    run_boot(0);
    assert(decoded(0).session==1 && random_calls==1); /* no unbounded retry loop */
}

static void test_old_response_and_finite_queries(void)
{
    run_boot(17);
    reply(16,1); uart_test_poll(2);
    assert(sent_count==1 && test_waiting); /* stale boot cannot advance self-test */
    reply(17,1); uart_test_poll(3);
    score_frame_t status=decoded(1);
    assert(status.type==SCORE_STATUS && status.session==17 && status.seq==2);
    reply(17,2); uart_test_poll(4);
    score_frame_t list=decoded(2);
    assert(list.type==SCORE_LIST && list.session==17 && list.seq==3 && list.payload_len==12);
    assert(score_get_u32(list.payload)==0 && score_get_u32(list.payload+4)==0);
    assert(score_get_u16(list.payload+8)==1 && score_get_u16(list.payload+10)==0);
    reply(17,3);
    uart_test_poll(5); uart_test_poll(50000);
    assert(sent_count==3 && random_calls==1 && !test_waiting);
    run_boot(23);
    uart_test_poll(5000); assert(sent_count==1); /* 4999 ms after initial send */
    uart_test_poll(5001); assert(sent_count==2 && decoded(1).type==SCORE_STATUS);
    uart_test_poll(10001); assert(sent_count==3 && decoded(2).type==SCORE_LIST);
    uart_test_poll(15001); uart_test_poll(20000); assert(sent_count==3);
}
#endif

int main(void)
{
#if CONFIG_SCORE_UART_SELF_TEST
    test_fresh_boot_identity_and_zero();
    test_old_response_and_finite_queries();
    puts("PASS: production UART self-test boot sessions, stale replies and finite queries");
#else
    run_boot(99);
    for (unsigned i=0;i<20;++i) uart_test_poll(i*5000);
    assert(sent_count==0 && random_calls==0);
    puts("PASS: production UART service with self-test disabled sends no autonomous requests");
#endif
    return 0;
}
