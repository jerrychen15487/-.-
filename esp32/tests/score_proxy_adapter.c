/* Desktop test adapter only: exercises production C via Python/SQLite. */
#include "score_proxy.h"
#include <string.h>
#ifdef _WIN32
#define API __declspec(dllexport)
#else
#define API
#endif
static score_proxy_t proxy;
static uint8_t uart[SCORE_MAX_FRAME], ble[SCORE_MAX_FRAME];
static size_t uart_len, ble_len;
static uint32_t epoch;
static bool send_uart(const uint8_t *p, size_t n, void *ctx)
{
    (void)ctx;
    if (uart_len) return false;
    memcpy(uart, p, n); uart_len = n; return true;
}
static bool notify(const uint8_t *p, size_t n, void *ctx)
{
    (void)ctx;
    if (ble_len) return false;
    memcpy(ble, p, n); ble_len = n; return true;
}
API void adapter_connect(uint32_t value)
{
    score_proxy_io_t io = {.uart_send=send_uart, .notify=notify};
    score_proxy_init(&proxy, &io);
    uart_len = ble_len = 0; epoch = value;
    score_proxy_connect(&proxy, epoch, 20, true);
}
API void adapter_ble(const uint8_t *p, size_t n, uint32_t now)
{ score_proxy_ble_feed(&proxy, epoch, p, n, now); }
API void adapter_uart(const uint8_t *p, size_t n, uint32_t now)
{ score_proxy_uart_feed(&proxy, p, n, now); }
API void adapter_poll(uint32_t now) { score_proxy_poll(&proxy, now); }
API int adapter_connected(void) { return proxy.connected; }
API size_t adapter_take_uart(uint8_t *p)
{ size_t n = uart_len; memcpy(p, uart, n); uart_len = 0; return n; }
API size_t adapter_take_ble(uint8_t *p)
{ size_t n = ble_len; memcpy(p, ble, n); ble_len = 0; return n; }
