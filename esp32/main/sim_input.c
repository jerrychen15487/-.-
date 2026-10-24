#include "bridge.h"
#include <string.h>
#include "esp_timer.h"
#include "esp_log.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"

/* 16 chronological events: dynamics, chord, half-pedal and releases. */
static const uint8_t phrase[][4] = {
    {0x09,0x90,60,32}, {0x08,0x80,60,64},
    {0x09,0x90,60,100}, {0x09,0x90,60,0},
    {0x0b,0xb0,64,127},
    {0x09,0x90,60,80}, {0x09,0x90,64,90}, {0x09,0x90,67,100},
    {0x08,0x80,60,64}, {0x08,0x80,64,64}, {0x08,0x80,67,64},
    {0x0b,0xb0,64,32}, {0x0b,0xb0,64,0},
    {0x0b,0xb0,67,127}, {0x0b,0xb0,67,0}, {0x0b,0xb0,1,0},
};

static void sim_task(void *arg)
{
    uint8_t burst[4 * sizeof(phrase)];
    for (size_t i = 0; i < 4; ++i) memcpy(burst + i * sizeof(phrase), phrase, sizeof(phrase));
    bridge_start_session();
    for (unsigned round = 0; round < 100; ++round) {
        /* Same parser/queue/SPI path; one timestamp for all 64 events. */
        bridge_receive(burst, sizeof(burst), esp_timer_get_time());
        vTaskDelay(pdMS_TO_TICKS(2000));
    }
    ESP_LOGI("sim", "SIM_DONE rounds=100 injected=6400; check bridge sent/errors/max_us");
    vTaskDelete(NULL);
}

void sim_input_start(void)
{
    BaseType_t ok = xTaskCreatePinnedToCore(sim_task, "midi_sim", 3072, NULL,
                                           BRIDGE_CLIENT_PRIORITY, NULL, BRIDGE_CORE);
    configASSERT(ok == pdPASS);
}
