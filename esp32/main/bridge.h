#pragma once
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include "midi_codec.h"

enum { BRIDGE_CORE = 1, BRIDGE_USB_PRIORITY = 20, BRIDGE_CLIENT_PRIORITY = 19,
       BRIDGE_TX_PRIORITY = 18, BRIDGE_QUEUE_LENGTH = 64 };
void bridge_init(void);
void bridge_start_session(void);
void bridge_end_session(void);
/* Called only by the input task on Core 1 (USB callback is not an ISR). */
void bridge_receive(const uint8_t *bytes, size_t length, int64_t received_us);
/* Queue one locally generated six-byte control frame (for example, joystick
 * pitch bend or modulation). The frame is copied before this function returns. */
bool bridge_send_local(const midi_frame_t *frame, int64_t received_us);
void bridge_set_octave_shift(int shift);
void bridge_usb_error(void);
void usb_midi_start(void);
void sim_input_start(void);
