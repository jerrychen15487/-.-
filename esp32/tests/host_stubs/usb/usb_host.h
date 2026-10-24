#pragma once
#include "test_platform.h"
typedef void *usb_host_client_handle_t;
typedef void *usb_device_handle_t;
typedef struct { uint16_t wTotalLength; } usb_config_desc_t;
enum { USB_TRANSFER_STATUS_COMPLETED, USB_TRANSFER_STATUS_ERROR,
       USB_TRANSFER_STATUS_TIMED_OUT, USB_TRANSFER_STATUS_CANCELED,
       USB_TRANSFER_STATUS_STALL, USB_TRANSFER_STATUS_OVERFLOW,
       USB_TRANSFER_STATUS_SKIPPED, USB_TRANSFER_STATUS_NO_DEVICE };
typedef struct usb_transfer usb_transfer_t;
struct usb_transfer {
    uint8_t *data_buffer;
    size_t data_buffer_size;
    int num_bytes, actual_num_bytes, status;
    usb_device_handle_t device_handle;
    uint8_t bEndpointAddress;
    void (*callback)(usb_transfer_t *);
    void *context;
};
enum { USB_HOST_CLIENT_EVENT_NEW_DEV, USB_HOST_CLIENT_EVENT_DEV_GONE };
typedef struct {
    int event;
    struct { uint8_t address; } new_dev;
    struct { usb_device_handle_t dev_hdl; } dev_gone;
} usb_host_client_event_msg_t;
typedef struct {
    bool is_synchronous;
    int max_num_event_msg;
    struct { void (*client_event_callback)(const usb_host_client_event_msg_t *, void *); void *callback_arg; } async;
} usb_host_client_config_t;
typedef struct { int intr_flags, peripheral_map; } usb_host_config_t;
esp_err_t usb_host_transfer_alloc(size_t size, int isoc, usb_transfer_t **out);
esp_err_t usb_host_transfer_free(usb_transfer_t *t);
esp_err_t usb_host_transfer_submit(usb_transfer_t *t);
esp_err_t usb_host_device_open(usb_host_client_handle_t client, uint8_t address, usb_device_handle_t *out);
esp_err_t usb_host_get_active_config_descriptor(usb_device_handle_t d, const usb_config_desc_t **out);
esp_err_t usb_host_interface_claim(usb_host_client_handle_t c, usb_device_handle_t d, uint8_t i, uint8_t a);
esp_err_t usb_host_interface_release(usb_host_client_handle_t c, usb_device_handle_t d, uint8_t i);
esp_err_t usb_host_device_close(usb_host_client_handle_t c, usb_device_handle_t d);
esp_err_t usb_host_endpoint_halt(usb_device_handle_t d, uint8_t ep);
esp_err_t usb_host_endpoint_flush(usb_device_handle_t d, uint8_t ep);
static inline esp_err_t usb_host_client_register(const usb_host_client_config_t *c, usb_host_client_handle_t *h)
{ (void)c; *h = NULL; return ESP_OK; }
static inline esp_err_t usb_host_device_addr_list_fill(int n, uint8_t *a, int *count)
{ (void)n; (void)a; *count = 0; return ESP_OK; }
esp_err_t usb_host_client_handle_events(usb_host_client_handle_t h, TickType_t t);
static inline esp_err_t usb_host_install(const usb_host_config_t *c) { (void)c; return ESP_OK; }
static inline esp_err_t usb_host_lib_handle_events(TickType_t t, uint32_t *f)
{ (void)t; *f = 0; return ESP_OK; }
