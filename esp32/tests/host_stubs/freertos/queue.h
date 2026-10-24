#pragma once
#include "test_platform.h"
typedef struct {
    uint8_t *storage;
    unsigned capacity, size, head, count;
} StaticQueue_t;
typedef StaticQueue_t *QueueHandle_t;
QueueHandle_t xQueueCreateStatic(unsigned capacity, unsigned size, uint8_t *storage, StaticQueue_t *control);
BaseType_t xQueueSend(QueueHandle_t q, const void *item, TickType_t wait);
BaseType_t xQueueReceive(QueueHandle_t q, void *item, TickType_t wait);
