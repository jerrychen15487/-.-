#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include "score_stub.h"

/* Exercise the production GATT/GAP/notification implementation. The stubs
 * model queue copying, mbuf ownership and deterministic host event dispatch;
 * they make no claims about real radio throughput, pairing or scheduling. */
#include "../main/score_ble.c"

struct stub_hs_config ble_hs_cfg;
static struct ble_npl_eventq host_queue;
static uint32_t clock_ms;
static int nvs_result, init_result, notify_result, address_result;
static bool deliver_sync;
static unsigned nvs_calls, controller_inits, controller_deinits, advertisements;
static unsigned terminations, allocated_mbufs, notify_attempts, delivered_count;
static uint16_t terminated_handle, stack_mtu;
static struct { uint16_t handle, length; uint8_t bytes[512]; } delivered[128];

int64_t esp_timer_get_time(void) { return (int64_t)clock_ms*1000; }
esp_err_t nvs_flash_init(void) { ++nvs_calls; return nvs_result; }
esp_err_t nimble_port_init(void) { ++controller_inits; return init_result; }
esp_err_t nimble_port_deinit(void) { ++controller_deinits; return ESP_OK; }
void nimble_port_run(void) { }
void nimble_port_freertos_init(void (*task)(void*))
{ (void)task; if (deliver_sync) ble_hs_cfg.sync_cb(); }
void nimble_port_freertos_deinit(void) { }
struct ble_npl_eventq *nimble_port_get_dflt_eventq(void) { return &host_queue; }
int ble_gap_adv_set_fields(const struct ble_hs_adv_fields *f)
{ assert(f->num_uuids128==1); return 0; }
int ble_gap_adv_rsp_set_fields(const struct ble_hs_adv_fields *f)
{ assert(f->name_len <= 29); return 0; }
int ble_gap_adv_start(uint8_t own,const void *direct,int time,
                      const struct ble_gap_adv_params *params,stub_gap_fn fn,void *arg)
{
    (void)own; (void)direct; (void)time; (void)params; (void)fn; (void)arg;
    ++advertisements; return 0;
}
int ble_gap_terminate(uint16_t handle,uint8_t reason)
{
    assert(reason==BLE_ERR_REM_USER_CONN_TERM);
    terminated_handle=handle; ++terminations; return 0;
}
int ble_hs_mbuf_to_flat(const struct os_mbuf *om,void *dst,size_t cap,uint16_t *length)
{
    if (om->length>cap) return -1;
    memcpy(dst,om->data,om->length); *length=om->length; return 0;
}
struct os_mbuf *ble_hs_mbuf_from_flat(const void *data,uint16_t length)
{
    assert(length<=512);
    struct os_mbuf *om=malloc(sizeof(*om)); assert(om);
    om->length=length; memcpy(om->data,data,length); ++allocated_mbufs; return om;
}
int ble_gatts_notify_custom(uint16_t handle,uint16_t attr,struct os_mbuf *om)
{
    assert(attr==tx_handle && om); ++notify_attempts;
    if (!notify_result) {
        assert(delivered_count<128);
        delivered[delivered_count].handle=handle;
        delivered[delivered_count].length=om->length;
        memcpy(delivered[delivered_count++].bytes,om->data,om->length);
    }
    /* IDF notify_custom consumes the mbuf on every return path. */
    free(om); --allocated_mbufs; return notify_result;
}
int ble_hs_util_ensure_addr(int random) { (void)random; return address_result; }
int ble_hs_id_infer_auto(int privacy,uint8_t *own) { (void)privacy; *own=0; return 0; }
void ble_svc_gap_init(void) { }
void ble_svc_gatt_init(void) { }
int ble_svc_gap_device_name_set(const char *name) { assert(name && *name); return 0; }
int ble_gatts_count_cfg(const struct ble_gatt_svc_def *s)
{
    assert(s[0].characteristics[0].flags==BLE_GATT_CHR_F_WRITE);
    assert(s[0].characteristics[1].flags==BLE_GATT_CHR_F_NOTIFY);
    assert(s[0].characteristics[1].access_cb!=NULL);
    return 0;
}
int ble_gatts_add_svcs(const struct ble_gatt_svc_def *s)
{ *s[0].characteristics[1].val_handle=42; return 0; }
uint16_t ble_att_mtu(uint16_t handle)
{ assert(lock == 0); return handle == 7 ? stack_mtu : 0; }
int ble_att_set_preferred_mtu(uint16_t mtu) { assert(mtu==517); return 0; }

