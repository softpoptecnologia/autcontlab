# Relatório — atualização ESP32 único + HX711 + buzzer

**Branch:** `feature/esp32-autcont-hx711-buzzer`  
**Data:** 2026-10-24  
**Escopo definitivo:** um ESP32-D; sem segundo ESP; sem atuador mecânico.

## 1. Diagnóstico prévio

| Item | Situação encontrada |
|---|---|
| Firmware ativo | `arduinoV4/sensor_e_motor` — DRV8825/A4988, ENABLE GPIO17, microstep 1, sensor RISING |
| TB6600 | Ainda não refletido no código versionado (só na especificação/testes físicos) |
| MLX90614 / HX711 / buzzer | Ausentes no firmware |
| Pesagem no backend | Simulada ao finalizar sessão (`simular_pesagens`) |
| Atuador / ESP8266 / HW-130 | **Não existiam** no repositório (nada a remover de prompts anteriores) |
| MQTT | Prefixo `factory/default/line/1/device/{codigo}/` já em uso |

## 2. Funcionalidades preservadas

- Sessões start/stop via MQTT + Flutter/API
- Contagem HTTP `/leituras`
- Configuração de motor `/motor/config` e tópicos `cmd`/`motor`
- Dashboard AdminLTE (Central, Filtros, Cadastros, Motor)
- Simulação de pesagem (agora **opt-in** via `simular_pesagem: true`)
- Código histórico `arduinoV4/sensor_e_motor`

## 3. Implementado nesta branch

### Firmware `firmware/esp32_autcont/`

- TB6600: microstep 1/8, 30 RPM, sem ENABLE, pulso ativo LOW
- E18: `INPUT_PULLUP` + `FALLING` + fila ISR
- MLX90614 (falha explícita, sem temperatura fictícia)
- HX711: tara, calibração NVS, estabilidade por janela
- Buzzer não bloqueante (sucesso 2× / erro 3×)
- Máquina de estados completa do ciclo
- MQTT: start/stop/config/tara/calibrar/buzzer_config/ack_falha + status/event

### Backend

- `POST /pesagens` idempotente (`sessao_id` + `cycle_id`)
- `GET /estacao/status`, tara/calibrar/buzzer/ack_falha
- `ensure_schema` + `migrations/001_estacao_pesagem.sql`
- `mqtt_worker` grava `dispositivo_status`
- Finalizar sessão agrega pesagens reais; simulação só se pedida

### Interface

- Página `/dashboard/estacao` — ciclo, peso, temps, controles

### Documentação

- `docs/arquitetura.md`, `hardware.md`, `mqtt.md`, `maquina_estados.md`, `testes.md`
- `README.md` na raiz do repo V4

## 4. Arquivos principais

**Novos:** `firmware/esp32_autcont/*`, `docs/*`, `backend/migrations/001_estacao_pesagem.sql`, `backend/templates/dashboard/estacao.html`, `README.md`

**Alterados:** `backend/app.py`, `backend/mqtt_worker.py`, `backend/web_dashboard/routes.py`, `backend/templates/dashboard/base.html`, `backend/schema_extras.sql`, `.gitignore`, cabeçalho histórico do `.ino` antigo

## 5. Validação

| Tipo | Status |
|---|---|
| `py_compile` app/mqtt_worker/routes | OK |
| Compilação Arduino no hardware | **Não executada neste ambiente** |
| Testes físicos motor/sensor/balança/buzzer | **Pendentes** |

## 6. Pendências físicas

1. Confirmar alimentação/nível do módulo HX711  
2. Tipo de buzzer e drive por transistor se necessário  
3. Calibrar fator HX711 e limiares de presença/vazio/estabilidade  
4. Isolar vibração da esteira na célula  
5. Alinhar `API_PORT` do `secrets.h` com a porta real do Flask (padrão código legado 5000; Flask `.env` pode usar 5010)  
6. Rodar checklist em `docs/testes.md` com energia e proteção mecânica  
