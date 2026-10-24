#include "joystick_diag.h"
#include "bridge.h"

#include "esp_adc/adc_oneshot.h"
#include "esp_check.h"
#include "esp_log.h"
#include "esp_timer.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "driver/gpio.h"

#define JOYSTICK_X_GPIO 1
#define JOYSTICK_Y_GPIO 2
#define JOYSTICK_MOD_GPIO 4
#define JOYSTICK_ADC_MIN 0
#define JOYSTICK_ADC_MAX 4095
#define JOYSTICK_SAMPLES 4
#define JOYSTICK_CONTROL_PERIOD_MS 1
#define JOYSTICK_LOG_PERIOD_MS 200
#define JOYSTICK_CALIBRATION_SAMPLES 200
#define JOYSTICK_DEAD_ZONE 100
#define JOYSTICK_FILTER_SHIFT 2
#define JOYSTICK_SEND_PERIOD_MS 5
#define JOYSTICK_BEND_THRESHOLD 64
#define JOYSTICK_VIBRATO_THRESHOLD 2
#define JOYSTICK_BUTTON_COUNT 2

static const char *TAG = "joystick";

#if CONFIG_JOYSTICK_BUTTONS
static const gpio_num_t button_gpios[JOYSTICK_BUTTON_COUNT] = {
    CONFIG_JOYSTICK_SW1_GPIO, CONFIG_JOYSTICK_SW2_GPIO,
};
#endif

static adc_oneshot_unit_handle_t adc_handle;
static adc_channel_t x_channel;
static adc_channel_t y_channel;
#if CONFIG_JOYSTICK_STEADY_MODULATION
static adc_channel_t mod_channel;
#endif

static int clamp_int(int value, int minimum, int maximum)
{
    if (value < minimum) {
        return minimum;
    }
    if (value > maximum) {
        return maximum;
    }
    return value;
}

static int read_average(adc_channel_t channel)
{
    int total = 0;
    for (int i = 0; i < JOYSTICK_SAMPLES; ++i) {
        int raw = 0;
        ESP_ERROR_CHECK(adc_oneshot_read(adc_handle, channel, &raw));
        total += raw;
    }
    return total / JOYSTICK_SAMPLES;
}

static int map_axis_signed(int raw, int center, int negative_limit, int positive_limit)
{
    const int delta = raw - center;
    if (delta >= -JOYSTICK_DEAD_ZONE && delta <= JOYSTICK_DEAD_ZONE) {
        return 0;
    }

    if (delta > 0) {
        const int span = JOYSTICK_ADC_MAX - center - JOYSTICK_DEAD_ZONE;
        if (span <= 0) {
            return 0;
        }
        const int value = ((delta - JOYSTICK_DEAD_ZONE) * positive_limit) / span;
        return clamp_int(value, 0, positive_limit);
    }

    const int span = center - JOYSTICK_ADC_MIN - JOYSTICK_DEAD_ZONE;
    if (span <= 0) {
        return 0;
    }
    const int value = ((delta + JOYSTICK_DEAD_ZONE) * (-negative_limit)) / span;
    return clamp_int(value, negative_limit, 0);
}

static int absolute_difference(int left, int right)
{
    const int difference = left - right;
    return difference < 0 ? -difference : difference;
}

static void send_pitch_bend(uint16_t bend_u14)
{
    const midi_frame_t frame = {{
        MIDI_PITCH_BEND, 0,
        (uint8_t)(bend_u14 & 0x7f),
        (uint8_t)((bend_u14 >> 7) & 0x7f),
        0, 0,
    }};
    bridge_send_local(&frame, esp_timer_get_time());
}

static void send_vibrato_depth(uint8_t depth)
{
    // Standard MIDI CC1 (modulation wheel) controls the FPGA-local vibrato LFO.
    const midi_frame_t frame = {{MIDI_CONTROL, 0, 1, depth, 0, 0}};
    bridge_send_local(&frame, esp_timer_get_time());
}

#if CONFIG_JOYSTICK_BUTTONS
static void send_button_action(unsigned button)
{
    static int octave_shift;
    octave_shift += button == 0 ? -1 : 1;
    if (octave_shift < -4) octave_shift = -4;
    if (octave_shift > 4) octave_shift = 4;
    bridge_set_octave_shift(octave_shift);
    ESP_LOGI(TAG, "SW%u octave_shift=%d", button + 1, octave_shift);
}

