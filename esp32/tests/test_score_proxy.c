#include "score_proxy.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>

static score_proxy_t proxy;
static uint8_t uart_wire[SCORE_MAX_FRAME], ble_wire[SCORE_MAX_FRAME];
static size_t uart_len, ble_len;
static unsigned sends, notifies, disconnects;
static bool tx_busy, uart_ok;

static bool send_uart(const uint8_t *wire, size_t n, void *context)
{
    (void)context;
    memcpy(uart_wire, wire, n); uart_len = n; ++sends;
    return uart_ok;
}
static bool notify(const uint8_t *wire, size_t n, void *context)
{
    (void)context;
    if (tx_busy) return false;
    memcpy(ble_wire, wire, n); ble_len = n; ++notifies;
    return true;
}
static void disconnect(void *context) { (void)context; ++disconnects; }
static void setup(void)
{
    score_proxy_io_t io = {.uart_send=send_uart, .notify=notify, .disconnect=disconnect};
    score_proxy_init(&proxy, &io);
    sends = notifies = disconnects = 0; tx_busy = false; uart_ok = true;
    uart_len = ble_len = 0;
    score_proxy_connect(&proxy, 11, 20, true);
}
static void request(uint8_t type, uint32_t session, uint32_t seq, const uint8_t *data, size_t len, uint32_t now)
{
    uint8_t wire[SCORE_MAX_FRAME];
    size_t n = score_encode(wire, sizeof(wire), type, session, seq, data, len);
    assert(n);
    for (size_t i = 0; i < n; i += 20)
        score_proxy_ble_feed(&proxy, 11, wire + i, n - i < 20 ? n - i : 20, now);
}
static void response(uint8_t type, uint32_t session, uint32_t seq, const uint8_t *data, size_t len, uint32_t now)
{
    uint8_t wire[SCORE_MAX_FRAME];
    size_t n = score_encode(wire, sizeof(wire), type, session, seq, data, len);
    assert(n);
    score_proxy_uart_feed(&proxy, wire, n, now);
}
static void error(uint8_t request_type, uint32_t session, uint32_t seq, uint32_t now)
{
    uint8_t payload[8] = {request_type, 0, SCORE_BUSY, 0, 0xff, 0xff, 0xff, 0xff};
    response(SCORE_ERROR, session, seq, payload, sizeof(payload), now);
}
static void handshake(void)
{
    request(SCORE_CAPS, 1, 1, NULL, 0, 0);
    uint8_t payload[42] = {SCORE_CAPS,0,0,0};
    score_put_u16(payload+4, 2); score_put_u16(payload+6, 2);
    score_put_u16(payload+8, 1024); score_put_u16(payload+10, 512);
    score_put_u32(payload+12, 1048576); score_put_u32(payload+16, 10000);
    score_put_u32(payload+20, 16); score_put_u32(payload+24, 4);
    score_put_u32(payload+28, 32); score_put_u32(payload+32, 64);
    score_put_u16(payload+36, 1); score_put_u16(payload+38, 1); score_put_u16(payload+40, 1);
    response(SCORE_ACK,1,1,payload,sizeof(payload),1);
    assert(proxy.connected && !proxy.waiting && notifies == 1);
}

static void caps_uses_updated_link_limit(void)
{
    const uint16_t limits[] = {20, 61, 512};
    for (unsigned i = 0; i < sizeof(limits) / sizeof(limits[0]); ++i) {
        setup();
        score_proxy_link(&proxy, limits[i], true);
        handshake();
        score_frame_t frame;
        assert(score_decode(ble_wire, ble_len, &frame) && frame.type == SCORE_ACK);
        char json[SCORE_MAX_FRAME], expected[32];
        assert(frame.payload_len < sizeof(json));
        memcpy(json, frame.payload, frame.payload_len); json[frame.payload_len] = 0;
        snprintf(expected, sizeof(expected), "\"max_write\":%u", limits[i]);
        assert(strstr(json, expected));
    }
    puts("PASS CAPS advertises current link limit at MTU 23/64/517");
}

