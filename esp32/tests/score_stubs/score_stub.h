#ifndef SCORE_STUB_H
#define SCORE_STUB_H
#include <stdbool.h>
#include <assert.h>
#include <stddef.h>
#include <stdint.h>
#include <stdarg.h>
#include <string.h>

/* Deterministic desktop API boundary, not a radio/controller simulator. */
typedef int esp_err_t;
enum { ESP_OK=0, ESP_FAIL=-1, ESP_ERR_NO_MEM=0x101, ESP_ERR_INVALID_ARG=0x102,
       ESP_ERR_INVALID_STATE=0x103, ESP_ERR_TIMEOUT=0x107 };
static inline const char *esp_err_to_name(esp_err_t err) { (void)err; return "stub"; }
static inline void stub_log(const char *tag, const char *fmt, ...)
{ (void)tag; (void)fmt; }
#define ESP_LOGI(...) stub_log(__VA_ARGS__)
#define ESP_LOGW(...) stub_log(__VA_ARGS__)
#define ESP_LOGE(...) stub_log(__VA_ARGS__)

#define CONFIG_BT_NIMBLE_PINNED_TO_CORE 0
#define CONFIG_BT_CTRL_PINNED_TO_CORE 0
#define CONFIG_BT_NIMBLE_MAX_CONNECTIONS 1
#define CONFIG_BT_NIMBLE_HOST_TASK_STACK_SIZE 4096
#define configMAX_PRIORITIES 25
#define ESP_TASK_BT_CONTROLLER_PRIO 23
typedef int portMUX_TYPE;
#define portMUX_INITIALIZER_UNLOCKED 0
static inline void stub_enter(portMUX_TYPE *p) { assert(*p==0); *p=1; }
static inline void stub_exit(portMUX_TYPE *p) { assert(*p==1); *p=0; }
#define portENTER_CRITICAL(p) stub_enter(p)
#define portEXIT_CRITICAL(p) stub_exit(p)
#define pdTRUE 1
#define pdMS_TO_TICKS(n) (n)
typedef struct {
    size_t capacity, item_size, head, count;
    uint8_t *storage;
} StaticQueue_t;
typedef StaticQueue_t *QueueHandle_t;
static inline QueueHandle_t xQueueCreateStatic(size_t n, size_t bytes,
                                              uint8_t *storage, StaticQueue_t *q)
{ *q=(StaticQueue_t){n,bytes,0,0,storage}; return q; }
static inline int xQueueSend(QueueHandle_t q, const void *item, unsigned wait)
{
    (void)wait;
    if (q->count == q->capacity) return 0;
    memcpy(q->storage+((q->head+q->count)%q->capacity)*q->item_size, item, q->item_size);
    ++q->count; return pdTRUE;
}
static inline int xQueueReceive(QueueHandle_t q, void *item, unsigned wait)
{
    (void)wait;
    if (!q->count) return 0;
    memcpy(item,q->storage+q->head*q->item_size,q->item_size);
    q->head=(q->head+1)%q->capacity; --q->count; return pdTRUE;
}
static inline int xQueueReset(QueueHandle_t q) { q->count=q->head=0; return pdTRUE; }
typedef struct { unsigned token; } StaticSemaphore_t;
typedef StaticSemaphore_t *SemaphoreHandle_t;
static inline SemaphoreHandle_t xSemaphoreCreateBinaryStatic(StaticSemaphore_t *s)
{ s->token=0; return s; }
static inline int xSemaphoreGive(SemaphoreHandle_t s) { s->token=1; return pdTRUE; }
static inline int xSemaphoreTake(SemaphoreHandle_t s, unsigned wait)
{ (void)wait; if (!s->token) return 0; s->token=0; return pdTRUE; }

struct ble_npl_event { void (*fn)(struct ble_npl_event *); void *arg; bool queued; };
struct ble_npl_eventq { struct ble_npl_event *pending; };
static inline void ble_npl_event_init(struct ble_npl_event *e,
                                    void (*fn)(struct ble_npl_event *), void *arg)
{ *e=(struct ble_npl_event){fn,arg,false}; }
static inline void ble_npl_eventq_put(struct ble_npl_eventq *q, struct ble_npl_event *e)
{ if (!e->queued) { e->queued=true; q->pending=e; } }

