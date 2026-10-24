#include "bridge.h"
#include "midi_descriptors.h"
#include <stdbool.h>
#include "esp_log.h"
#include "esp_timer.h"
#include "esp_intr_alloc.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "usb/usb_host.h"

typedef struct {
    usb_host_client_handle_t client;
    usb_device_handle_t device;
    usb_transfer_t *transfer;
    midi_endpoint_t endpoint;
    uint8_t pending_address;
    bool claimed, in_flight, stopping, stop_started, resubmit;
} midi_host_t;
static const char *TAG = "midi_usb";

static void transfer_done(usb_transfer_t *transfer)
{
    const int64_t received_us = esp_timer_get_time();
    midi_host_t *host = transfer->context;
    host->in_flight = false;
    if (host->stopping) return;
    if (transfer->status == USB_TRANSFER_STATUS_COMPLETED) {
        bridge_receive(transfer->data_buffer, transfer->actual_num_bytes, received_us);
        host->resubmit = true;
    } else {
        ESP_LOGW(TAG, "IN completion status=%d actual=%d", transfer->status, transfer->actual_num_bytes);
        bridge_usb_error();
        host->stopping = true;
    }
}

static void client_event(const usb_host_client_event_msg_t *event, void *arg)
{
    midi_host_t *host = arg;
    if (event->event == USB_HOST_CLIENT_EVENT_NEW_DEV && !host->pending_address) {
        host->pending_address = event->new_dev.address;
    } else if (event->event == USB_HOST_CLIENT_EVENT_DEV_GONE &&
               event->dev_gone.dev_hdl == host->device) {
        host->stopping = true;
    }
}

static void submit_receive(midi_host_t *host)
{
    host->resubmit = false;
    /* Exactly one MPS: don't wait for a second full USB packet to complete a read. */
    host->transfer->num_bytes = host->endpoint.max_packet_size;
    esp_err_t err = usb_host_transfer_submit(host->transfer);
    if (err == ESP_OK) host->in_flight = true;
    else {
        bridge_usb_error();
        host->stopping = true;
        ESP_LOGW(TAG, "IN submission failed: %s", esp_err_to_name(err));
    }
}

static void open_device(midi_host_t *host, uint8_t address)
{
    esp_err_t err = usb_host_device_open(host->client, address, &host->device);
    if (err != ESP_OK) {
        ESP_LOGW(TAG, "Open address %u: %s", address, esp_err_to_name(err));
        return;
    }
    const usb_config_desc_t *configuration = NULL;
    err = usb_host_get_active_config_descriptor(host->device, &configuration);
    if (err != ESP_OK || !midi_find_endpoint((const uint8_t *)configuration,
                                             configuration ? configuration->wTotalLength : 0,
                                             &host->endpoint)) {
        ESP_LOGW(TAG, "No supported MIDI 1.0 bulk IN interface (address %u)", address);
        host->stopping = true;
        return;
    }
    err = usb_host_interface_claim(host->client, host->device,
                                   host->endpoint.interface_number, host->endpoint.alternate_setting);
    if (err != ESP_OK) goto failed;
    host->claimed = true;
    err = usb_host_transfer_alloc(host->endpoint.max_packet_size, 0, &host->transfer);
    if (err != ESP_OK) goto failed;
    host->transfer->device_handle = host->device;
    host->transfer->bEndpointAddress = host->endpoint.endpoint;
    host->transfer->callback = transfer_done;
    host->transfer->context = host;
    bridge_start_session();
    ESP_LOGI(TAG, "address=%u interface=%u alt=%u IN=0x%02x MPS=%u",
             address, host->endpoint.interface_number, host->endpoint.alternate_setting,
             host->endpoint.endpoint, host->endpoint.max_packet_size);
    submit_receive(host);
    return;
failed:
    bridge_usb_error();
    ESP_LOGW(TAG, "MIDI setup failed: %s", esp_err_to_name(err));
    host->stopping = true;
}

static void stop_device(midi_host_t *host)
{
    if (!host->stop_started) {
        host->stop_started = true;
        host->resubmit = false;
        bridge_end_session();
        if (host->claimed) {
            /* Task context, outside callbacks. Flush returns outstanding transfers
             * via client callbacks; don't free their buffers before that happens. */
            ESP_ERROR_CHECK(usb_host_endpoint_halt(host->device, host->endpoint.endpoint));
            ESP_ERROR_CHECK(usb_host_endpoint_flush(host->device, host->endpoint.endpoint));
        }
    }
    if (host->in_flight) return;
    if (host->claimed) ESP_ERROR_CHECK(usb_host_interface_release(host->client, host->device,
                                                                host->endpoint.interface_number));
    ESP_ERROR_CHECK(usb_host_device_close(host->client, host->device));
    if (host->transfer) ESP_ERROR_CHECK(usb_host_transfer_free(host->transfer));
    host->device = NULL;
    host->transfer = NULL;
    host->claimed = host->stopping = host->stop_started = false;
    ESP_LOGI(TAG, "Device released; waiting for a new connection");
}

static void client_task(void *arg)
{
    midi_host_t host = {0};
    const usb_host_client_config_t config = {
        .is_synchronous = false, .max_num_event_msg = 5,
        .async = {.client_event_callback = client_event, .callback_arg = &host},
    };
    ESP_ERROR_CHECK(usb_host_client_register(&config, &host.client));
    /* Also handle a piano that finished enumeration before client registration. */
    uint8_t addresses[1];
    int count = 0;
    ESP_ERROR_CHECK(usb_host_device_addr_list_fill(1, addresses, &count));
    if (count) host.pending_address = addresses[0];
    for (;;) {
        if (host.stopping) stop_device(&host);
        if (host.pending_address && !host.stopping) {
            uint8_t address = host.pending_address;
            host.pending_address = 0;
            if (!host.device) open_device(&host, address);
        }
        if (host.stopping && !host.stop_started) continue;
        if (host.resubmit && !host.stopping) submit_receive(&host);
        if (host.stopping && !host.stop_started) continue;
        ESP_ERROR_CHECK(usb_host_client_handle_events(host.client, portMAX_DELAY));
    }
}

static void host_task(void *arg)
{
    const usb_host_config_t config = {.intr_flags = ESP_INTR_FLAG_LEVEL1, .peripheral_map = 1};
    ESP_ERROR_CHECK(usb_host_install(&config));
    xTaskNotifyGive((TaskHandle_t)arg);
    for (;;) {
        uint32_t flags;
        ESP_ERROR_CHECK(usb_host_lib_handle_events(portMAX_DELAY, &flags));
        /* The client is permanent. device_free_all is only for full shutdown
         * after deregistering clients, not for normal unplug/replug cycles. */
    }
}

void usb_midi_start(void)
{
    BaseType_t ok = xTaskCreatePinnedToCore(host_task, "usb_daemon", 4096,
                                           xTaskGetCurrentTaskHandle(), BRIDGE_USB_PRIORITY,
                                           NULL, BRIDGE_CORE);
    configASSERT(ok == pdPASS);
    ulTaskNotifyTake(pdTRUE, portMAX_DELAY);
    ok = xTaskCreatePinnedToCore(client_task, "usb_midi", 5120, NULL,
                                 BRIDGE_CLIENT_PRIORITY, NULL, BRIDGE_CORE);
    configASSERT(ok == pdPASS);
}