static void forwarding_and_timeouts(void)
{
    setup(); handshake();
    uint8_t data[23] = {1}; data[16] = 0; data[20] = 0xa5; data[21] = 0x5a; data[22] = 0x91;
    request(SCORE_DATA,1,2,data,sizeof(data),100);
    score_frame_t f;
    assert(score_decode(uart_wire,uart_len,&f));
    assert(f.type==SCORE_DATA && f.session==1 && f.seq==2 && f.payload_len==23);
    assert(!memcmp(f.payload,data,23) && sends==2 && notifies==1);
    score_proxy_poll(&proxy,5099); assert(proxy.waiting);
    score_proxy_poll(&proxy,5100);
    assert(!proxy.waiting && proxy.stats.timeouts==1 && sends==2 && notifies==1);
    request(SCORE_DATA,1,2,data,sizeof(data),5101);
    assert(sends==3 && proxy.stats.retries==1 && notifies==1);
    error(SCORE_DATA,1,1,5102); assert(notifies==1); /* old sequence */
    error(SCORE_DATA,1,2,5103); assert(notifies==2 && !proxy.waiting);
    assert(score_decode(ble_wire,ble_len,&f) && f.type==SCORE_ERROR);
    /* Same seq with changed bytes is never sent downstream. */
    data[22] ^= 1;
    request(SCORE_DATA,1,2,data,sizeof(data),5104);
    assert(disconnects==1 && sends==3);
    puts("PASS proxy durable-ACK boundary, data identity, website-only retries, timeout, stale and conflicting requests");
}

static void changed_and_backpressure(void)
{
    setup(); handshake();
    request(SCORE_STATUS,1,2,NULL,0,100);
    uint8_t changed[8] = {2,0,0,0,1,0,0,0};
    tx_busy=true;
    response(SCORE_CHANGED,0,0,changed,8,101);
    assert(notifies==1 && proxy.changed_pending && proxy.waiting);
    changed[0]=3;
    response(SCORE_CHANGED,0,0,changed,8,102);
    error(SCORE_STATUS,1,2,103);
    assert(proxy.reply_len && proxy.changed_pending && notifies==1);
    tx_busy=false;
    score_proxy_poll(&proxy,104);
    assert(notifies==3 && !proxy.reply_len && !proxy.changed_pending);
    score_frame_t f;
    assert(score_decode(ble_wire,ble_len,&f) && f.type==SCORE_CHANGED && !f.seq && !f.session);
    assert(proxy.stats.changed==2 && proxy.connected);
    /* Invalid unsolicited data cannot terminate the current request. */
    request(SCORE_STATUS,1,3,NULL,0,110);
    changed[6]=1;
    response(SCORE_CHANGED,0,0,changed,8,111);
    assert(proxy.connected && proxy.waiting && notifies==3);
    puts("PASS response priority, bounded CHANGED coalescing and notification backpressure");
}

static void connection_ownership(void)
{
    setup(); handshake();
    request(SCORE_STATUS,1,2,NULL,0,100);
    score_proxy_disconnect(&proxy,10); assert(proxy.connected); /* wrong epoch */
    score_proxy_disconnect(&proxy,11); assert(!proxy.connected && sends==2);
    score_proxy_connect(&proxy,12,128,true);
    uint8_t wire[20]; size_t n=score_encode(wire,sizeof(wire),SCORE_CAPS,2,1,NULL,0);
    score_proxy_ble_feed(&proxy,11,wire,n,101); assert(sends==2);
    score_proxy_ble_feed(&proxy,12,wire,n,102); assert(sends==3);
    error(SCORE_STATUS,1,2,103); assert(notifies==1 && proxy.waiting);
    error(SCORE_CAPS,2,1,104); assert(notifies==2);
    score_proxy_link(&proxy,512,false);
    score_proxy_ble_feed(&proxy,12,wire,n,105);
    assert(disconnects==1 && !proxy.connected);
    /* First request must establish session through CAPS. */
    setup(); request(SCORE_STATUS,1,1,NULL,0,0);
    assert(disconnects==1 && !sends);
    puts("PASS connection epochs, stale callbacks/responses, subscriptions and session establishment");
}

