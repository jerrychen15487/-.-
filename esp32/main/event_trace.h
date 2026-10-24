#pragma once
#include "sdkconfig.h"
#include <stddef.h>
#include <stdint.h>
#ifdef CONFIG_BRIDGE_DETAIL_LOG
void event_trace_init(void);
void event_trace_session(uint32_t session);
void event_trace_record(int kind, const uint8_t *bytes, size_t length, int64_t received_us, int status);
void event_trace_dump(void);
#else
#define event_trace_init() ((void)0)
#define event_trace_session(s) ((void)0)
#define event_trace_record(k, b, n, t, s) ((void)0)
#define event_trace_dump() ((void)0)
#endif
