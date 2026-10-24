# Firmware ESP32-D — AUTCONT

Controlador único: TB6600 + E18-D80NK + MLX90614 + HX711 + buzzer.

## Preparação

1. Instale as bibliotecas listadas em `docs/testes.md`.
2. `copy secrets.example.h secrets.h` e edite Wi-Fi / MQTT / API.
3. Abra `esp32_autcont.ino` na Arduino IDE (placa **ESP32 Dev Module**).
4. Grave e monitore a serial em 115200.

## Pinagem

Ver `docs/hardware.md` e `config.h`.

## Histórico

A versão anterior (DRV8825/A4988) permanece em `arduinoV4/sensor_e_motor/`.
