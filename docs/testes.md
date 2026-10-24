# Plano de testes AUTCONT

**Legenda:** ⬜ não executado · 🟡 compilado/simulado · 🟢 validado no hardware

> Nenhuma marcação 🟢 abaixo foi feita nesta entrega de software — validação física pendente.

## A — Motor TB6600

- ⬜ Partida com rampa
- ⬜ 30 RPM estável
- ⬜ Parada com desaceleração
- ⬜ Mudança de direção só com motor parado

## B — E18-D80NK

- ⬜ Detecção FALLING + pull-up
- ⬜ Refractário / sem contagem duplicada
- ⬜ Fila de eventos sob carga

## C — MLX90614

- ⬜ Ambiente e objeto coerentes
- ⬜ Indisponível → sem temperatura fictícia

## D — HX711

- ⬜ Tara
- ⬜ Calibração com massa conhecida
- ⬜ Repetibilidade e estabilidade
- ⬜ Limiar de presença / vazio

## E — Buzzer

- ⬜ Desligado no boot
- ⬜ Dois beeps após peso válido
- ⬜ Três beeps em falha
- ⬜ Uma execução por ciclo

## F — Integração

- ⬜ Detecção → posição → parada → peso → buzzer → registro → retirada → liberação
- ⬜ Idempotência `cycle_id` em `POST /pesagens`
- ⬜ Painel `/dashboard/estacao` atualiza status

## G — Falhas

- ⬜ Wi-Fi / MQTT offline (contagem não descartada)
- ⬜ HX711 ausente → FALHA
- ⬜ Peso instável → FALHA
- ⬜ `ack_falha` recupera com segurança
- ⬜ Comando MQTT duplicado não re-dispara buzzer/ciclo

## Compilação (firmware)

Arduino IDE / CLI — placa ESP32 Dev Module. Bibliotecas:

- PubSubClient
- ArduinoJson
- HX711 (bogde)
- Adafruit MLX90614 (+ Adafruit BusIO)

```text
Abrir: firmware/esp32_autcont/esp32_autcont.ino
Copiar secrets.example.h → secrets.h
Gravar no ESP32-D
```
