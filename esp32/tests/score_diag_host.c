/* Platform seam for running the unchanged proxy regression with hooks enabled. */
#include "score_diag.h"
uint64_t score_diag_clock(void) { static uint64_t ticks; return ++ticks; }
void score_diag_lock(void) { }
void score_diag_unlock(void) { }
