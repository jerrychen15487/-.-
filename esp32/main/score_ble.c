#include "score_ble.h"

#include <string.h>
#include "esp_log.h"
#include "esp_task.h"
#include "esp_timer.h"
#include "freertos/FreeRTOS.h"
#include "freertos/queue.h"
#include "freertos/semphr.h"
#include "host/ble_hs.h"
#include "host/util/util.h"
#include "nimble/nimble_port.h"
#include "nimble/nimble_port_freertos.h"
#include "nvs_flash.h"
#include "score_protocol.h"
#include "sdkconfig.h"
#include "services/gap/ble_svc_gap.h"
#include "services/gatt/ble_svc_gatt.h"

_Static_assert(CONFIG_BT_NIMBLE_PINNED_TO_CORE == 0, "NimBLE host must use Core 0");
_Static_assert(CONFIG_BT_CTRL_PINNED_TO_CORE == 0, "BLE controller must use Core 0");
_Static_assert(CONFIG_BT_NIMBLE_MAX_CONNECTIONS == 1, "single score client only");
#if CONFIG_BT_NIMBLE_NVS_PERSIST
#error "Score BLE must not persist bonds during real-time performance"
#endif

enum { INGRESS_COUNT = 2 };
static const char *TAG = "score_ble";
/* NimBLE's UUID macro takes least-significant byte first. */
static const ble_uuid128_t service_uuid = BLE_UUID128_INIT(
    0x01, 0x00, 0x00, 0x00, 0xc8, 0x43, 0xb0, 0x9a,
    0x31, 0x4e, 0x7a, 0x8d, 0x01, 0x00, 0x34, 0xe6);
static const ble_uuid128_t rx_uuid = BLE_UUID128_INIT(
    0x01, 0x00, 0x00, 0x00, 0xc8, 0x43, 0xb0, 0x9a,
    0x31, 0x4e, 0x7a, 0x8d, 0x02, 0x00, 0x34, 0xe6);
static const ble_uuid128_t tx_uuid = BLE_UUID128_INIT(
    0x01, 0x00, 0x00, 0x00, 0xc8, 0x43, 0xb0, 0x9a,
    0x31, 0x4e, 0x7a, 0x8d, 0x03, 0x00, 0x34, 0xe6);

static portMUX_TYPE lock = portMUX_INITIALIZER_UNLOCKED;
static score_ble_link_t link_state = { .max_write = 20 };
static score_ble_stats_t counters;
static uint16_t connection = BLE_HS_CONN_HANDLE_NONE, tx_handle;
static uint8_t own_addr_type;
static bool host_started, startup_failed, startup_complete, host_synced;
static StaticSemaphore_t sync_control;
static SemaphoreHandle_t sync_done;
static esp_err_t sync_result = ESP_ERR_TIMEOUT;
static uint32_t abort_epoch;
static QueueHandle_t ingress;
static StaticQueue_t ingress_control;
static uint8_t ingress_storage[INGRESS_COUNT * sizeof(score_ble_fragment_t)];
static struct ble_npl_event tx_event;
/* One outgoing application frame: never interleave ACK and CHANGED fragments. */
static struct {
    uint8_t bytes[SCORE_MAX_FRAME];
    uint32_t epoch, progress_ms;
    uint16_t length, offset;
} tx;
_Static_assert(sizeof(ingress_storage) + sizeof(tx) <= SCORE_BLE_DATA_BUDGET,
               "BLE application buffers exceed their reserved budget");

static int gap_event(struct ble_gap_event *event, void *arg);
#if CONFIG_SCORE_DIAGNOSTICS
static void diagnostic_link(void)
{
    struct ble_gap_conn_desc desc = {0};
    uint16_t mtu = 0;
    if (link_state.connected) {
        ble_gap_conn_find(connection, &desc);
        mtu = ble_att_mtu(connection);
    }
    score_diag_link(link_state.epoch, link_state.connected, link_state.subscribed,
        mtu, link_state.max_write, desc.conn_itvl, desc.conn_latency, desc.supervision_timeout);
}
#endif

