#ifndef SCORE_JSON_H
#define SCORE_JSON_H

#include "score_protocol.h"

/* Both functions write a COMPLETE encoded frame, including CRC, to out.
 * out must not overlap frame->payload. No allocation or retained pointers.
 * On failure *out_len=0, and partial output must be discarded.
 * Request JSON uses exactly the documented keys; duplicate/unknown keys,
 * noninteger numeric forms, invalid UTF-8 and invalid surrogate escapes fail. */
bool score_request_from_ble(const score_frame_t *frame, uint8_t *out,
                            size_t cap, size_t *out_len);
bool score_response_to_ble(const score_frame_t *frame, uint16_t max_write,
                           uint8_t *out, size_t cap, size_t *out_len);

#endif
