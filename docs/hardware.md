# Hardware — pinagem e ligações

## Controlador

**ESP32-D / ESP32 DevKit** — único microcontrolador da estação.

| Componente | GPIO | Notas |
|---|---|---|
| TB6600 PUL− | 25 | PUL+ → 3V3 (ânodo comum) |
| TB6600 DIR− | 26 | DIR+ → 3V3 |
| TB6600 ENA | — | Desconectado |
| E18-D80NK OUT | 27 | Marrom 5V, Azul GND, Preto GPIO; `INPUT_PULLUP`, `FALLING` |
| MLX90614 SDA | 13 | |
| MLX90614 SCL | 23 | |
| HX711 DT | 32 | Validar VCC 3V3 vs 5V do módulo |
| HX711 SCK | 33 | |
| Buzzer | 18 | Usar transistor se corrente > capacidade do GPIO |

**Não aplicar 12 V nos GPIOs.** TB6600 usa fonte externa 12 V; ESP32 via USB (ou 5 V regulado).

## TB6600 (testado fisicamente)

- NEMA 17, 200 passos/rev, microstep **1/8** → **1600 pulsos/rev**
- DIP unidade testada: SW1 OFF, SW2 ON, SW3 OFF
- Velocidade de referência: **30 RPM**
- Pulso ativo em **LOW** (ânodo comum)
- Corrente SW4–SW6 conforme nominal do motor

## E18-D80NK

- Alimentação 5 V, saída NPN NA, ativo em LOW
- Detecção: HIGH → LOW

## HX711

- Integração no mesmo ESP32 (não há segundo ESP de balança neste escopo)
- Critério de posição na balança: peso ≥ limiar de presença (configurável)
- Estabilidade: janela de amostras + tolerância + tempo mínimo (não usar só `delay`)

## Buzzer

- Substitui o atuador mecânico de expulsão
- Sucesso: 150 ms ON / 150 ms OFF / 150 ms ON
- Erro: três beeps curtos
- Acionamento não bloqueante no firmware

## Pendências de validação física

- Nível lógico / alimentação do módulo HX711 específico
- Tipo de buzzer (ativo/passivo) e necessidade de transistor
- Isolamento mecânico da célula de carga em relação à vibração da esteira
- Limiares `SCALE_PRESENCE_G`, `SCALE_EMPTY_G` e `SCALE_STABILITY_TOL_G` após calibração