static void fresh_process(void)
{
    assert(allocated_mbufs==0);
    memset(&ble_hs_cfg,0,sizeof(ble_hs_cfg));
    memset(&host_queue,0,sizeof(host_queue));
    memset(&link_state,0,sizeof(link_state)); link_state.max_write=20;
    memset(&counters,0,sizeof(counters));
    memset(&tx,0,sizeof(tx));
    host_started=startup_failed=startup_complete=host_synced=false; abort_epoch=0;
    connection=BLE_HS_CONN_HANDLE_NONE; ingress=NULL;
    sync_result=ESP_ERR_TIMEOUT;
    nvs_result=init_result=notify_result=address_result=0;
    deliver_sync=true;
    clock_ms=0; stack_mtu=23;
    nvs_calls=controller_inits=controller_deinits=advertisements=0;
    terminations=notify_attempts=delivered_count=0;
    terminated_handle=BLE_HS_CONN_HANDLE_NONE;
}

static void connect_client(bool subscribe)
{
    struct ble_gap_event event={.type=BLE_GAP_EVENT_CONNECT};
    event.connect.conn_handle=7;
    assert(gap_event(&event,NULL)==0);
    if (subscribe) {
        event.type=BLE_GAP_EVENT_SUBSCRIBE;
        event.subscribe.conn_handle=7; event.subscribe.attr_handle=tx_handle;
        event.subscribe.cur_notify=1;
        assert(gap_event(&event,NULL)==0);
    }
}

static void boot(bool subscribe)
{
    fresh_process(); assert(score_ble_start()==ESP_OK);
    assert(controller_inits==1 && controller_deinits==0 && advertisements==1);
    assert(ble_hs_cfg.sm_bonding==0);
    connect_client(subscribe);
}

static void run_host_event(void)
{
    struct ble_npl_event *event=host_queue.pending;
    if (event) {
        host_queue.pending=NULL; event->queued=false; event->fn(event);
    }
    assert(allocated_mbufs==0);
}

static void tick(uint32_t time)
{
    clock_ms=time; score_ble_poll(); run_host_event();
}

static int write_fragment(struct os_mbuf *om)
{
    struct ble_gatt_access_ctxt access={.op=BLE_GATT_ACCESS_OP_WRITE_CHR,.om=om};
    return access_rx(7,41,&access,NULL);
}

static void test_ingress_copy_and_backpressure(void)
{
    boot(false);
    struct os_mbuf om={.length=20}; memset(om.data,0x31,20);
    assert(write_fragment(&om)==BLE_ATT_ERR_UNLIKELY);
    struct ble_gap_event e={.type=BLE_GAP_EVENT_SUBSCRIBE};
    e.subscribe.conn_handle=7; e.subscribe.attr_handle=tx_handle; e.subscribe.cur_notify=1;
    gap_event(&e,NULL);
    assert(write_fragment(&om)==0);
    memset(om.data,0x42,20);
    assert(write_fragment(&om)==0);
    assert(write_fragment(&om)==BLE_ATT_ERR_INSUFFICIENT_RES);
    memset(om.data,0x99,20);
    score_ble_fragment_t item;
    assert(score_ble_receive(&item) && item.length==20 && item.epoch==1);
    for (unsigned i=0;i<20;++i) assert(item.bytes[i]==0x31);
    assert(score_ble_receive(&item) && item.bytes[0]==0x42);
    assert(!score_ble_receive(&item));
    score_ble_stats_t stat; score_ble_stats(&stat); assert(stat.rejected_writes==2);
}

static void test_mtu_limits(void)
{
    boot(true);
    struct os_mbuf om={.length=21};
    assert(write_fragment(&om)==BLE_ATT_ERR_INVALID_ATTR_VALUE_LEN);
    struct ble_gap_event e={.type=BLE_GAP_EVENT_MTU}; e.mtu.conn_handle=7; e.mtu.value=64; stack_mtu=64;
    gap_event(&e,NULL);
    score_ble_link_t state; score_ble_link(&state); assert(state.max_write==61);
    om.length=61; assert(write_fragment(&om)==0);
    om.length=62; assert(write_fragment(&om)==BLE_ATT_ERR_INVALID_ATTR_VALUE_LEN);
    e.mtu.value=517; stack_mtu=517; gap_event(&e,NULL); score_ble_link(&state); assert(state.max_write==512);
    om.length=512; assert(write_fragment(&om)==0);
    om.length=513; assert(write_fragment(&om)==BLE_ATT_ERR_INVALID_ATTR_VALUE_LEN);
}

