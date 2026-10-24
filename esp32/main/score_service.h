#pragma once

/* Called before bridge_init; waits only for bounded startup, never for a peer. */
void score_service_start(void);
