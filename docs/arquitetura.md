# AUTCONT — Arquitetura

## Visão geral

Um único **ESP32-D (DevKit)** controla toda a estação física:

- Motor de passo NEMA 17 via **TB6600**
- Contagem **E18-D80NK**
- Temperatura **MLX90614**
- Pesagem **HX711** + célula de carga
- Confirmação sonora por **buzzer** (substitui o atuador mecânico)

O servidor permanece com Flask, MySQL, MQTT (Mosquitto) e painel web.

```text
ESP32-D ──Wi-Fi──► MQTT broker + HTTP API Flask ──► MySQL ──► Painel AUTCONT
```

## Componentes de software

| Parte | Caminho | Função |
|---|---|---|
| Firmware atual | `firmware/esp32_autcont/` | Ciclo completo transporte → pesagem → buzzer |
| Firmware histórico | `arduinoV4/sensor_e_motor/` | Versão anterior DRV8825/A4988 (preservada) |
| API | `backend/app.py` | Sessões, leituras, pesagens, motor, balança |
| Worker MQTT | `backend/mqtt_worker.py` | Consome `event`/`status` e atualiza `dispositivo_status` |
| Painel | `backend/templates/dashboard/` | Central, motor, **Estação AUTCONT** |
| App Flutter | `contagem_esteiraV3/` | Operação de sessão (preservado) |

## Fora de escopo (definitivo)

- Segundo ESP / ESP8266
- Motor DC de expulsão, HW-130, L293D, SN74HC595, fins de curso
- Comunicação MQTT entre microcontroladores

## Fluxo de produção (resumo)

1. Sessão `start` via MQTT → esteira liga, contagem habilitada  
2. E18 detecta produto → `cycle_id = sessao-produto`  
3. Posicionamento confirmado por limiar de peso no HX711  
4. Esteira para → estabilização → pesagem com janela de amostras  
5. Buzzer (2 beeps) → `POST /pesagens` + evento MQTT  
6. Aguarda retirada (peso ≈ 0) → libera próximo ciclo  

Falhas entram em `FALHA` e exigem `ack_falha` (sem retomada automática).
