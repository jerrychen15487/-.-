#ifndef SCORE_UART_STUB_H
#define SCORE_UART_STUB_H
#include "score_stub.h"

/* Config inputs are variable here solely to test every production guard
 * without building an IDF image for each rejected pin combination. */
extern int stub_tx_pin, stub_rx_pin, stub_rx_marker, stub_tx_marker;
#ifdef SCORE_TEST_CONST_UNASSIGNED
#define CONFIG_SCORE_UART_TX_PIN -1
#define CONFIG_SCORE_UART_RX_PIN -1
#else
#define CONFIG_SCORE_UART_TX_PIN stub_tx_pin
#define CONFIG_SCORE_UART_RX_PIN stub_rx_pin
#endif
#define CONFIG_BRIDGE_SCLK_PIN 12
#define CONFIG_BRIDGE_MOSI_PIN 11
#define CONFIG_BRIDGE_CS_PIN 10
#define CONFIG_BRIDGE_READY_PIN 13
#define CONFIG_BRIDGE_RX_MARK_PIN stub_rx_marker
#define CONFIG_BRIDGE_TX_MARK_PIN stub_tx_marker
/* Match the IDF mask macro's negative-shift compile hazard, not just range
 * checks, so the default -1 build guard has an independent regression check. */
#define GPIO_IS_VALID_GPIO(n) ((n)>=0 && (((UINT64_C(1)<<(n)) & UINT64_C(0x1ffffffffffff))!=0))
#define GPIO_IS_VALID_OUTPUT_GPIO(n) (GPIO_IS_VALID_GPIO(n) && (n)!=46)
enum { UART_NUM_1=1, UART_DATA_8_BITS=8, UART_PARITY_DISABLE=0,
       UART_STOP_BITS_1=1, UART_HW_FLOWCTRL_DISABLE=0, UART_SCLK_DEFAULT=0,
       UART_PIN_NO_CHANGE=-1, UART_DATA=1, UART_FIFO_OVF, UART_BUFFER_FULL,
       UART_FRAME_ERR, UART_PARITY_ERR, UART_BREAK };
typedef struct {
    int baud_rate, data_bits, parity, stop_bits, flow_ctrl, source_clk;
} uart_config_t;
typedef struct { int type; size_t size; } uart_event_t;
esp_err_t uart_param_config(int port,const uart_config_t *config);
esp_err_t uart_set_pin(int port,int tx,int rx,int rts,int cts);
esp_err_t uart_driver_install(int port,int rx_bytes,int tx_bytes,int count,
                              QueueHandle_t *events,int flags);
int uart_write_bytes(int port,const void *bytes,size_t length);
int uart_read_bytes(int port,void *bytes,size_t length,unsigned wait);
esp_err_t uart_flush_input(int port);
#endif
