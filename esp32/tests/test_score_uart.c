#include <assert.h>
#include <stdio.h>
#include <string.h>
#include "score_uart_stub.h"
#include "../main/score_uart.c"

int stub_tx_pin,stub_rx_pin,stub_rx_marker,stub_tx_marker;
static esp_err_t param_result,pin_result,driver_result;
static int read_result,write_result;
static unsigned param_calls,pin_calls,driver_calls,write_calls,flush_calls,read_calls;
static size_t largest_read;
static uart_config_t actual_config;
static StaticQueue_t event_queue;
static uint8_t event_storage[16*sizeof(uart_event_t)];
static uint8_t incoming[2048];
static size_t incoming_length,incoming_offset;

esp_err_t uart_param_config(int port,const uart_config_t *config)
{ assert(port==1); ++param_calls; actual_config=*config; return param_result; }
esp_err_t uart_set_pin(int port,int tx,int rx,int rts,int cts)
{
    assert(port==1 && tx==stub_tx_pin && rx==stub_rx_pin);
    assert(rts==UART_PIN_NO_CHANGE && cts==UART_PIN_NO_CHANGE);
    ++pin_calls; return pin_result;
}
esp_err_t uart_driver_install(int port,int rx_bytes,int tx_bytes,int count,
                              QueueHandle_t *queue,int flags)
{
    assert(port==1 && rx_bytes==2048 && tx_bytes==0 && count==16 && flags==0);
    ++driver_calls;
    if (driver_result==ESP_OK)
        *queue=xQueueCreateStatic(16,sizeof(uart_event_t),event_storage,&event_queue);
    return driver_result;
}
int uart_write_bytes(int port,const void *bytes,size_t length)
{
    assert(port==1 && bytes && length<=SCORE_MAX_FRAME); ++write_calls;
    return write_result==-9999 ? (int)length : write_result;
}
int uart_read_bytes(int port,void *bytes,size_t length,unsigned wait)
{
    assert(port==1 && wait==0); ++read_calls;
    if (length>largest_read) largest_read=length;
    if (read_result<0) return read_result;
    size_t remaining=incoming_length-incoming_offset;
    if (remaining>length) remaining=length;
    memcpy(bytes,incoming+incoming_offset,remaining); incoming_offset+=remaining;
    return (int)remaining;
}
esp_err_t uart_flush_input(int port)
{ assert(port==1); ++flush_calls; incoming_length=incoming_offset=0; return ESP_OK; }

static void fresh_process(void)
{
    ready=false; events=NULL; memset(&stats,0,sizeof(stats));
    stub_tx_pin=14; stub_rx_pin=15; stub_rx_marker=stub_tx_marker=-1;
    param_result=pin_result=driver_result=ESP_OK;
    read_result=0; write_result=-9999;
    param_calls=pin_calls=driver_calls=write_calls=flush_calls=read_calls=0;
    largest_read=0; incoming_length=incoming_offset=0;
}
static void push_event(int type,size_t size)
{
    uart_event_t e={type,size}; assert(xQueueSend(events,&e,0)==pdTRUE);
}

static void test_unassigned_and_reserved_pins(void)
{
    fresh_process(); stub_tx_pin=stub_rx_pin=-1;
    assert(score_uart_init()==ESP_ERR_INVALID_STATE && param_calls==0);
    uint8_t byte=0; bool reset=true;
    assert(!score_uart_send(&byte,1));
    assert(score_uart_read(&byte,1,&reset)==0 && !reset);
    const int bad[]={-1,0,3,10,11,12,13,19,20,22,25,26,32,33,37,43,44,45,46,48,49};
    for (size_t i=0;i<sizeof(bad)/sizeof(*bad);++i) {
        fresh_process(); stub_tx_pin=bad[i];
        assert(score_uart_init()==ESP_ERR_INVALID_ARG && param_calls==0);
        fresh_process(); stub_rx_pin=bad[i];
        assert(score_uart_init()==ESP_ERR_INVALID_ARG && param_calls==0);
    }
    fresh_process(); stub_rx_pin=stub_tx_pin;
    assert(score_uart_init()==ESP_ERR_INVALID_ARG);
    fresh_process(); stub_rx_marker=stub_tx_pin;
    assert(score_uart_init()==ESP_ERR_INVALID_ARG);
    fresh_process(); stub_tx_marker=stub_rx_pin;
    assert(score_uart_init()==ESP_ERR_INVALID_ARG);
}