/* Host-context only: query the negotiated ATT channel outside our spinlock.
 * MTU events alone are insufficient: a connection/subscription callback may
 * observe negotiation that already completed before our cached link update. */
static bool refresh_max_write(uint16_t conn)
{
    if (!link_state.connected || connection != conn) return false;
    uint16_t mtu = ble_att_mtu(conn);
    if (mtu == 0) return false; /* No ATT channel; retain the current limit. */
    unsigned maximum = mtu > 3 ? mtu - 3 : 20;
    if (maximum > SCORE_BLE_FRAGMENT_MAX) maximum = SCORE_BLE_FRAGMENT_MAX;
    portENTER_CRITICAL(&lock);
    bool changed = link_state.max_write != maximum;
    link_state.max_write = (uint16_t)maximum;
    portEXIT_CRITICAL(&lock);
    return changed;
}

static uint32_t now_ms(void)
{
    return (uint32_t)(esp_timer_get_time() / 1000);
}

static void request_tx_event(void)
{
    if (host_started) ble_npl_eventq_put(nimble_port_get_dflt_eventq(), &tx_event);
}

static int advertise(void)
{
    if (startup_failed || !host_synced) return BLE_HS_EDISABLED;
    struct ble_hs_adv_fields fields = {0};
    fields.flags = BLE_HS_ADV_F_DISC_GEN | BLE_HS_ADV_F_BREDR_UNSUP;
    fields.uuids128 = (ble_uuid128_t *)&service_uuid;
    fields.num_uuids128 = 1;
    fields.uuids128_is_complete = 1;
    int rc = ble_gap_adv_set_fields(&fields);
    if (rc == 0) {
        /* Full 128-bit service UUID fits advertisement; name is scan response. */
        struct ble_hs_adv_fields response = {0};
        response.name = (uint8_t *)"PianoScore-S3";
        response.name_len = strlen((const char *)response.name);
        response.name_is_complete = 1;
        rc = ble_gap_adv_rsp_set_fields(&response);
    }
    if (rc == 0) {
        struct ble_gap_adv_params params = {0};
        params.conn_mode = BLE_GAP_CONN_MODE_UND;
        params.disc_mode = BLE_GAP_DISC_MODE_GEN;
        rc = ble_gap_adv_start(own_addr_type, NULL, BLE_HS_FOREVER,
                              &params, gap_event, NULL);
    }
    if (rc != 0) ESP_LOGE(TAG, "advertise failed rc=%d; no controller restart", rc);
    return rc;
}

static void clear_link(void)
{
    portENTER_CRITICAL(&lock);
    link_state.connected = false;
    link_state.subscribed = false;
    link_state.max_write = 20;
    connection = BLE_HS_CONN_HANDLE_NONE;
    tx.length = 0;
    abort_epoch = 0;
    portEXIT_CRITICAL(&lock);
    SCORE_DIAG(score_diag_reset(0));
    SCORE_DIAG(diagnostic_link());
    /* No persistence operation and no downstream DELETE/PAUSE on disconnect. */
    xQueueReset(ingress);
}

static int access_rx(uint16_t conn, uint16_t handle,
                     struct ble_gatt_access_ctxt *ctxt, void *arg)
{
    (void)handle;
    (void)arg;
    if (ctxt->op != BLE_GATT_ACCESS_OP_WRITE_CHR) return BLE_ATT_ERR_WRITE_NOT_PERMITTED;
    score_ble_fragment_t fragment;
    SCORE_DIAG(fragment.arrival_us = score_diag_clock());
    if (refresh_max_write(conn)) { SCORE_DIAG(diagnostic_link()); }
    portENTER_CRITICAL(&lock);
    bool allowed = link_state.connected && link_state.subscribed && connection == conn;
    fragment.epoch = link_state.epoch;
    uint16_t maximum = link_state.max_write;
    portEXIT_CRITICAL(&lock);
    size_t length = OS_MBUF_PKTLEN(ctxt->om);
    int result = 0;
    if (!allowed) result = BLE_ATT_ERR_UNLIKELY;
    else if (length == 0 || length > maximum || length > sizeof(fragment.bytes))
        result = BLE_ATT_ERR_INVALID_ATTR_VALUE_LEN;
    else if (ble_hs_mbuf_to_flat(ctxt->om, fragment.bytes, sizeof(fragment.bytes),
                                &fragment.length) != 0)
        result = BLE_ATT_ERR_UNLIKELY;
    else if (xQueueSend(ingress, &fragment, 0) != pdTRUE)
        result = BLE_ATT_ERR_INSUFFICIENT_RES;
    if (result != 0) {
        portENTER_CRITICAL(&lock);
        counters.rejected_writes++;
        portEXIT_CRITICAL(&lock);
    }
    /* The mbuf is owned by NimBLE; only the copied fragment leaves this call. */
    return result;
}

