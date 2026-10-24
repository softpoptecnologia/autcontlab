#pragma once
// ============================================================
// AUTCONT — configuração do ESP32-D (um único controlador)
// Credenciais: copie secrets.example.h → secrets.h (não versionar).
// ============================================================

#ifndef WIFI_SSID
#define WIFI_SSID "Lab-Calabouco"
#endif
#ifndef WIFI_PASSWORD
#define WIFI_PASSWORD "ailsonETE"
#endif
#ifndef MQTT_HOST
#define MQTT_HOST "10.0.0.136"
#endif
#ifndef MQTT_PORT
#define MQTT_PORT 1883
#endif
#ifndef API_HOST
#define API_HOST "10.0.0.136"
#endif
#ifndef API_PORT
#define API_PORT 5000
#endif

#define DEVICE_CODE "esteira1"
#define API_PATH_LEITURAS "/leituras"
#define API_PATH_PESAGENS "/pesagens"

// --- Pinos (ESP32-D DevKit) ---------------------------------
#define SENSOR_PIN   27   // E18-D80NK OUT (NPN, ativo LOW)
#define STEP_PIN     25   // TB6600 PUL− (ânodo comum)
#define DIR_PIN      26   // TB6600 DIR− (ânodo comum)
#define I2C_SDA      13   // MLX90614
#define I2C_SCL      23
#define HX711_DOUT   32
#define HX711_SCK    33
#define BUZZER_PIN   18

// TB6600: ENA+ / ENA− desconectados — sem pino ENABLE no ESP32.

// --- Motor NEMA 17 + TB6600 ---------------------------------
#define FULL_STEPS_PER_REV 200
#define MICROSTEP          8    // DIP SW1 OFF, SW2 ON, SW3 OFF → 1600 pulsos/rev
#define DEFAULT_RPM        30
#define DEFAULT_DIR        0
#define MIN_RPM            5
#define MAX_RPM            200
#define START_RPM          5
#define RAMP_STEP_RPM      1
#define RAMP_INTERVAL_MS   30

// Pulso ativo em LOW (ligação ânodo comum). Idle = HIGH.
#define STEP_IDLE_LEVEL    HIGH

// --- Sensor E18 ---------------------------------------------
#define SENSOR_REFRACT_MS  200

// --- Balança HX711 ------------------------------------------
#define SCALE_CAL_DEFAULT       420.0f   // substituir após calibração física
#define SCALE_PRESENCE_G        20.0f    // limiar de presença na plataforma
#define SCALE_EMPTY_G           5.0f     // considerado vazio / retirado
#define SCALE_STABILITY_TOL_G   2.0f     // amplitude máx. na janela
#define SCALE_WINDOW_SAMPLES    12
#define SCALE_STABLE_MS         800
#define SCALE_WEIGH_TIMEOUT_MS  8000
#define SCALE_POSITION_TIMEOUT_MS 15000
#define SCALE_REMOVE_TIMEOUT_MS 30000
#define SCALE_SETTLE_MS         400

// --- Buzzer -------------------------------------------------
#define BUZZER_ENABLED_DEFAULT true
#define BUZZER_BEEP_MS         150
#define BUZZER_GAP_MS          150
#define BUZZER_SUCCESS_BEEPS   2
#define BUZZER_ERROR_BEEPS     3

// --- Status periódico ---------------------------------------
#define STATUS_INTERVAL_MS     2000
