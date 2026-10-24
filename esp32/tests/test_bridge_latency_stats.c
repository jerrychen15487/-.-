#include <assert.h>
#include <stdint.h>
#include "bridge_latency_stats.h"

int main(void)
{
    bridge_latency_stats_t stats = {0};
    assert(bridge_latency_mean_us(&stats) == 0);
    bridge_latency_record(&stats, -1);
    assert(stats.count == 0);
    bridge_latency_record(&stats, 365);
    bridge_latency_record(&stats, 120);
    bridge_latency_record(&stats, 5000);
    bridge_latency_record(&stats, 5001);
    assert(stats.count == 4);
    assert(stats.min_us == 120);
    assert(stats.max_us == 5001);
    assert(stats.over_5ms == 1);
    assert(bridge_latency_mean_us(&stats) == (365 + 120 + 5000 + 5001) / 4);
    return 0;
}