static int access_tx(uint16_t conn, uint16_t handle,
                     struct ble_gatt_access_ctxt *ctxt, void *arg)
{
    (void)conn; (void)handle; (void)ctxt; (void)arg;
    /* Notifications always use notify_custom's copied mbuf, never a read. */
    return BLE_ATT_ERR_READ_NOT_PERMITTED;
}

static const struct ble_gatt_svc_def services[] = {
    {
        .type = BLE_GATT_SVC_TYPE_PRIMARY,
        .uuid = &service_uuid.u,
        .characteristics = (struct ble_gatt_chr_def[]) {
            { .uuid = &rx_uuid.u, .access_cb = access_rx, .flags = BLE_GATT_CHR_F_WRITE },
            { .uuid = &tx_uuid.u, .access_cb = access_tx,
              .flags = BLE_GATT_CHR_F_NOTIFY, .val_handle = &tx_handle },
            {0},
        },
    },
    {0},
};

/* Runs on the NimBLE host queue. Connection/disconnect and notification calls
 * cannot race a reused connection handle. A failed enqueue retries this unsent
 * fragment only; this is not an application request retry. */
static void transmit_event(struct ble_npl_event *event)
{
    (void)event;
    uint16_t handle, length, offset;
    uint32_t epoch;
    bool terminate = false;
    if (refresh_max_write(connection)) { SCORE_DIAG(diagnostic_link()); }
    portENTER_CRITICAL(&lock);
    handle = connection;
    epoch = link_state.epoch;
    if (link_state.connected && abort_epoch == epoch) {
        terminate = true;
        link_state.subscribed = false;
        abort_epoch = 0;
        tx.length = 0;
    }
    if (tx.length != 0 && (!link_state.connected || !link_state.subscribed || tx.epoch != epoch))
        tx.length = 0;
    if (tx.length != 0 && (uint32_t)(now_ms() - tx.progress_ms) >= 5000) {
        terminate = true;
        link_state.subscribed = false;
        tx.length = 0;
        counters.notify_failures++;
    }
    offset = tx.offset;
    length = tx.length != 0 ? tx.length - tx.offset : 0;
    if (length > link_state.max_write) length = link_state.max_write;
    portEXIT_CRITICAL(&lock);
    if (terminate) {
        ble_gap_terminate(handle, BLE_ERR_REM_USER_CONN_TERM);
        return;
    }
    if (length == 0) return;
    struct os_mbuf *om = ble_hs_mbuf_from_flat(tx.bytes + offset, length);
    if (!om) { SCORE_DIAG(score_diag_notify_part(false, false)); return; }
    /* notify_custom consumes om on BOTH success and failure. NOTIFY_TX is
     * synchronous in this IDF host and is queue acceptance, not receiver ACK. */
    int rc = ble_gatts_notify_custom(handle, tx_handle, om);
    SCORE_DIAG(score_diag_notify_part(rc == 0, offset + length == tx.length));
    portENTER_CRITICAL(&lock);
    if (rc == 0) {
        tx.offset += length;
        tx.progress_ms = now_ms();
        if (tx.offset == tx.length) tx.length = 0;
    } else if (rc != BLE_HS_ENOMEM && rc != BLE_HS_EBUSY && rc != BLE_HS_EAGAIN) {
        counters.notify_failures++;
        abort_epoch = epoch;
    }
    portEXIT_CRITICAL(&lock);
}

