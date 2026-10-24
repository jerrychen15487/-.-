#pragma once
#include <assert.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
typedef int esp_err_t;
#define ESP_OK 0
#define ESP_FAIL -1
#define ESP_ERR_TIMEOUT 0x107
#define ESP_ERROR_CHECK(x) assert((x) == ESP_OK)
#define configASSERT(x) assert(x)
#define ESP_INTR_FLAG_LEVEL1 1
typedef int BaseType_t;
typedef unsigned TickType_t;
typedef void *TaskHandle_t;
#define pdPASS 1
#define pdTRUE 1
#define portMAX_DELAY UINT32_MAX
#define configTICK_RATE_HZ 1000
void test_log(const char *tag, const char *format, ...);
#define ESP_LOGI(...) test_log(__VA_ARGS__)
#define ESP_LOGW(...) test_log(__VA_ARGS__)
static inline const char *esp_err_to_name(esp_err_t e) { (void)e; return "mock"; }
extern int64_t test_now_us;
static inline int64_t esp_timer_get_time(void) { return test_now_us; }
static inline TaskHandle_t xTaskGetCurrentTaskHandle(void) { return NULL; }
static inline unsigned ulTaskNotifyTake(int clear, unsigned timeout) { (void)clear; (void)timeout; return 1; }
static inline void xTaskNotifyGive(TaskHandle_t task) { (void)task; }
static inline BaseType_t xTaskCreatePinnedToCore(void (*f)(void *), const char *name, unsigned stack,
                                              void *arg, int priority, void *out, int core)
{ (void)f; (void)name; (void)stack; (void)arg; (void)priority; (void)out; (void)core; return pdPASS; }

/* Single-threaded bounded-trace test; does not model SMP scheduling. */
typedef int portMUX_TYPE;
#define portMUX_INITIALIZER_UNLOCKED 0
#define portENTER_CRITICAL(m) ((void)(m))
#define portEXIT_CRITICAL(m) ((void)(m))
#define ESP_LOG_BUFFER_HEX(tag, data, len) test_hex(tag, data, len)
void test_hex(const char *tag, const void *bytes, size_t length);
