#pragma once
#include <stdint.h>

/* USB Note On callback-to-SPI-return statistics. Zero count means no sample. */
typedef struct {
    uint32_t count;
    uint32_t over_5ms;
    int64_t min_us;
    int64_t max_us;
    uint64_t sum_us;
} bridge_latency_stats_t;

static inline void bridge_latency_record(bridge_latency_stats_t *stats, int64_t elapsed_us)
{
    if (elapsed_us < 0) return;
    if (stats->count == 0 || elapsed_us < stats->min_us) stats->min_us = elapsed_us;
    if (elapsed_us > stats->max_us) stats->max_us = elapsed_us;
    stats->sum_us += (uint64_t)elapsed_us;
    ++stats->count;
    if (elapsed_us > 5000) ++stats->over_5ms;
}

static inline uint64_t bridge_latency_mean_us(const bridge_latency_stats_t *stats)
{
    return stats->count ? stats->sum_us / stats->count : 0;
}