static void test_negotiated_mtu_without_event(void)
{
    /* Reproduce the captured link: stack MTU 517, no MTU event delivered to
     * this callback. Subscription and actual I/O must not remain at 20. */
    boot(false);
    stack_mtu=517;
    struct ble_gap_event e={.type=BLE_GAP_EVENT_SUBSCRIBE};
    e.subscribe.conn_handle=7; e.subscribe.attr_handle=tx_handle; e.subscribe.cur_notify=1;
    gap_event(&e,NULL);
    score_ble_link_t state; score_ble_link(&state); assert(state.max_write==512);
    struct os_mbuf om={.length=512};
    for (unsigned i=0;i<512;++i) om.data[i]=(uint8_t)i;
    assert(write_fragment(&om)==0);
    om.length=40; assert(write_fragment(&om)==0);
    score_ble_fragment_t item;
    assert(score_ble_receive(&item) && item.length==512);
    for (unsigned i=0;i<512;++i) assert(item.bytes[i]==(uint8_t)i);
    assert(score_ble_receive(&item) && item.length==40);
    assert(!score_ble_receive(&item));
    uint8_t reply[141]={0};
    assert(score_ble_notify(1,reply,sizeof(reply),0)); tick(1);
    assert(delivered_count==1 && delivered[0].length==141);

    /* Late event data cannot overwrite the authoritative negotiated value. */
    e.type=BLE_GAP_EVENT_MTU; e.mtu.conn_handle=7; e.mtu.value=23;
    gap_event(&e,NULL); score_ble_link(&state); assert(state.max_write==512);
    e.mtu.conn_handle=8; stack_mtu=23;
    gap_event(&e,NULL); score_ble_link(&state); assert(state.max_write==512);
    e.mtu.conn_handle=7; stack_mtu=0;
    gap_event(&e,NULL); score_ble_link(&state); assert(state.max_write==512);
    e.type=BLE_GAP_EVENT_DISCONNECT; gap_event(&e,NULL);
    stack_mtu=23; connect_client(true); score_ble_link(&state);
    assert(state.epoch==2 && state.max_write==20);
    om.length=21; assert(write_fragment(&om)==BLE_ATT_ERR_INVALID_ATTR_VALUE_LEN);

    /* Negotiation may precede CONNECT, or complete after subscription. */
    fresh_process(); assert(score_ble_start()==ESP_OK); stack_mtu=517;
    connect_client(true); score_ble_link(&state); assert(state.max_write==512);
    boot(true); stack_mtu=517;
    om.length=512; assert(write_fragment(&om)==0);
    score_ble_link(&state); assert(state.max_write==512);
    boot(true); stack_mtu=517;
    assert(score_ble_notify(1,reply,sizeof(reply),0)); tick(1);
    assert(delivered_count==1 && delivered[0].length==141);
}

static void test_output_ownership_and_order(void)
{
    boot(true);
    uint8_t reply[45], change[7]; memset(reply,0x11,sizeof(reply)); memset(change,0x22,sizeof(change));
    assert(score_ble_notify(1,reply,sizeof(reply),0));
    memset(reply,0xff,sizeof(reply));
    assert(!score_ble_notify(1,change,sizeof(change),0));
    tick(1); tick(2); tick(3);
    assert(delivered_count==3 && delivered[0].length==20 && delivered[1].length==20 && delivered[2].length==5);
    for (unsigned n=0;n<3;++n) for (unsigned i=0;i<delivered[n].length;++i)
        assert(delivered[n].bytes[i]==0x11);
    assert(score_ble_notify(1,change,sizeof(change),3)); tick(4);
    assert(delivered_count==4 && delivered[3].length==7 && delivered[3].bytes[0]==0x22);
    unsigned old_attempts=notify_attempts; tick(5); tick(6); assert(notify_attempts==old_attempts);
}

static void test_busy_timeout_and_recovery(void)
{
    boot(true);
    uint8_t reply[21]={0};
    notify_result=BLE_HS_EBUSY;
    assert(score_ble_notify(1,reply,sizeof(reply),0));
    tick(4999); assert(terminations==0 && delivered_count==0 && tx.offset==0);
    tick(5000); assert(terminations==1 && terminated_handle==7 && tx.length==0);
    tick(6000); assert(terminations==1);
    boot(true);
    notify_result=BLE_HS_ENOMEM;
    assert(score_ble_notify(1,reply,sizeof(reply),0));
    tick(100); assert(tx.offset==0 && allocated_mbufs==0);
    notify_result=0; tick(101); tick(102);
    assert(delivered_count==2 && terminations==0 && tx.length==0);
    boot(true); notify_result=99;
    assert(score_ble_notify(1,reply,sizeof(reply),0));
    tick(1); tick(2);
    assert(terminations==1 && delivered_count==0 && tx.length==0);
}