static void configure_buttons(void)
{
    uint64_t mask = 0;
    for (unsigned i = 0; i < JOYSTICK_BUTTON_COUNT; ++i)
        mask |= 1ULL << button_gpios[i];
    const gpio_config_t config = {
        .pin_bit_mask = mask,
        .mode = GPIO_MODE_INPUT,
        .pull_up_en = GPIO_PULLUP_ENABLE,
        .pull_down_en = GPIO_PULLDOWN_DISABLE,
        .intr_type = GPIO_INTR_DISABLE,
    };
    ESP_ERROR_CHECK(gpio_config(&config));
}
#endif

static void calibrate_center(int *x_center, int *y_center)
{
    int64_t x_total = 0;
    int64_t y_total = 0;

    ESP_LOGI(TAG, "keep joystick released and centered: calibrating for %d ms",
             JOYSTICK_CALIBRATION_SAMPLES * JOYSTICK_CONTROL_PERIOD_MS);
    for (int i = 0; i < JOYSTICK_CALIBRATION_SAMPLES; ++i) {
        x_total += read_average(x_channel);
        y_total += read_average(y_channel);
        vTaskDelay(pdMS_TO_TICKS(JOYSTICK_CONTROL_PERIOD_MS));
    }

    *x_center = (int)(x_total / JOYSTICK_CALIBRATION_SAMPLES);
    *y_center = (int)(y_total / JOYSTICK_CALIBRATION_SAMPLES);
    ESP_LOGI(TAG, "calibration complete: center_x=%d center_y=%d dead_zone=+/-%d",
             *x_center, *y_center, JOYSTICK_DEAD_ZONE);
}

static void joystick_task(void *argument)
{
    (void)argument;
    int x_center = 0;
    int y_center = 0;
    calibrate_center(&x_center, &y_center);

    int x_filtered = x_center;
    int y_filtered = y_center;
#if CONFIG_JOYSTICK_STEADY_MODULATION
    int mod_filtered = read_average(mod_channel);
#endif
    TickType_t last_log = xTaskGetTickCount();
    TickType_t last_send = last_log - pdMS_TO_TICKS(JOYSTICK_SEND_PERIOD_MS);
    int last_bend_u14 = -1;
    int last_vibrato_depth = -1;
#if CONFIG_JOYSTICK_BUTTONS
    int button_previous[JOYSTICK_BUTTON_COUNT] = {1, 1};
    int button_stable[JOYSTICK_BUTTON_COUNT] = {1, 1};
    uint8_t button_integrator[JOYSTICK_BUTTON_COUNT] = {0};
#endif

    while (true) {
        const int x_raw = read_average(x_channel);
        const int y_raw = read_average(y_channel);
#if CONFIG_JOYSTICK_STEADY_MODULATION
        const int mod_raw = read_average(mod_channel);
#endif

        // Integer exponential smoothing. At a 1 ms update period this removes
        // ADC chatter while keeping the control response within about 10 ms.
        x_filtered += (x_raw - x_filtered) >> JOYSTICK_FILTER_SHIFT;
        y_filtered += (y_raw - y_filtered) >> JOYSTICK_FILTER_SHIFT;
#if CONFIG_JOYSTICK_STEADY_MODULATION
        mod_filtered += (mod_raw - mod_filtered) >> JOYSTICK_FILTER_SHIFT;
#endif

        const int bend14 = map_axis_signed(x_filtered, x_center, -8192, 8191);
        const int y_signed = map_axis_signed(y_filtered, y_center, -127, 127);
        const int bend_u14 = clamp_int(bend14 + 8192, 0, 16383);
#if CONFIG_JOYSTICK_STEADY_MODULATION
        // RP1 is a non-centering modulation wheel. Y1 is a momentary trim:
        // forward increases and backward decreases the held CC1 depth.
        // A small zero zone makes the fully-off position reliably silent.
        const int steady_depth = mod_filtered <= 80 ? 0 :
            clamp_int(((mod_filtered - 80) * 127) / (JOYSTICK_ADC_MAX - 80), 0, 127);
        const int vibrato_depth = clamp_int(steady_depth + y_signed, 0, 127);
#else
        const int vibrato_depth = y_signed > 0 ? y_signed : 0;
#endif

        const TickType_t now = xTaskGetTickCount();
        if ((now - last_send) >= pdMS_TO_TICKS(JOYSTICK_SEND_PERIOD_MS)) {
            if (last_bend_u14 < 0 || (bend_u14 == 8192 && last_bend_u14 != 8192) ||
                absolute_difference(bend_u14, last_bend_u14) >= JOYSTICK_BEND_THRESHOLD) {
                send_pitch_bend((uint16_t)bend_u14);
                last_bend_u14 = bend_u14;
            }
            if (last_vibrato_depth < 0 ||
                (vibrato_depth == 0 && last_vibrato_depth != 0) ||
                absolute_difference(vibrato_depth, last_vibrato_depth) >= JOYSTICK_VIBRATO_THRESHOLD) {
                send_vibrato_depth((uint8_t)vibrato_depth);
                last_vibrato_depth = vibrato_depth;
            }
            last_send = now;
        }
        if ((now - last_log) >= pdMS_TO_TICKS(JOYSTICK_LOG_PERIOD_MS)) {
            ESP_LOGI(TAG,
                     "CTRL raw_x=%d raw_y=%d filtered_x=%d filtered_y=%d "
                     "bend14=%d y_signed=%d cc1=%d",
                     x_raw, y_raw, x_filtered, y_filtered, bend14, y_signed,
                     vibrato_depth);
            last_log = now;
        }
#if CONFIG_JOYSTICK_BUTTONS
        for (unsigned i = 0; i < JOYSTICK_BUTTON_COUNT; ++i) {
            const int level = gpio_get_level(button_gpios[i]);
            if (level == button_previous[i]) {
                if (button_integrator[i] < 3) ++button_integrator[i];
            } else {
                button_integrator[i] = 0;
                button_previous[i] = level;
            }
            if (button_integrator[i] >= 3 && level != button_stable[i]) {
                button_stable[i] = level;
                if (level == 0) send_button_action(i);
            }
        }
#endif

        vTaskDelay(pdMS_TO_TICKS(JOYSTICK_CONTROL_PERIOD_MS));
    }
}

