# MQTT — contratos AUTCONT

Prefixo (inalterado):

```text
factory/default/line/1/device/esteira1/
```

| Sufixo | Direção | Uso |
|---|---|---|
| `cmd` | Flask → ESP | `start`, `stop`, `config`, `tara`, `calibrar`, `buzzer_config`, `ack_falha` |
| `motor` | Flask → ESP | config de RPM/direção (retain permitido **somente** para config, nunca para movimento de ciclo) |
| `status` | ESP → Flask | `station_status`, LWT online/offline |
| `event` | ESP → Flask | `produto_detectado`, `peso_validado`, `ciclo_concluido`, `cycle_state` |

## Exemplos

**Start de sessão** (já usado pelo backend):

```json
{"action":"start","sessao_id":15,"motor_enabled":true,"rpm":30,"dir":0}
```

**Tara / calibração / buzzer**:

```json
{"action":"tara"}
{"action":"calibrar","peso_conhecido_g":500}
{"action":"buzzer_config","enabled":true}
```

**Evento de peso**:

```json
{
  "type": "peso_validado",
  "action": "peso_validado",
  "sessao_id": 15,
  "produto_id": 125,
  "cycle_id": "15-125",
  "peso_g": 354.8,
  "estavel": true,
  "buzzer_acionado": true
}
```

Persistência oficial da pesagem: **HTTP `POST /pesagens`** (idempotente por `sessao_id` + `cycle_id`).

Comandos com `cmd_id` crescente são ignorados se antigos/duplicados no firmware.