static void broken_links(void)
{
    setup();
    uint8_t wire[20]; size_t n=score_encode(wire,sizeof(wire),SCORE_CAPS,1,1,NULL,0);
    assert(n == 20);
    score_proxy_ble_feed(&proxy,11,wire,9,UINT32_MAX-99);
    score_proxy_poll(&proxy,4899); assert(proxy.connected);
    score_proxy_poll(&proxy,4900); assert(!proxy.connected && disconnects==1);
    setup(); uart_ok=false; request(SCORE_CAPS,1,1,NULL,0,0);
    assert(disconnects==1 && notifies==0);
    setup(); handshake(); request(SCORE_STATUS,1,2,NULL,0,100);
    n=score_encode(wire,sizeof(wire),SCORE_CAPS,1,1,NULL,0);
    assert(n == 20);
    score_proxy_uart_feed(&proxy,wire,10,101);
    score_proxy_uart_reset(&proxy);
    assert(proxy.waiting && proxy.uart_stream.used==0 && notifies==1);
    error(SCORE_STATUS,1,2,5101); /* Late but still matching, before a newer request */
    assert(notifies==2);
    puts("PASS BLE half-frame wrap/timeout, UART failure/reset and late response handling");
}

static void commit_deadline(void)
{
    static const char json[] = "{\"id\":\"12345678-1234-5678-9abc-def012345678\",\"total_bytes\":64,\"file_crc\":1}";
    setup(); handshake();
    request(SCORE_COMMIT,1,2,(const uint8_t *)json,strlen(json),100);
    score_proxy_poll(&proxy,30100-1);
    assert(proxy.waiting && sends==2 && notifies==1);
    score_proxy_poll(&proxy,30100);
    assert(!proxy.waiting && proxy.stats.timeouts==1 && sends==2 && notifies==1);
    /* Query supersedes the unknown result; a late old COMMIT cannot satisfy it. */
    request(SCORE_STATUS,1,3,NULL,0,30101);
    error(SCORE_COMMIT,1,2,30102);
    assert(proxy.waiting && notifies==1 && proxy.stats.stale==1);
    error(SCORE_STATUS,1,3,30103);
    assert(!proxy.waiting && notifies==2 && sends==3);
    puts("PASS COMMIT 30s deadline, no automatic replay and unknown-result query isolation");
}

static void exact_retry_identity(void)
{
    static const char canonical[] = "{\"generation\":0,\"cursor\":0,\"limit\":1}";
    static const char reordered[] = "{\"limit\":1,\"cursor\":0,\"generation\":0}";
    static const char spaced[] = "{ \"generation\":0,\"cursor\":0,\"limit\":1}";
    const char *different[] = {reordered, spaced};
    for (size_t i = 0; i < sizeof(different) / sizeof(different[0]); ++i) {
        setup(); handshake();
        request(SCORE_LIST,1,2,(const uint8_t *)canonical,strlen(canonical),100);
        request(SCORE_LIST,1,2,(const uint8_t *)canonical,strlen(canonical),101);
        assert(sends == 3 && proxy.stats.retries == 1 && !disconnects);
        error(SCORE_LIST,1,2,102);
        request(SCORE_LIST,1,2,(const uint8_t *)different[i],strlen(different[i]),103);
        assert(disconnects == 1 && sends == 3);
    }
    setup(); handshake();
    request(SCORE_STATUS,1,2,NULL,0,100);
    error(SCORE_STATUS,1,2,101);
    request(SCORE_CAPS,1,2,NULL,0,102);
    assert(disconnects == 1 && sends == 2); /* Same empty payload, different type. */
    setup(); handshake();
    uint8_t nil_data[21] = {0};
    request(SCORE_DATA,1,2,nil_data,sizeof(nil_data),100);
    assert(disconnects == 1 && sends == 1 && notifies == 1);
    puts("PASS exact retry bytes/type/length and nil song rejection before UART");
}

int main(void)
{
    caps_uses_updated_link_limit();
    forwarding_and_timeouts(); changed_and_backpressure(); connection_ownership(); broken_links(); commit_deadline(); exact_retry_identity();
    assert(sizeof(score_proxy_t) < 6144);
    printf("proxy static context: %u bytes; hardware/storage/timing not asserted\n", (unsigned)sizeof(score_proxy_t));
    return 0;
}