static void test_unsubscribe_and_connection_epoch(void)
{
    boot(true);
    uint8_t old_reply[45]; memset(old_reply,0xaa,sizeof(old_reply));
    assert(score_ble_notify(1,old_reply,sizeof(old_reply),0)); tick(1);
    struct ble_gap_event e={.type=BLE_GAP_EVENT_SUBSCRIBE};
    e.subscribe.conn_handle=7; e.subscribe.attr_handle=tx_handle; e.subscribe.cur_notify=0;
    gap_event(&e,NULL); tick(2); assert(terminations==1 && delivered_count==1);
    e.type=BLE_GAP_EVENT_DISCONNECT; gap_event(&e,NULL);
    connect_client(true);
    score_ble_link_t state; score_ble_link(&state); assert(state.epoch==2);
    assert(!score_ble_notify(1,old_reply,sizeof(old_reply),2));
    uint8_t new_reply=0xbb; assert(score_ble_notify(2,&new_reply,1,2)); tick(3);
    assert(delivered_count==2 && delivered[1].length==1 && delivered[1].bytes[0]==0xbb);
}

static void test_disconnect_clears_unconsumed_input_and_output(void)
{
    boot(true);
    struct os_mbuf om={.length=20}; assert(write_fragment(&om)==0);
    uint8_t reply[40]={0}; assert(score_ble_notify(1,reply,sizeof(reply),0));
    struct ble_gap_event e={.type=BLE_GAP_EVENT_DISCONNECT}; gap_event(&e,NULL);
    score_ble_fragment_t fragment; assert(!score_ble_receive(&fragment));
    tick(1); assert(delivered_count==0 && tx.length==0);
    assert(advertisements==2 && controller_inits==1 && controller_deinits==0);
    connect_client(true); assert(write_fragment(&om)==0);
    assert(score_ble_receive(&fragment) && fragment.epoch==2);
    score_ble_disconnect(1); tick(2); assert(terminations==0);
    score_ble_disconnect(2); tick(3); assert(terminations==1);
}

static void test_startup_failure_and_runtime_reset(void)
{
    fresh_process(); nvs_result=ESP_FAIL;
    assert(score_ble_start()==ESP_FAIL && nvs_calls==1 && controller_inits==0);
    assert(!host_started && advertisements==0);
    fresh_process(); init_result=ESP_FAIL;
    assert(score_ble_start()==ESP_FAIL && controller_inits==1 && !host_started);
    fresh_process(); address_result=1;
    assert(score_ble_start()==ESP_FAIL && advertisements==0);
    address_result=0; ble_hs_cfg.reset_cb(1); ble_hs_cfg.sync_cb();
    assert(advertisements==0 && nvs_calls==1 && controller_inits==1);
    fresh_process(); deliver_sync=false;
    assert(score_ble_start()==ESP_ERR_TIMEOUT && advertisements==0);
    ble_hs_cfg.sync_cb(); assert(advertisements==0 && controller_inits==1);
    boot(true);
    struct os_mbuf om={.length=20}; assert(write_fragment(&om)==0);
    uint8_t reply[40]={0}; assert(score_ble_notify(1,reply,sizeof(reply),0));
    ble_hs_cfg.reset_cb(99);
    score_ble_link_t state; score_ble_link(&state);
    assert(!state.connected && !state.subscribed && state.max_write==20 && !host_synced);
    score_ble_fragment_t fragment; assert(!score_ble_receive(&fragment) && tx.length==0);
    tick(1); assert(delivered_count==0);
    struct ble_gap_event event={.type=BLE_GAP_EVENT_ADV_COMPLETE};
    gap_event(&event,NULL); assert(advertisements==1); /* no advertise before sync */
    address_result=1; ble_hs_cfg.sync_cb();
    assert(!host_synced && !startup_failed && advertisements==1);
    address_result=0;
    ble_hs_cfg.sync_cb();
    assert(host_synced && nvs_calls==1 && controller_inits==1 && controller_deinits==0 && advertisements==2);
    connect_client(true); score_ble_link(&state); assert(state.epoch==2);
    assert(!score_ble_notify(1,reply,sizeof(reply),1));
    assert(score_ble_notify(2,reply,sizeof(reply),1)); tick(2); tick(3);
    assert(delivered_count==2 && delivered[0].handle==7);
}

int main(void)
{
    test_ingress_copy_and_backpressure();
    test_mtu_limits();
    test_negotiated_mtu_without_event();
    test_output_ownership_and_order();
    test_busy_timeout_and_recovery();
    test_unsubscribe_and_connection_epoch();
    test_disconnect_clears_unconsumed_input_and_output();
    test_startup_failure_and_runtime_reset();
    printf("PASS: production BLE lifecycle (8 groups); BLE buffers=%u bytes; no radio claims\n",
           (unsigned)score_ble_buffer_bytes());
    return 0;
}

#if CONFIG_SCORE_DIAGNOSTICS
uint64_t score_diag_clock(void) { return (uint64_t)esp_timer_get_time(); }
void score_diag_lock(void) { }
void score_diag_unlock(void) { }
int ble_gap_conn_find(uint16_t handle, struct ble_gap_conn_desc *desc)
{ (void)handle; *desc=(struct ble_gap_conn_desc){24,0,200}; return 0; }
#endif