static int gap_event(struct ble_gap_event *event, void *arg)
{
    (void)arg;
    switch (event->type) {
    case BLE_GAP_EVENT_CONNECT:
        if (event->connect.status != 0) { advertise(); break; }
        portENTER_CRITICAL(&lock);
        connection = event->connect.conn_handle;
        link_state.epoch++;
        if (link_state.epoch == 0) link_state.epoch++;
        link_state.connected = true;
        link_state.subscribed = false;
        link_state.max_write = 20;
        tx.length = 0;
        abort_epoch = 0;
        portEXIT_CRITICAL(&lock);
        refresh_max_write(connection);
        SCORE_DIAG(score_diag_reset(link_state.epoch));
        SCORE_DIAG(diagnostic_link());
        break;
    case BLE_GAP_EVENT_DISCONNECT:
        portENTER_CRITICAL(&lock);
        counters.disconnects++;
        portEXIT_CRITICAL(&lock);
        clear_link();
        advertise();
        break;
    case BLE_GAP_EVENT_SUBSCRIBE:
        if (event->subscribe.attr_handle != tx_handle) break;
        refresh_max_write(event->subscribe.conn_handle);
        portENTER_CRITICAL(&lock);
        if (connection == event->subscribe.conn_handle) {
            link_state.subscribed = event->subscribe.cur_notify != 0;
            if (!link_state.subscribed && tx.length != 0) {
                /* A partially emitted application frame cannot be resumed
                 * after a CCCD subscription cycle on the same connection. */
                abort_epoch = link_state.epoch;
                tx.length = 0;
            }
        }
        portEXIT_CRITICAL(&lock);
        SCORE_DIAG(diagnostic_link());
        /* Worker poll schedules any pending abort. Never publish to the host
         * queue from its own callback: IDF's eventq_put can wait if full. */
        break;
    case BLE_GAP_EVENT_MTU:
        refresh_max_write(event->mtu.conn_handle);
        SCORE_DIAG(diagnostic_link());
        break;
#if CONFIG_SCORE_DIAGNOSTICS
    case BLE_GAP_EVENT_CONN_UPDATE:
        diagnostic_link();
        break;
#endif
    case BLE_GAP_EVENT_ADV_COMPLETE:
        advertise();
        break;
    case BLE_GAP_EVENT_REPEAT_PAIRING:
        return BLE_GAP_REPEAT_PAIRING_IGNORE;
    default: break;
    }
    return 0;
}

static void on_reset(int reason)
{
    /* The SDK can resynchronize its existing host/controller. Clear this link,
     * but do not latch a runtime reset into a permanent application failure or
     * deinit/reinit the controller (RF/NVS work) while MIDI is running. */
    host_synced = false;
    clear_link();
    ESP_LOGW(TAG, "NimBLE reset reason=%d; waiting for SDK resynchronization", reason);
}

static void on_sync(void)
{
    if (startup_failed) return;
    bool initial_sync = !startup_complete;
    int rc = ble_hs_util_ensure_addr(0);
    if (rc == 0) rc = ble_hs_id_infer_auto(0, &own_addr_type);
    if (rc != 0) {
        host_synced = false;
        ESP_LOGE(TAG, "BLE identity synchronization failed rc=%d", rc);
        if (initial_sync) {
            startup_failed = true;
            sync_result = ESP_FAIL;
            xSemaphoreGive(sync_done);
        }
        return;
    }
    host_synced = true;
    rc = advertise();
    if (initial_sync) {
        sync_result = rc == 0 ? ESP_OK : ESP_FAIL;
        startup_complete = rc == 0;
        startup_failed = rc != 0;
        xSemaphoreGive(sync_done);
    }
}

static void host_task(void *arg)
{
    (void)arg;
    nimble_port_run();
    nimble_port_freertos_deinit();
}

