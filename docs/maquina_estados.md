# Máquina de estados do ciclo

Estados implementados no firmware `esp32_autcont`:

```text
AGUARDANDO_PRODUTO
PRODUTO_DETECTADO
POSICIONANDO          ← peso ≥ SCALE_PRESENCE_G
ESTEIRA_PARANDO
AGUARDANDO_ESTABILIZACAO
PESANDO               ← janela + tolerância + tempo mínimo
PESO_VALIDADO
BUZZER_CONFIRMADO
REGISTRANDO           ← POST /pesagens
AGUARDANDO_RETIRADA   ← peso ≤ SCALE_EMPTY_G
CICLO_CONCLUIDO
FALHA                 ← exige ack_falha
```

## Critérios verificáveis

| Transição | Critério |
|---|---|
| Posicionado | Leitura HX711 ≥ limiar de presença (não só timeout) |
| Peso válido | Amplitude da janela ≤ tolerância por ≥ `SCALE_STABLE_MS` |
| Retirado | Peso ≤ limiar de vazio |
| Falha | Timeout de posição/pesagem/retirada, HX711 off, API off prolongada |

Um produto por ciclo. Detecções extras ficam na fila ISR (`detectQueue`) e não são descartadas por falha de rede.
