#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include "esp_err.h"

typedef struct {
    uint32_t rx_bytes, tx_bytes, fifo_overflow, buffer_full;
    uint32_t frame_error, parity_error, breaks, io_error;
} score_uart_stats_t;

/* All calls belong to the score worker on Core 0, including driver install. */
esp_err_t score_uart_init(void);
bool score_uart_send(const uint8_t *bytes, size_t length);
size_t score_uart_read(uint8_t *bytes, size_t capacity, bool *reset_stream);
const score_uart_stats_t *score_uart_stats(void);