void joystick_diag_start(void)
{
    adc_unit_t x_unit;
    adc_unit_t y_unit;
    ESP_ERROR_CHECK(adc_oneshot_io_to_channel(JOYSTICK_X_GPIO, &x_unit, &x_channel));
    ESP_ERROR_CHECK(adc_oneshot_io_to_channel(JOYSTICK_Y_GPIO, &y_unit, &y_channel));
    ESP_ERROR_CHECK_WITHOUT_ABORT(x_unit == ADC_UNIT_1 && y_unit == ADC_UNIT_1
                                      ? ESP_OK : ESP_ERR_INVALID_STATE);

    const adc_oneshot_unit_init_cfg_t unit_config = {
        .unit_id = ADC_UNIT_1,
        .ulp_mode = ADC_ULP_MODE_DISABLE,
    };
    ESP_ERROR_CHECK(adc_oneshot_new_unit(&unit_config, &adc_handle));

    const adc_oneshot_chan_cfg_t channel_config = {
        .atten = ADC_ATTEN_DB_12,
        .bitwidth = ADC_BITWIDTH_DEFAULT,
    };
    ESP_ERROR_CHECK(adc_oneshot_config_channel(adc_handle, x_channel, &channel_config));
    ESP_ERROR_CHECK(adc_oneshot_config_channel(adc_handle, y_channel, &channel_config));
#if CONFIG_JOYSTICK_STEADY_MODULATION
    adc_unit_t mod_unit;
    ESP_ERROR_CHECK(adc_oneshot_io_to_channel(JOYSTICK_MOD_GPIO, &mod_unit, &mod_channel));
    ESP_ERROR_CHECK(mod_unit == ADC_UNIT_1 ? ESP_OK : ESP_ERR_INVALID_STATE);
    ESP_ERROR_CHECK(adc_oneshot_config_channel(adc_handle, mod_channel, &channel_config));
#endif
#if CONFIG_JOYSTICK_BUTTONS
    configure_buttons();
#endif

#if CONFIG_JOYSTICK_STEADY_MODULATION
    ESP_LOGI(TAG, "control enabled: X1=GPIO1 bend, Y1=GPIO2 momentary CC1 trim, RP1=GPIO4 held CC1; 3.3V only");
#else
    ESP_LOGI(TAG,
             "control enabled: X1=GPIO1 pitch bend, Y1 positive=CC1 vibrato; 3.3V only");
#endif
#if CONFIG_JOYSTICK_BUTTONS
    ESP_LOGI(TAG, "octave buttons enabled: SW1 down GPIO%d, SW2 up GPIO%d (active low)",
             CONFIG_JOYSTICK_SW1_GPIO, CONFIG_JOYSTICK_SW2_GPIO);
#endif
    const BaseType_t created = xTaskCreatePinnedToCore(
        joystick_task, "joystick_diag", 3072, NULL, 1, NULL, 0);
    ESP_ERROR_CHECK(created == pdPASS ? ESP_OK : ESP_ERR_NO_MEM);
}
