#ifndef SCORE_SERVICE_STUB_H
#define SCORE_SERVICE_STUB_H
#include "score_stub.h"

typedef unsigned TickType_t;
typedef void *TaskHandle_t;
#define portMAX_DELAY UINT32_MAX
#define pdPASS 1
#define MALLOC_CAP_8BIT 1
uint32_t esp_random(void);
unsigned ulTaskNotifyTake(int clear,unsigned wait);
int xTaskCreatePinnedToCore(void (*task)(void*),const char *name,unsigned stack,
                            void *arg,unsigned priority,TaskHandle_t *handle,int core);
void xTaskNotifyGive(TaskHandle_t task);
void vTaskDelay(TickType_t delay);
unsigned uxTaskGetStackHighWaterMark(TaskHandle_t task);
size_t heap_caps_get_minimum_free_size(unsigned caps);
size_t heap_caps_get_largest_free_block(unsigned caps);
#endif
