#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include "esp_err.h"
#include "score_diag.h"

/* Fixed ingress + outgoing-frame storage, including their slot metadata.
 * Queue/semaphore control blocks, task stacks and stack/driver allocations are
 * reported separately and must not be represented as part of this budget. */
enum { SCORE_BLE_FRAGMENT_MAX = 512, SCORE_BLE_DATA_BUDGET = 2200 };
typedef struct {
    uint32_t epoch;
    uint16_t max_write;
    bool connected, subscribed;
} score_ble_link_t;

typedef struct {
    uint32_t epoch;
    uint16_t length;
#if CONFIG_SCORE_DIAGNOSTICS
    uint64_t arrival_us;
#endif
    uint8_t bytes[SCORE_BLE_FRAGMENT_MAX];
} score_ble_fragment_t;

typedef struct {
    uint32_t rejected_writes, notify_failures, disconnects;
} score_ble_stats_t;

/* Startup only; NVS/RF initialize before MIDI starts. No erase fallback. */
esp_err_t score_ble_start(void);
void score_ble_link(score_ble_link_t *link);
bool score_ble_receive(score_ble_fragment_t *fragment);
/* Worker only: copy one entire frame; false means slot/connection unavailable. */
bool score_ble_notify(uint32_t epoch, const uint8_t *bytes, size_t length,
                      uint32_t now_ms);
void score_ble_poll(void);
void score_ble_disconnect(uint32_t epoch);
void score_ble_stats(score_ble_stats_t *stats);
size_t score_ble_buffer_bytes(void);
