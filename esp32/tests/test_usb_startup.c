/* Exercise production startup/callback/cleanup functions against a mock Host API.
 * This verifies lifecycle/order, not USB electrical compatibility or RTOS scheduling. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "../main/usb_midi_host.c"

static int allocs, frees, bulk, closes, errors, received;
static bool reject_bulk, bulk_pending;
static int fail_alloc;
static usb_transfer_t *pending_bulk;
int64_t test_now_us;
esp_err_t usb_host_client_handle_events(usb_host_client_handle_t client, TickType_t wait)
{ (void)client; (void)wait; return ESP_OK; }
void test_log(const char *tag, const char *format, ...) { (void)tag; (void)format; }
void bridge_usb_error(void) { ++errors; }
void bridge_start_session(void) {}
void bridge_end_session(void) {}
void bridge_receive(const uint8_t *p, size_t n, int64_t time)
{ (void)p; (void)time; assert(n == 4); ++received; }
bool midi_find_endpoint(const uint8_t *p, size_t n, midi_endpoint_t *out)
{ (void)p; (void)n; *out = (midi_endpoint_t){1, 0, 0x81, 64}; return true; }
esp_err_t usb_host_transfer_alloc(size_t size, int isoc, usb_transfer_t **out)
{
    assert(isoc == 0);
    if (++allocs == fail_alloc) return ESP_FAIL;
    *out = calloc(1, sizeof(**out)); assert(*out);
    (*out)->data_buffer = calloc(1, size); assert((*out)->data_buffer);
    (*out)->data_buffer_size = size;
    return ESP_OK;
}
esp_err_t usb_host_transfer_free(usb_transfer_t *t)
{
    assert(!(t == pending_bulk && bulk_pending));
    free(t->data_buffer); free(t); ++frees; return ESP_OK;
}
esp_err_t usb_host_transfer_submit(usb_transfer_t *t)
{
    assert(!bulk_pending);
    assert(t->num_bytes == 64 && t->bEndpointAddress == 0x81);
    ++bulk;
    if (reject_bulk) return ESP_FAIL;
    pending_bulk = t; bulk_pending = true; return ESP_OK;
}
esp_err_t usb_host_device_open(usb_host_client_handle_t c, uint8_t a, usb_device_handle_t *out)
{ (void)c; assert(a > 0); *out = (void *)(uintptr_t)1; return ESP_OK; }
esp_err_t usb_host_get_active_config_descriptor(usb_device_handle_t d, const usb_config_desc_t **out)
{ (void)d; static const usb_config_desc_t config = {9}; *out = &config; return ESP_OK; }
esp_err_t usb_host_interface_claim(usb_host_client_handle_t c, usb_device_handle_t d, uint8_t i, uint8_t a)
{ (void)c; (void)d; assert(i == 1 && a == 0); return ESP_OK; }
esp_err_t usb_host_interface_release(usb_host_client_handle_t c, usb_device_handle_t d, uint8_t i)
{ (void)c; (void)d; assert(i == 1); return ESP_OK; }
esp_err_t usb_host_device_close(usb_host_client_handle_t c, usb_device_handle_t d)
{ (void)c; (void)d; assert(!bulk_pending); ++closes; return ESP_OK; }
esp_err_t usb_host_endpoint_halt(usb_device_handle_t d, uint8_t ep)
{ (void)d; assert(ep == 0x81); return ESP_OK; }
esp_err_t usb_host_endpoint_flush(usb_device_handle_t d, uint8_t ep)
{ (void)d; assert(ep == 0x81); return ESP_OK; }
static void reset(void)
{
    allocs = frees = bulk = closes = errors = received = 0;
    reject_bulk = bulk_pending = false;
    fail_alloc = 0; pending_bulk = NULL; test_now_us = 1000000;
}
static void complete(midi_host_t *h, int status)
{
    assert(bulk_pending);
    bulk_pending = false;
    h->transfer->status = status;
    h->transfer->actual_num_bytes = 4;
    h->transfer->callback(h->transfer);
}
static void disconnect(midi_host_t *h)
{
    usb_host_client_event_msg_t event = {.event = USB_HOST_CLIENT_EVENT_DEV_GONE,
                                       .dev_gone = {.dev_hdl = h->device}};
    client_event(&event, h);
}
int main(void)
{
    reset(); midi_host_t h = {0};
    open_device(&h, 1);
    assert(allocs == 1 && bulk == 1 && h.in_flight && !h.resubmit);
    complete(&h, USB_TRANSFER_STATUS_COMPLETED);
    assert(received == 1 && h.resubmit && !h.in_flight && bulk == 1);
    submit_receive(&h);
    assert(bulk == 2 && h.in_flight);
    disconnect(&h); stop_device(&h);
    assert(closes == 0 && frees == 0 && !h.resubmit);
    complete(&h, USB_TRANSFER_STATUS_COMPLETED); /* A late completion cannot enqueue. */
    assert(received == 1 && !h.resubmit);
    stop_device(&h); assert(frees == 1 && closes == 1 && !h.device);
    open_device(&h, 2); assert(bulk == 3 && h.in_flight);
    disconnect(&h); stop_device(&h); assert(closes == 1);
    complete(&h, USB_TRANSFER_STATUS_NO_DEVICE);
    stop_device(&h); assert(frees == 2 && closes == 2 && errors == 0);
    puts("PASS immediate one-MPS IN, callback-to-task resubmit, disconnect drain, late completion, reconnect");

    reset(); h = (midi_host_t){0}; open_device(&h, 1);
    complete(&h, USB_TRANSFER_STATUS_STALL);
    assert(h.stopping && !h.resubmit && errors == 1);
    stop_device(&h); assert(frees == 1 && closes == 1);
    reset(); h = (midi_host_t){0}; reject_bulk = true; open_device(&h, 1);
    assert(h.stopping && !h.in_flight && errors == 1);
    stop_device(&h); assert(frees == 1 && closes == 1);
    reset(); h = (midi_host_t){0}; fail_alloc = 1; open_device(&h, 1);
    assert(h.stopping && bulk == 0 && errors == 1);
    stop_device(&h); assert(frees == 0 && closes == 1);
    puts("PASS IN STALL, submission failure, allocation failure: no leaked transfer");
    return 0;
}