esp_err_t score_ble_start(void)
{
    ingress = xQueueCreateStatic(INGRESS_COUNT, sizeof(score_ble_fragment_t),
                                 ingress_storage, &ingress_control);
    sync_done = xSemaphoreCreateBinaryStatic(&sync_control);
    if (!ingress || !sync_done) return ESP_ERR_NO_MEM;
    esp_err_t err = nvs_flash_init();
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "NVS init failed %s; not erasing NVS; MIDI remains available",
                 esp_err_to_name(err));
        return err;
    }
    err = nimble_port_init();
    if (err != ESP_OK) return err;
    ble_hs_cfg.reset_cb = on_reset;
    ble_hs_cfg.sync_cb = on_sync;
    ble_hs_cfg.sm_bonding = 0;
    ble_hs_cfg.sm_our_key_dist = 0;
    ble_hs_cfg.sm_their_key_dist = 0;
    /* No ble_store_config_init: this service never writes pairing state. */
    ble_svc_gap_init();
    ble_svc_gatt_init();
    int rc = ble_svc_gap_device_name_set("PianoScore-S3");
    if (rc == 0) rc = ble_gatts_count_cfg(services);
    if (rc == 0) rc = ble_gatts_add_svcs(services);
    if (rc == 0) rc = ble_att_set_preferred_mtu(517);
    if (rc != 0) {
        ESP_LOGE(TAG, "GATT setup failed rc=%d; startup cleanup only", rc);
        nimble_port_deinit();
        return ESP_FAIL;
    }
    ble_npl_event_init(&tx_event, transmit_event, NULL);
    host_started = true;
    nimble_port_freertos_init(host_task);
    ESP_LOGI(TAG, "NimBLE Core0 host_prio=%u host_stack=%u controller_prio=%u; 1 connection, no bond storage",
             (unsigned)(configMAX_PRIORITIES - 4), (unsigned)CONFIG_BT_NIMBLE_HOST_TASK_STACK_SIZE,
             (unsigned)ESP_TASK_BT_CONTROLLER_PRIO);
    if (xSemaphoreTake(sync_done, pdMS_TO_TICKS(5000)) != pdTRUE) {
        startup_failed = true;
        ESP_LOGE(TAG, "NimBLE sync timeout; no runtime controller reinitialization");
        return ESP_ERR_TIMEOUT;
    }
    return sync_result;
}

void score_ble_link(score_ble_link_t *link)
{
    portENTER_CRITICAL(&lock);
    *link = link_state;
    portEXIT_CRITICAL(&lock);
}

bool score_ble_receive(score_ble_fragment_t *fragment)
{
    return ingress && xQueueReceive(ingress, fragment, 0) == pdTRUE;
}

bool score_ble_notify(uint32_t epoch, const uint8_t *bytes, size_t length, uint32_t time)
{
    if (!bytes || length == 0 || length > sizeof(tx.bytes)) return false;
    bool accepted = false;
    portENTER_CRITICAL(&lock);
    if (link_state.connected && link_state.subscribed && link_state.epoch == epoch && tx.length == 0) {
        memcpy(tx.bytes, bytes, length);
        tx.epoch = epoch;
        tx.progress_ms = time;
        tx.offset = 0;
        tx.length = (uint16_t)length;
        SCORE_DIAG(score_diag_notify_begin(epoch, bytes, length));
        accepted = true;
    }
    portEXIT_CRITICAL(&lock);
    if (accepted) request_tx_event();
    return accepted;
}

void score_ble_poll(void)
{
    portENTER_CRITICAL(&lock);
    bool pending = tx.length != 0 || abort_epoch != 0;
    portEXIT_CRITICAL(&lock);
    if (pending) request_tx_event();
}

void score_ble_disconnect(uint32_t epoch)
{
    portENTER_CRITICAL(&lock);
    if (link_state.connected && link_state.epoch == epoch) abort_epoch = epoch;
    portEXIT_CRITICAL(&lock);
    request_tx_event();
}

void score_ble_stats(score_ble_stats_t *stats)
{
    portENTER_CRITICAL(&lock);
    *stats = counters;
    portEXIT_CRITICAL(&lock);
}

size_t score_ble_buffer_bytes(void)
{
    return sizeof(ingress_storage) + sizeof(tx);
}
