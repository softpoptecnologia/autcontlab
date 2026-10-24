# mqtt_worker.py — consome event/status do ESP32 AUTCONT
import os, json, signal, sys
from datetime import datetime, timezone
import paho.mqtt.client as mqtt
from dotenv import load_dotenv
from db import one, exec_

load_dotenv()
SITE = os.getenv("SITE", "default")
LINE_ID = os.getenv("LINE_ID", "1")
MQTT_HOST = os.getenv("MQTT_HOST", "127.0.0.1")
MQTT_PORT = int(os.getenv("MQTT_PORT", "1883"))
MQTT_USER = os.getenv("MQTT_USER")
MQTT_PASS = os.getenv("MQTT_PASS")

TOPIC_EVENTS = f"factory/{SITE}/line/{LINE_ID}/device/+/event"
TOPIC_STATUS = f"factory/{SITE}/line/{LINE_ID}/device/+/status"

_cache_disp = {}


def _disp_id(codigo: str):
    if codigo in _cache_disp:
        return _cache_disp[codigo]
    r = one("SELECT id FROM dispositivos WHERE codigo=:c", c=codigo)
    if not r:
        return None
    _cache_disp[codigo] = r["id"]
    return _cache_disp[codigo]


def _now():
    return datetime.now(timezone.utc).replace(tzinfo=None)


def _upsert_status(codigo: str, payload: dict):
    if not isinstance(payload, dict):
        return
    try:
        exec_(
            """
            INSERT INTO dispositivo_status
              (dispositivo_codigo, payload_json, cycle_state, peso_atual_g, ultimo_peso_g,
               peso_acumulado_g, detectados, pesados, hx711_ok, mlx_ok, buzzer_enabled,
               motor_running, rpm, temp_amb, temp_obj, falha, atualizado_em)
            VALUES
              (:c, :pj, :cs, :pa, :up, :pac, :det, :pes, :hx, :mlx, :bz,
               :mr, :rpm, :ta, :to, :falha, :ts)
            ON DUPLICATE KEY UPDATE
              payload_json=VALUES(payload_json),
              cycle_state=VALUES(cycle_state),
              peso_atual_g=VALUES(peso_atual_g),
              ultimo_peso_g=VALUES(ultimo_peso_g),
              peso_acumulado_g=VALUES(peso_acumulado_g),
              detectados=VALUES(detectados),
              pesados=VALUES(pesados),
              hx711_ok=VALUES(hx711_ok),
              mlx_ok=VALUES(mlx_ok),
              buzzer_enabled=VALUES(buzzer_enabled),
              motor_running=VALUES(motor_running),
              rpm=VALUES(rpm),
              temp_amb=VALUES(temp_amb),
              temp_obj=VALUES(temp_obj),
              falha=VALUES(falha),
              atualizado_em=VALUES(atualizado_em)
            """,
            c=codigo,
            pj=json.dumps(payload, ensure_ascii=False),
            cs=payload.get("cycle_state"),
            pa=payload.get("peso_atual_g"),
            up=payload.get("ultimo_peso_g"),
            pac=payload.get("peso_acumulado_g"),
            det=payload.get("detectados"),
            pes=payload.get("pesados"),
            hx=1 if payload.get("hx711_ok") else (0 if "hx711_ok" in payload else None),
            mlx=1 if payload.get("mlx_ok") else (0 if "mlx_ok" in payload else None),
            bz=1 if payload.get("buzzer_enabled") else (0 if "buzzer_enabled" in payload else None),
            mr=1 if payload.get("motor_running") else (0 if "motor_running" in payload else None),
            rpm=payload.get("current_rpm") if payload.get("current_rpm") is not None else payload.get("rpm"),
            ta=payload.get("temp_amb"),
            to=payload.get("temp_obj"),
            falha=(payload.get("falha") or None),
            ts=_now(),
        )
    except Exception as e:
        print("[STATUS] upsert falhou:", e)


def on_connect(client, userdata, flags, rc, properties=None):
    print("[MQTT] conectado rc=", rc)
    client.subscribe(TOPIC_EVENTS, qos=1)
    client.subscribe(TOPIC_STATUS, qos=1)


def on_message(client, userdata, msg):
    topic = msg.topic
    try:
        payload = json.loads(msg.payload.decode("utf-8"))
    except Exception:
        payload = msg.payload.decode("utf-8")

    parts = topic.split("/")
    codigo = parts[6] if len(parts) >= 7 else None
    if not codigo:
        print("[MQTT] tópico inesperado:", topic)
        return

    did = _disp_id(codigo)
    if not did:
        print("[MQTT] dispositivo desconhecido:", codigo)
        return

    if topic.endswith("/event"):
        if not isinstance(payload, dict):
            print("[MQTT] payload inválido em event:", payload)
            return

        t = payload.get("type") or payload.get("action")
        if t == "count_delta":
            sessao_id = payload.get("sessao_id")
            delta = int(payload.get("delta", 0))
            ts = payload.get("ts")
            if not sessao_id or delta == 0:
                return
            try:
                when = (
                    datetime.fromisoformat(ts.replace("Z", ""))
                    if ts else _now()
                )
            except Exception:
                when = _now()
            exec_(
                """
                INSERT INTO leituras (sessao_id, dispositivo_id, timestamp, contagem_incremental, temperatura_c)
                VALUES (:sessao_id, :dispositivo_id, :ts, :delta, NULL)
                """,
                sessao_id=sessao_id,
                dispositivo_id=did,
                ts=when,
                delta=delta,
            )

        elif t in ("peso_validado", "pesagem"):
            # Persistência principal via HTTP /pesagens; aqui só loga
            print("[EVENT] peso_validado", payload.get("cycle_id"), payload.get("peso_g"))

        elif t in ("cycle_state", "produto_detectado", "ciclo_concluido"):
            print("[EVENT]", t, payload.get("cycle_id") or payload.get("state"))

        elif t == "heartbeat":
            pass

        elif t == "summary":
            pass

    elif topic.endswith("/status"):
        if isinstance(payload, dict):
            _upsert_status(codigo, payload)
            st = payload.get("status") or payload.get("type")
            if st in ("offline", "online") or payload.get("type") == "lwt":
                print("[STATUS]", codigo, payload.get("status") or payload.get("cycle_state"))
        else:
            status = str(payload).strip().lower()
            if status in ("offline", "online"):
                print("[STATUS]", f"Dispositivo {codigo} ficou {status}")


def main():
    client = mqtt.Client(client_id="flask-mqtt-consumer", clean_session=True)
    if MQTT_USER:
        client.username_pw_set(MQTT_USER, MQTT_PASS)
    client.on_connect = on_connect
    client.on_message = on_message
    client.connect(MQTT_HOST, MQTT_PORT, 30)

    def _sig(*args):
        client.disconnect()
        sys.exit(0)

    signal.signal(signal.SIGINT, _sig)
    signal.signal(signal.SIGTERM, _sig)
    client.loop_forever()


if __name__ == "__main__":
    main()
