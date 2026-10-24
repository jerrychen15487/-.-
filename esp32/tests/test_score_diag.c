#include <assert.h>
#include <stdio.h>
#include "score_diag.h"

#if CONFIG_SCORE_DIAGNOSTICS
static uint64_t clock_us;
uint64_t score_diag_clock(void) { return clock_us; }
void score_diag_lock(void) { }
void score_diag_unlock(void) { }
static uint8_t payload[532] = {1}, wire[64];
static score_frame_t request = {.type=SCORE_DATA,.session=10,.seq=1,.payload=payload,.payload_len=532};
static uint8_t ack_payload[32] = {SCORE_DATA};
static score_frame_t ack = {.type=SCORE_ACK,.session=10,.seq=1,.payload=ack_payload,.payload_len=32};

static void begin(void)
{
    clock_us=100;
    score_diag_ingress(1,90,20);
    clock_us=200;
    score_diag_ingress(1,180,532);
    clock_us=220;
    score_diag_request(1,&request);
    clock_us=230; score_diag_uart_begin();
    clock_us=250; score_diag_uart_end();
}
static void finish(void)
{
    clock_us=300; score_diag_reply(1,&ack,20);
    score_encode(wire,sizeof(wire),SCORE_ACK,10,ack.seq,ack_payload,32);
    score_diag_notify_begin(1,wire,52);
    clock_us=320; score_diag_notify_part(false,false);
    clock_us=330; score_diag_notify_part(true,false);
    clock_us=340; score_diag_notify_part(true,true);
}
int main(void)
{
    score_diag_reset(1);
    score_diag_link(1,true,true,23,20,24,0,200);
    begin();
    /* A stale identity must not enable the outgoing record. */
    score_frame_t stale=ack; stale.seq=99;
    score_diag_reply(1,&stale,20);
    finish();
    score_diag_record_t r;
    assert(score_diag_take(&r));
    assert(r.session==10 && r.seq==1 && r.attempt==1 && r.rx_count==2);
    assert(r.us[SD_RX]==90 && r.us[SD_QUEUE]==15 && r.us[SD_QUEUE_MAX]==20);
    assert(r.us[SD_PARSE]==40 && r.us[SD_UART_CALL]==20 && r.us[SD_UART_RTT]==70);
    assert(r.us[SD_READY_WAIT]==30 && r.us[SD_NOTIFY]==10 && r.busy==1);
    assert(!score_diag_take(&r));
    begin(); begin(); finish();
    assert(score_diag_take(&r) && r.attempt==3);
    /* CHANGED is never credited as a DATA reply. */
    score_encode(wire,sizeof(wire),SCORE_CHANGED,0,0,NULL,0);
    score_diag_notify_begin(1,wire,20); score_diag_notify_part(true,true);
    score_diag_summary_t s; score_diag_link_t link;
    score_diag_snapshot(&s,&link);
    assert(s.completed==2 && s.abandoned==1 && s.changed==1);
    assert(link.mtu==23 && link.interval==24);
    /* New connection: old queued fragments/late response cannot join it. */
    score_diag_reset(2);
    score_diag_ingress(1,100,20); score_diag_reply(1,&ack,20);
    score_diag_notify_part(true,true);
    score_diag_snapshot(&s,&link); assert(s.completed==0);
    /* The fixed record queue is lossy; completion never blocks on logging. */
    score_diag_reset(1);
    begin(); finish(); begin(); finish(); begin(); finish();
    score_diag_snapshot(&s,&link);
    assert(s.completed==3 && s.dropped==0);
    /* Preserve queued records across reset; next connection cannot wait on them. */
    score_diag_reset(1); begin(); finish();
    score_diag_snapshot(&s,&link); assert(s.dropped==1);
    /* Fast reply may be observed before a write-call return; do not reorder. */
    score_diag_reset(1); begin();
    clock_us=251; score_diag_reply(1,&ack,20);
    clock_us=252; score_diag_uart_end();
    score_diag_notify_begin(1,wire,1); score_diag_notify_part(true,true);
    score_diag_snapshot(&s,&link); assert(s.completed==0);
    score_diag_uart_io(552,52,7);
    score_diag_snapshot(&s,&link);
    assert(s.uart_tx==552 && s.uart_rx==52 && s.uart_calls==1 && s.uart_sum==7);
    assert(score_diag_bytes()<=SCORE_DIAG_DATA_BUDGET);
    printf("score diagnostics: deterministic timing/identity/overflow passed (%u bytes)\n",(unsigned)score_diag_bytes());
    return 0;
}
#else
int main(void)
{
    int evaluated=0;
    SCORE_DIAG(++evaluated);
    SCORE_DIAG(nonexistent_symbol());
    assert(evaluated==0 && SCORE_DIAG_DATA_BUDGET==0);
    puts("score diagnostics disabled: hooks do not evaluate arguments");
    return 0;
}
#endif