static void test_initialization_failures(void)
{
    fresh_process(); param_result=ESP_FAIL;
    assert(score_uart_init()==ESP_FAIL && pin_calls==0 && driver_calls==0);
    fresh_process(); pin_result=ESP_FAIL;
    assert(score_uart_init()==ESP_FAIL && param_calls==1 && driver_calls==0);
    fresh_process(); driver_result=ESP_ERR_NO_MEM;
    assert(score_uart_init()==ESP_ERR_NO_MEM && !ready);
    uint8_t byte=0; assert(!score_uart_send(&byte,1) && write_calls==0);
    fresh_process(); assert(score_uart_init()==ESP_OK);
    assert(actual_config.baud_rate==1000000 && actual_config.data_bits==8);
    assert(actual_config.parity==UART_PARITY_DISABLE && actual_config.stop_bits==1);
    assert(actual_config.flow_ctrl==UART_HW_FLOWCTRL_DISABLE && ready);
}

static void test_event_length_is_not_buffer_length(void)
{
    fresh_process(); assert(score_uart_init()==ESP_OK);
    incoming_length=1044;
    for (size_t i=0;i<incoming_length;++i) incoming[i]=(uint8_t)i;
    push_event(UART_DATA,(size_t)0x7fffffff);
    uint8_t piece[128]; size_t total=0; bool reset;
    while (total<incoming_length) {
        size_t count=score_uart_read(piece,sizeof(piece),&reset);
        assert(!reset && count>0 && count<=128);
        assert(memcmp(piece,incoming+total,count)==0); total+=count;
    }
    assert(total==1044 && read_calls==9 && largest_read==128);
    assert(score_uart_stats()->rx_bytes==1044 && flush_calls==0);
    assert(score_uart_read(piece,sizeof(piece),&reset)==0);
}

static void test_uart_errors_flush_and_recover(void)
{
    const int faults[]={UART_FIFO_OVF,UART_BUFFER_FULL,UART_FRAME_ERR,UART_PARITY_ERR,UART_BREAK};
    for (size_t i=0;i<sizeof(faults)/sizeof(*faults);++i) {
        fresh_process(); assert(score_uart_init()==ESP_OK);
        incoming_length=37; memset(incoming,0xcc,incoming_length);
        push_event(UART_DATA,incoming_length); push_event(faults[i],0);
        uint8_t piece[128]; bool reset=false;
        assert(score_uart_read(piece,sizeof(piece),&reset)==0 && reset);
        assert(flush_calls==1 && event_queue.count==0 && incoming_length==0);
        const score_uart_stats_t *s=score_uart_stats();
        assert(s->fifo_overflow+s->buffer_full+s->frame_error+s->parity_error+s->breaks==1);
        incoming_length=32; memset(incoming,0xa5,incoming_length);
        push_event(UART_DATA,32);
        assert(score_uart_read(piece,sizeof(piece),&reset)==32 && !reset);
        assert(piece[0]==0xa5 && piece[31]==0xa5);
    }
    fresh_process(); assert(score_uart_init()==ESP_OK); read_result=-1;
    uint8_t piece[128]; bool reset=false;
    assert(score_uart_read(piece,sizeof(piece),&reset)==0 && reset);
    assert(score_uart_stats()->io_error==1);
}

static void test_send_failure_is_not_success(void)
{
    fresh_process(); assert(score_uart_init()==ESP_OK);
    uint8_t frame[SCORE_MAX_FRAME]={0};
    assert(!score_uart_send(NULL,20) && !score_uart_send(frame,0));
    assert(!score_uart_send(frame,SCORE_MAX_FRAME+1) && write_calls==0);
    write_result=19;
    assert(!score_uart_send(frame,20) && score_uart_stats()->tx_bytes==0);
    assert(score_uart_stats()->io_error==1);
    write_result=0;
    assert(!score_uart_send(frame,20) && score_uart_stats()->io_error==2);
    write_result=-1;
    assert(!score_uart_send(frame,20) && score_uart_stats()->io_error==3);
    write_result=-9999;
    assert(score_uart_send(frame,sizeof(frame)) && score_uart_stats()->tx_bytes==SCORE_MAX_FRAME);
}

int main(void)
{
    test_unassigned_and_reserved_pins();
    test_initialization_failures();
    test_event_length_is_not_buffer_length();
    test_uart_errors_flush_and_recover();
    test_send_failure_is_not_success();
    puts("PASS: production UART boundary (5 groups); no physical serial claims");
    return 0;
}
