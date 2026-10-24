#include "bridge.h"
#include "sdkconfig.h"
#include "esp_log.h"
#if CONFIG_SCORE_ENABLED
#include "score_service.h"
#endif
#if CONFIG_JOYSTICK_DIAGNOSTICS
#include "joystick_diag.h"
#endif

void app_main(void)
{
#if CONFIG_SCORE_ENABLED
    score_service_start();
#endif
    bridge_init();
#if CONFIG_JOYSTICK_DIAGNOSTICS
    joystick_diag_start();
#endif
#if CONFIG_BRIDGE_SIM_INPUT
    ESP_LOGI("app", "input=SIM: 100 rounds x 64 events, every two seconds");
    sim_input_start();
#else
    ESP_LOGI("app", "input=USB: USB-MIDI 1.0; UART0 is the CH340 debug console");
    usb_midi_start();
#endif
}
