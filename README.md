# AUTCONT Lab

Estação industrial de **transporte → contagem → temperatura → pesagem → confirmação sonora**, com um único **ESP32-D**.

Repositório: [softpoptecnologia/autcontlab](https://github.com/softpoptecnologia/autcontlab)

## Arquitetura atual

- **Firmware:** `firmware/esp32_autcont/` (TB6600 1/8, E18, MLX90614, HX711, buzzer)
- **Histórico:** `arduinoV4/sensor_e_motor/` (DRV8825/A4988 — preservado)
- **Backend:** `backend/` (Flask + MQTT + MySQL)
- **Painel:** `/dashboard/` e `/dashboard/estacao`
- **App:** `contagem_esteiraV3/` (Flutter)

Documentação: `docs/` (`arquitetura`, `hardware`, `mqtt`, `maquina_estados`, `testes`).

## Fora de escopo

Segundo ESP, empurrador DC, HW-130 / L293D / fins de curso.

## Backend (resumo)

```bash
cd backend
python -m venv .venv
# ativar .venv
pip install -r requirements.txt   # se existir
cp .env.example .env              # se existir — configurar MySQL/MQTT
python app.py
python mqtt_worker.py             # em outro terminal
```

Migração SQL opcional: `backend/migrations/001_estacao_pesagem.sql`  
(o `ensure_schema()` do Flask também aplica incrementos ao subir).

## Firmware

1. Copiar `firmware/esp32_autcont/secrets.example.h` → `secrets.h`
2. Ajustar Wi-Fi, MQTT e IP da API
3. Compilar e gravar `esp32_autcont.ino` no ESP32-D

## API nova / estendida

| Método | Rota | Uso |
|---|---|---|
| POST | `/pesagens` | Pesagem real (idempotente por `cycle_id`) |
| GET | `/estacao/status` | Snapshot do ESP |
| POST | `/balanca/tara` | Comando MQTT tara |
| POST | `/balanca/calibrar` | Calibração com massa conhecida |
| POST | `/buzzer/config` | Liga/desliga buzzer |
| POST | `/estacao/ack_falha` | Sai do estado FALHA |

Contratos de sessão, motor e `/leituras` foram preservados.
