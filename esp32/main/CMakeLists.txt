set(bridge_sources "app_main.c" "bridge.c" "usb_midi_host.c" "sim_input.c"
    "midi_codec.c" "midi_descriptors.c" "event_trace.c")
# IDF expands component requirements before loading CONFIG_*; keep dependency
# discovery unconditional. Score/BT sources remain disabled in the off profile.
set(bridge_requires esp_driver_spi esp_driver_gpio esp_timer esp_adc usb esp_driver_uart bt nvs_flash)
if(CONFIG_JOYSTICK_DIAGNOSTICS)
    list(APPEND bridge_sources "joystick_diag.c")
endif()
if(CONFIG_SCORE_ENABLED)
    list(APPEND bridge_sources "score_service.c" "score_uart.c" "score_protocol.c")
endif()
if(CONFIG_SCORE_BLE_ENABLED)
    list(APPEND bridge_sources "score_ble.c" "score_proxy.c" "score_json.c")
endif()
if(CONFIG_SCORE_DIAGNOSTICS)
    list(APPEND bridge_sources "score_diag.c" "score_diag_idf.c")
endif()
idf_component_register(SRCS ${bridge_sources} INCLUDE_DIRS "." REQUIRES ${bridge_requires})