typedef struct { uint8_t type; } ble_uuid_t;
typedef struct { ble_uuid_t u; uint8_t value[16]; } ble_uuid128_t;
#define BLE_UUID128_INIT(...) { {128}, {__VA_ARGS__} }
struct os_mbuf { uint16_t length; uint8_t data[512]; };
#define OS_MBUF_PKTLEN(om) ((om)->length)
struct ble_gatt_access_ctxt { uint8_t op; struct os_mbuf *om; };
typedef int (*stub_access_fn)(uint16_t,uint16_t,struct ble_gatt_access_ctxt*,void*);
struct ble_gatt_chr_def {
    const ble_uuid_t *uuid;
    stub_access_fn access_cb;
    unsigned flags;
    uint16_t *val_handle;
};
struct ble_gatt_svc_def {
    unsigned type;
    const ble_uuid_t *uuid;
    const struct ble_gatt_chr_def *characteristics;
};
struct ble_hs_adv_fields {
    unsigned flags;
    ble_uuid128_t *uuids128;
    unsigned num_uuids128, uuids128_is_complete;
    uint8_t *name;
    size_t name_len;
    unsigned name_is_complete;
};
struct ble_gap_adv_params { unsigned conn_mode, disc_mode; };
struct ble_gap_event {
    unsigned type;
    union {
        struct { int status; uint16_t conn_handle; } connect;
        struct { uint16_t attr_handle, conn_handle; unsigned cur_notify; } subscribe;
        struct { uint16_t conn_handle, value; } mtu;
    };
};
struct stub_hs_config {
    void (*reset_cb)(int);
    void (*sync_cb)(void);
    unsigned sm_bonding, sm_our_key_dist, sm_their_key_dist;
};
extern struct stub_hs_config ble_hs_cfg;
enum {
    BLE_HS_CONN_HANDLE_NONE=0xffff, BLE_HS_ADV_F_DISC_GEN=2,
    BLE_HS_ADV_F_BREDR_UNSUP=4, BLE_HS_FOREVER=0x7fffffff,
    BLE_GAP_CONN_MODE_UND=2, BLE_GAP_DISC_MODE_GEN=2,
    BLE_ATT_ERR_WRITE_NOT_PERMITTED=3, BLE_ATT_ERR_READ_NOT_PERMITTED=2,
    BLE_ATT_ERR_UNLIKELY=14, BLE_ATT_ERR_INVALID_ATTR_VALUE_LEN=13,
    BLE_ATT_ERR_INSUFFICIENT_RES=17, BLE_GATT_ACCESS_OP_WRITE_CHR=2,
    BLE_GATT_SVC_TYPE_PRIMARY=1, BLE_GATT_CHR_F_WRITE=8, BLE_GATT_CHR_F_NOTIFY=16,
    BLE_HS_ENOMEM=6, BLE_HS_EBUSY=15, BLE_HS_EAGAIN=1, BLE_HS_EDISABLED=30,
    BLE_ERR_REM_USER_CONN_TERM=0x13, BLE_GAP_REPEAT_PAIRING_IGNORE=0,
    BLE_GAP_EVENT_CONNECT=1, BLE_GAP_EVENT_DISCONNECT,
    BLE_GAP_EVENT_SUBSCRIBE, BLE_GAP_EVENT_MTU, BLE_GAP_EVENT_ADV_COMPLETE,
    BLE_GAP_EVENT_CONN_UPDATE, BLE_GAP_EVENT_REPEAT_PAIRING
};
typedef int (*stub_gap_fn)(struct ble_gap_event*,void*);
int64_t esp_timer_get_time(void);
esp_err_t nvs_flash_init(void);
esp_err_t nimble_port_init(void);
esp_err_t nimble_port_deinit(void);
void nimble_port_run(void);
void nimble_port_freertos_init(void (*task)(void*));
void nimble_port_freertos_deinit(void);
struct ble_npl_eventq *nimble_port_get_dflt_eventq(void);
int ble_gap_adv_set_fields(const struct ble_hs_adv_fields *fields);
int ble_gap_adv_rsp_set_fields(const struct ble_hs_adv_fields *fields);
int ble_gap_adv_start(uint8_t own,const void *direct,int time,
                      const struct ble_gap_adv_params *params,stub_gap_fn fn,void *arg);
int ble_gap_terminate(uint16_t handle,uint8_t reason);
int ble_hs_mbuf_to_flat(const struct os_mbuf *om,void *dst,size_t cap,uint16_t *len);
struct os_mbuf *ble_hs_mbuf_from_flat(const void *data,uint16_t len);
int ble_gatts_notify_custom(uint16_t handle,uint16_t attr,struct os_mbuf *om);
int ble_hs_util_ensure_addr(int random);
int ble_hs_id_infer_auto(int privacy,uint8_t *own);
void ble_svc_gap_init(void);
void ble_svc_gatt_init(void);
int ble_svc_gap_device_name_set(const char *name);
int ble_gatts_count_cfg(const struct ble_gatt_svc_def *services);
int ble_gatts_add_svcs(const struct ble_gatt_svc_def *services);
int ble_att_set_preferred_mtu(uint16_t mtu);
uint16_t ble_att_mtu(uint16_t handle);

#if CONFIG_SCORE_DIAGNOSTICS
struct ble_gap_conn_desc { uint16_t conn_itvl, conn_latency, supervision_timeout; };
int ble_gap_conn_find(uint16_t handle, struct ble_gap_conn_desc *desc);
#endif
#endif
