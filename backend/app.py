# app.py
import os, json, logging, random, threading, time
from datetime import datetime, timezone
from flask import Flask, request, jsonify, redirect
from flask_cors import CORS
from dotenv import load_dotenv
import paho.mqtt.client as mqtt
from sqlalchemy.exc import OperationalError
from db import one, all_, exec_, engine
from sqlalchemy import text

load_dotenv()

# ====================================================
# 🔧 CONFIGURAÇÃO PRINCIPAL
# ====================================================
SITE = os.getenv("SITE", "default")
LINE_ID = os.getenv("LINE_ID", "1")
FLASK_HOST = os.getenv("FLASK_HOST", "0.0.0.0")
FLASK_PORT = int(os.getenv("FLASK_PORT", "5010"))
FLASK_DEBUG = os.getenv("FLASK_DEBUG", "false").lower() == "true"

MQTT_HOST = os.getenv("MQTT_HOST", "127.0.0.1")
MQTT_PORT = int(os.getenv("MQTT_PORT", "1883"))
MQTT_USER = os.getenv("MQTT_USER")
MQTT_PASS = os.getenv("MQTT_PASS")

# Peso unitário de referência padrão (g) para simulação da esteira de peso
PESO_UNITARIO_DEFAULT_G = float(os.getenv("PESO_UNITARIO_DEFAULT_G", "350"))
PESO_TOLERANCIA_PCT = float(os.getenv("PESO_TOLERANCIA_PCT", "0.04"))

# ====================================================
# 🚀 FLASK APP
# ====================================================
app = Flask(__name__)
CORS(
    app,
    resources={r"/*": {"origins": "*"}},
    supports_credentials=False,
    allow_headers=["Content-Type", "Authorization", "Accept"],
    methods=["GET", "POST", "PUT", "PATCH", "DELETE", "OPTIONS"],
)

try:
    from web_dashboard.routes import dashboard_bp
    app.register_blueprint(dashboard_bp)
except ImportError:
    print("⚠️  Blueprint do dashboard não encontrado (opcional).")

logging.basicConfig(
    level=logging.INFO if not FLASK_DEBUG else logging.DEBUG,
    format="%(asctime)s [%(levelname)s] %(message)s",
)
log = logging.getLogger("app")

# ====================================================
# 📡 MQTT CLIENT (PUBLICADOR)
# ====================================================
mqttc = mqtt.Client(client_id=f"flask-api-pub-{os.getpid()}", clean_session=True)
if MQTT_USER:
    mqttc.username_pw_set(MQTT_USER, MQTT_PASS)
mqttc.reconnect_delay_set(min_delay=1, max_delay=15)


def _on_mqtt_connect(client, userdata, flags, rc):
    if rc == 0:
        log.info("MQTT conectado em %s:%s", MQTT_HOST, MQTT_PORT)
        try:
            _republish_motor_configs()
        except Exception as e:
            log.warning("Falha ao reenviar config do motor no MQTT: %s", e)
    else:
        log.warning("MQTT recusou conexão rc=%s em %s:%s", rc, MQTT_HOST, MQTT_PORT)


def _on_mqtt_disconnect(client, userdata, rc):
    log.warning("MQTT desconectado rc=%s — reconectando", rc)


mqttc.on_connect = _on_mqtt_connect
mqttc.on_disconnect = _on_mqtt_disconnect


def mqtt_connected() -> bool:
    try:
        return bool(mqttc.is_connected())
    except Exception:
        return False


def _mqtt_connect_bg():
    """Mantém o Flask ligado ao Mosquitto local, sem travar o boot da API."""
    mqttc.loop_start()
    while True:
        if mqtt_connected():
            time.sleep(5)
            continue
        try:
            mqttc.connect(MQTT_HOST, MQTT_PORT, 20)
        except Exception as e:
            log.warning(
                "MQTT sem conexão em %s:%s (%s). Nova tentativa em 3s.",
                MQTT_HOST, MQTT_PORT, e,
            )
        time.sleep(3)

# Padrões de fábrica do motor (espelham o firmware em arduinoV4/sensor_e_motor.ino)
MOTOR_DEFAULTS = {
    "rpm": 50,
    "dir": 0,              # 0 = DIR LOW (padrão do firmware), 1 = DIR HIGH
    "hold": False,         # A4988: ENABLE só em movimento, como o original
    "min_half_us": 200,    # original era ~3 µs; 400 µs engasgava o motor
    "torque": 80,          # rampa curta (o original arrancava direto em 50 RPM)
    "motor_enabled": False,  # ESP não gira sozinho; painel/sessão ligam
}
MOTOR_RPM_MIN, MOTOR_RPM_MAX = 5, 200
MOTOR_PULSE_MIN, MOTOR_PULSE_MAX = 50, 2000
MOTOR_TORQUE_MIN, MOTOR_TORQUE_MAX = 10, 100


def publish_cmd(dispositivo_codigo, action_or_dict, retain=False, topic_suffix="cmd"):
    """Publica comandos MQTT para os dispositivos (não bloqueia se o broker estiver offline)."""
    topic = f"factory/default/line/1/device/{dispositivo_codigo}/{topic_suffix}"

    if isinstance(action_or_dict, dict):
        payload = json.dumps(action_or_dict)
    else:
        payload = json.dumps({"action": action_or_dict})

    print(f"[MQTT] Publicando em {topic}: {payload}")
    if not mqtt_connected():
        try:
            mqttc.connect(MQTT_HOST, MQTT_PORT, 10)
        except Exception as e:
            log.warning("MQTT offline em %s:%s (%s)", MQTT_HOST, MQTT_PORT, e)
            return False
    try:
        info = mqttc.publish(topic, payload, qos=1, retain=retain)
        if getattr(info, "rc", 1) == mqtt.MQTT_ERR_SUCCESS:
            return True
        log.warning("MQTT não publicou (rc=%s). Broker offline?", getattr(info, "rc", None))
        return False
    except Exception as e:
        log.warning("Falha ao publicar MQTT: %s", e)
        return False

# ====================================================
# 🕒 UTIL
# ====================================================
def now_utc_naive():
    return datetime.now(timezone.utc).replace(tzinfo=None)


def _as_bool(value, default=True) -> bool:
    if value is None:
        return default
    if isinstance(value, bool):
        return value
    if isinstance(value, (int, float)):
        return bool(int(value))
    return str(value).strip().lower() in ("1", "true", "on", "sim", "yes")


def _clamp_int(value, lo, hi, default) -> int:
    try:
        n = int(value)
    except (TypeError, ValueError):
        return default
    return max(lo, min(hi, n))


def motor_row_to_config(row: dict | None) -> dict:
    if not row:
        return dict(MOTOR_DEFAULTS)
    return {
        "rpm": int(row.get("rpm") or MOTOR_DEFAULTS["rpm"]),
        "dir": 1 if int(row.get("direcao") or 0) else 0,
        "hold": bool(int(row.get("hold") if row.get("hold") is not None else 1)),
        "min_half_us": int(row.get("min_half_us") or MOTOR_DEFAULTS["min_half_us"]),
        "torque": int(row.get("torque") or MOTOR_DEFAULTS["torque"]),
        "motor_enabled": bool(int(row.get("motor_enabled") if row.get("motor_enabled") is not None else 1)),
    }


def _config_is_default(cfg: dict) -> bool:
    return all(cfg.get(k) == MOTOR_DEFAULTS[k] for k in MOTOR_DEFAULTS)


def load_motor_config(dispositivo_codigo: str) -> dict:
    try:
        row = one(
            "SELECT * FROM configuracao_motor WHERE dispositivo_codigo=:c",
            c=dispositivo_codigo,
        )
    except Exception as e:
        log.warning("load_motor_config: %s", e)
        row = None
    return motor_row_to_config(row)


def save_motor_config(dispositivo_codigo: str, cfg: dict) -> dict:
    if not _table_exists("configuracao_motor"):
        ensure_schema()
    params = dict(
        c=dispositivo_codigo,
        rpm=cfg["rpm"],
        dir=cfg["dir"],
        hold=1 if cfg["hold"] else 0,
        min_us=cfg["min_half_us"],
        torque=cfg.get("torque", MOTOR_DEFAULTS["torque"]),
        mot=1 if cfg["motor_enabled"] else 0,
        ts=now_utc_naive(),
    )
    try:
        exec_(
            """
            INSERT INTO configuracao_motor
                (dispositivo_codigo, rpm, direcao, hold, min_half_us, torque, motor_enabled, atualizado_em)
            VALUES
                (:c, :rpm, :dir, :hold, :min_us, :torque, :mot, :ts)
            ON DUPLICATE KEY UPDATE
                rpm=VALUES(rpm),
                direcao=VALUES(direcao),
                hold=VALUES(hold),
                min_half_us=VALUES(min_half_us),
                torque=VALUES(torque),
                motor_enabled=VALUES(motor_enabled),
                atualizado_em=VALUES(atualizado_em)
            """,
            **params,
        )
    except Exception as e:
        log.warning("save_motor_config com torque falhou (%s); tentando sem a coluna", e)
        exec_(
            """
            INSERT INTO configuracao_motor
                (dispositivo_codigo, rpm, direcao, hold, min_half_us, motor_enabled, atualizado_em)
            VALUES
                (:c, :rpm, :dir, :hold, :min_us, :mot, :ts)
            ON DUPLICATE KEY UPDATE
                rpm=VALUES(rpm),
                direcao=VALUES(direcao),
                hold=VALUES(hold),
                min_half_us=VALUES(min_half_us),
                motor_enabled=VALUES(motor_enabled),
                atualizado_em=VALUES(atualizado_em)
            """,
            c=params["c"],
            rpm=params["rpm"],
            dir=params["dir"],
            hold=params["hold"],
            min_us=params["min_us"],
            mot=params["mot"],
            ts=params["ts"],
        )
    return cfg


def merge_motor_payload(current: dict, data: dict) -> dict:
    cfg = dict(current)
    if "rpm" in data and data["rpm"] is not None:
        cfg["rpm"] = _clamp_int(data["rpm"], MOTOR_RPM_MIN, MOTOR_RPM_MAX, current["rpm"])
    if "dir" in data and data["dir"] is not None:
        cfg["dir"] = 1 if int(data["dir"]) else 0
    if "hold" in data and data["hold"] is not None:
        cfg["hold"] = _as_bool(data["hold"], current["hold"])
    if "min_half_us" in data and data["min_half_us"] is not None:
        cfg["min_half_us"] = _clamp_int(
            data["min_half_us"], MOTOR_PULSE_MIN, MOTOR_PULSE_MAX, current["min_half_us"]
        )
    if "motor_enabled" in data and data["motor_enabled"] is not None:
        cfg["motor_enabled"] = _as_bool(data["motor_enabled"], current["motor_enabled"])
    if "torque" in data and data["torque"] is not None:
        cfg["torque"] = _clamp_int(
            data["torque"], MOTOR_TORQUE_MIN, MOTOR_TORQUE_MAX, current.get("torque", 90)
        )
    return cfg


def motor_mqtt_payload(cfg: dict, reset=False) -> dict:
    return {
        "action": "reset_config" if reset else "config",
        "rpm": int(cfg["rpm"]),
        "dir": int(cfg["dir"]),
        "hold": bool(cfg["hold"]),
        "min_half_us": int(cfg["min_half_us"]),
        "torque": int(cfg.get("torque", MOTOR_DEFAULTS["torque"])),
        "motor_enabled": bool(cfg["motor_enabled"]),
    }


def publish_motor_config(dispositivo_codigo: str, cfg: dict, reset=False):
    payload = motor_mqtt_payload(cfg, reset)
    ok_motor = publish_cmd(dispositivo_codigo, payload, retain=True, topic_suffix="motor")
    ok_cmd = publish_cmd(dispositivo_codigo, payload, retain=False, topic_suffix="cmd")
    return bool(ok_motor or ok_cmd), payload


def publish_esteira_sessao(dispositivo_codigo: str, action: str, sessao_id: int) -> bool:
    """Liga/desliga o motor junto com start/stop da sessão (app Flutter)."""
    motor_on = action == "start"
    cfg = load_motor_config(dispositivo_codigo)
    cfg["motor_enabled"] = motor_on
    start_payload = {
        "action": action,
        "sessao_id": sessao_id,
        "motor_enabled": motor_on,
        "rpm": cfg["rpm"],
        "dir": cfg["dir"],
        "hold": cfg["hold"],
        "min_half_us": cfg["min_half_us"],
        "torque": int(cfg.get("torque", MOTOR_DEFAULTS["torque"])),
    }
    ok_cmd = publish_cmd(
        dispositivo_codigo,
        start_payload,
        retain=False,
        topic_suffix="cmd",
    )
    try:
        save_motor_config(dispositivo_codigo, cfg)
    except Exception as e:
        log.warning("não persistiu motor_enabled na sessão: %s", e)
    ok_motor = publish_cmd(
        dispositivo_codigo,
        motor_mqtt_payload(cfg, reset=False),
        retain=True,
        topic_suffix="motor",
    )
    return bool(ok_cmd or ok_motor)


def _republish_motor_configs():
    try:
        if not _table_exists("configuracao_motor"):
            return
        rows = all_("SELECT * FROM configuracao_motor")
    except Exception:
        return
    for row in rows or []:
        codigo = (row.get("dispositivo_codigo") or "").strip()
        if not codigo:
            continue
        publish_motor_config(codigo, motor_row_to_config(row), reset=False)


def _column_exists(table: str, column: str) -> bool:
    row = one(
        """
        SELECT COUNT(*) AS n
        FROM information_schema.COLUMNS
        WHERE TABLE_SCHEMA = DATABASE()
          AND TABLE_NAME = :t
          AND COLUMN_NAME = :c
        """,
        t=table,
        c=column,
    )
    return bool(row and row.get("n"))


def _table_exists(table: str) -> bool:
    row = one(
        """
        SELECT COUNT(*) AS n
        FROM information_schema.TABLES
        WHERE TABLE_SCHEMA = DATABASE()
          AND TABLE_NAME = :t
        """,
        t=table,
    )
    return bool(row and row.get("n"))


def ensure_schema():
    """Garante colunas/tabelas de pesagem sem quebrar bases antigas."""
    alters = [
        ("sessoes_producao", "peso_total_g",
         "ALTER TABLE sessoes_producao ADD COLUMN peso_total_g DECIMAL(12,2) NULL"),
        ("sessoes_producao", "peso_medio_g",
         "ALTER TABLE sessoes_producao ADD COLUMN peso_medio_g DECIMAL(12,3) NULL"),
        ("sessoes_producao", "pesagem_status",
         "ALTER TABLE sessoes_producao ADD COLUMN pesagem_status VARCHAR(32) NULL DEFAULT 'pendente'"),
        ("sessoes_producao", "pesagem_em",
         "ALTER TABLE sessoes_producao ADD COLUMN pesagem_em DATETIME NULL"),
        ("sessoes_producao", "peso_unitario_ref_g",
         "ALTER TABLE sessoes_producao ADD COLUMN peso_unitario_ref_g DECIMAL(12,3) NULL"),
    ]
    for table, col, sql in alters:
        try:
            if not _column_exists(table, col):
                exec_(sql)
                log.info("Schema: adicionada coluna %s.%s", table, col)
        except Exception as e:
            log.warning("Schema skip %s.%s: %s", table, col, e)

    if not _table_exists("pesagens"):
        try:
            exec_(
                """
                CREATE TABLE pesagens (
                  id BIGINT AUTO_INCREMENT PRIMARY KEY,
                  sessao_id INT NOT NULL,
                  item_seq INT NOT NULL,
                  peso_g DECIMAL(12,3) NOT NULL,
                  simulado TINYINT(1) NOT NULL DEFAULT 1,
                  criado_em DATETIME NOT NULL,
                  INDEX idx_pesagens_sessao (sessao_id)
                )
                """
            )
            log.info("Schema: tabela pesagens criada")
        except Exception as e:
            log.warning("Schema skip pesagens: %s", e)

    try:
        with engine.begin() as c:
            # View sem depender de colunas de temperatura (bases antigas)
            c.execute(text("""
                CREATE OR REPLACE VIEW vw_totais_sessao AS
                SELECT s.id AS sessao_id,
                       COALESCE(SUM(l.contagem_incremental), 0) AS total
                FROM sessoes_producao s
                LEFT JOIN leituras l ON l.sessao_id = s.id
                GROUP BY s.id
            """))
    except Exception as e:
        log.warning("Schema view: %s", e)

    # Tenta enriquecer a view com médias de temperatura (opcional)
    try:
        if _column_exists("leituras", "temp_amb"):
            with engine.begin() as c:
                c.execute(text("""
                    CREATE OR REPLACE VIEW vw_totais_sessao AS
                    SELECT s.id AS sessao_id,
                           COALESCE(SUM(l.contagem_incremental), 0) AS total,
                           COALESCE(AVG(l.temp_amb), 0) AS avg_temp_amb,
                           COALESCE(AVG(l.temp_obj), 0) AS avg_temp_obj
                    FROM sessoes_producao s
                    LEFT JOIN leituras l ON l.sessao_id = s.id
                    GROUP BY s.id
                """))
    except Exception as e:
        log.warning("Schema view temps: %s", e)

    if not _table_exists("configuracao_motor"):
        try:
            exec_(
                """
                CREATE TABLE configuracao_motor (
                  dispositivo_codigo VARCHAR(64) NOT NULL PRIMARY KEY,
                  rpm INT NOT NULL,
                  direcao TINYINT(1) NOT NULL DEFAULT 0,
                  hold TINYINT(1) NOT NULL DEFAULT 1,
                  min_half_us INT NOT NULL DEFAULT 400,
                  torque INT NOT NULL DEFAULT 90,
                  motor_enabled TINYINT(1) NOT NULL DEFAULT 1,
                  atualizado_em DATETIME NOT NULL
                )
                """
            )
            log.info("Schema: tabela configuracao_motor criada")
        except Exception as e:
            log.warning("Schema skip configuracao_motor: %s", e)

    try:
        if _table_exists("configuracao_motor") and not _column_exists("configuracao_motor", "torque"):
            exec_("ALTER TABLE configuracao_motor ADD COLUMN torque INT NOT NULL DEFAULT 90")
            log.info("Schema: coluna configuracao_motor.torque")
    except Exception as e:
        log.warning("Schema skip torque: %s", e)


def _sessao_select_sql():
    """SELECT de sessão com fallback se colunas de peso não existirem."""
    has_peso = _column_exists("sessoes_producao", "peso_total_g")
    if has_peso:
        return """
            SELECT s.id, s.cliente_id, s.produto_id, s.lote, s.operador_id,
                   s.inicio, s.fim, s.status, COALESCE(v.total,0) AS total,
                   c.nome AS cliente, p.nome AS produto,
                   s.peso_total_g, s.peso_medio_g, s.pesagem_status,
                   s.pesagem_em, s.peso_unitario_ref_g
            FROM sessoes_producao s
            LEFT JOIN vw_totais_sessao v ON v.sessao_id = s.id
            LEFT JOIN clientes c ON c.id = s.cliente_id
            LEFT JOIN produtos p ON p.id = s.produto_id
            WHERE s.id=:id
        """
    return """
        SELECT s.id, s.cliente_id, s.produto_id, s.lote, s.operador_id,
               s.inicio, s.fim, s.status, COALESCE(v.total,0) AS total,
               c.nome AS cliente, p.nome AS produto
        FROM sessoes_producao s
        LEFT JOIN vw_totais_sessao v ON v.sessao_id = s.id
        LEFT JOIN clientes c ON c.id = s.cliente_id
        LEFT JOIN produtos p ON p.id = s.produto_id
        WHERE s.id=:id
    """


def _build_sessoes_filters():
    """Filtros compartilhados para listagem de sessões."""
    cliente_id = request.args.get("cliente_id", type=int)
    produto_id = request.args.get("produto_id", type=int)
    status = request.args.get("status")
    lote = (request.args.get("lote") or "").strip()
    q = (request.args.get("q") or "").strip()
    inicio_de = request.args.get("inicio_de")
    inicio_ate = request.args.get("inicio_ate")
    pesagem_status = request.args.get("pesagem_status")

    where = ["1=1"]
    params = {}

    if cliente_id:
        where.append("s.cliente_id = :cliente_id")
        params["cliente_id"] = cliente_id
    if produto_id:
        where.append("s.produto_id = :produto_id")
        params["produto_id"] = produto_id
    if status:
        where.append("s.status = :status")
        params["status"] = status
    if lote:
        where.append("s.lote LIKE :lote")
        params["lote"] = f"%{lote}%"
    if q:
        where.append(
            "(c.nome LIKE :q OR p.nome LIKE :q OR s.lote LIKE :q OR CAST(s.id AS CHAR) LIKE :q)"
        )
        params["q"] = f"%{q}%"
    if inicio_de:
        where.append("DATE(s.inicio) >= :inicio_de")
        params["inicio_de"] = inicio_de
    if inicio_ate:
        where.append("DATE(s.inicio) <= :inicio_ate")
        params["inicio_ate"] = inicio_ate
    if pesagem_status and _column_exists("sessoes_producao", "pesagem_status"):
        where.append("COALESCE(s.pesagem_status,'pendente') = :pesagem_status")
        params["pesagem_status"] = pesagem_status

    return " AND ".join(where), params


def simular_pesagens(sessao_id: int, peso_ref_g: float | None = None, seed: int | None = None):
    """Simula a esteira de peso: um peso por unidade contada."""
    tot = one(
        """
        SELECT COALESCE(v.total,0) AS total
        FROM sessoes_producao s
        LEFT JOIN vw_totais_sessao v ON v.sessao_id = s.id
        WHERE s.id=:id
        """,
        id=sessao_id,
    )
    if not tot:
        return None
    n = int(tot["total"] or 0)
    if n <= 0:
        exec_(
            """
            UPDATE sessoes_producao
            SET pesagem_status='concluida', peso_total_g=0, peso_medio_g=0,
                pesagem_em=:ts, peso_unitario_ref_g=:ref
            WHERE id=:id
            """,
            ts=now_utc_naive(),
            ref=peso_ref_g or PESO_UNITARIO_DEFAULT_G,
            id=sessao_id,
        )
        return {"sessao_id": sessao_id, "itens": 0, "peso_total_g": 0, "peso_medio_g": 0, "pesagens": []}

    ref = float(peso_ref_g or PESO_UNITARIO_DEFAULT_G)
    rng = random.Random(seed if seed is not None else sessao_id)
    pesos = []
    for i in range(1, n + 1):
        delta = rng.uniform(-PESO_TOLERANCIA_PCT, PESO_TOLERANCIA_PCT)
        peso = round(ref * (1.0 + delta), 3)
        pesos.append(peso)

    # limpa pesagens anteriores da sessão
    try:
        exec_("DELETE FROM pesagens WHERE sessao_id=:id", id=sessao_id)
    except Exception:
        pass

    ts = now_utc_naive()
    for i, peso in enumerate(pesos, start=1):
        exec_(
            """
            INSERT INTO pesagens (sessao_id, item_seq, peso_g, simulado, criado_em)
            VALUES (:sessao_id, :item_seq, :peso_g, 1, :ts)
            """,
            sessao_id=sessao_id,
            item_seq=i,
            peso_g=peso,
            ts=ts,
        )

    total_g = round(sum(pesos), 2)
    medio_g = round(total_g / n, 3)
    exec_(
        """
        UPDATE sessoes_producao
        SET peso_total_g=:total, peso_medio_g=:medio, pesagem_status='concluida',
            pesagem_em=:ts, peso_unitario_ref_g=:ref
        WHERE id=:id
        """,
        total=total_g,
        medio=medio_g,
        ts=ts,
        ref=ref,
        id=sessao_id,
    )
    return {
        "sessao_id": sessao_id,
        "itens": n,
        "peso_total_g": total_g,
        "peso_medio_g": medio_g,
        "peso_unitario_ref_g": ref,
        "simulado": True,
        "pesagens": [
            {"item_seq": i, "peso_g": p} for i, p in enumerate(pesos, start=1)
        ],
    }


# Bootstrap schema
try:
    ensure_schema()
except Exception as e:
    log.warning("ensure_schema falhou: %s", e)

threading.Thread(target=_mqtt_connect_bg, name="mqtt-connect", daemon=True).start()

# ====================================================
# 🩺 HEALTHCHECK + INDEX
# ====================================================
@app.get("/")
def root_index():
    """Painel industrial na raiz."""
    return redirect("/dashboard/")


@app.after_request
def _ensure_cors(resp):
    resp.headers.setdefault("Access-Control-Allow-Origin", "*")
    resp.headers.setdefault(
        "Access-Control-Allow-Headers", "Content-Type, Authorization, Accept"
    )
    resp.headers.setdefault(
        "Access-Control-Allow-Methods", "GET, POST, PUT, PATCH, DELETE, OPTIONS"
    )
    return resp

@app.get("/health")
def health():
    return jsonify({
        "ok": True,
        "mysql_db": os.getenv("MYSQL_DB"),
        "mqtt_host": MQTT_HOST,
        "mqtt_port": MQTT_PORT,
        "mqtt_connected": mqtt_connected(),
    })

# ====================================================
# 📋 LISTAGENS
# ====================================================
@app.get("/clientes")
def listar_clientes():
    rows = all_("SELECT id, nome FROM clientes ORDER BY nome ASC")
    return jsonify(rows)

@app.get("/produtos")
def listar_produtos():
    rows = all_("SELECT id, nome FROM produtos ORDER BY nome ASC")
    return jsonify(rows)

@app.get("/dispositivos")
def listar_dispositivos():
    rows = all_("SELECT id, codigo, COALESCE(descricao,'') AS descricao FROM dispositivos ORDER BY codigo ASC")
    return jsonify(rows)


def _motor_dispositivo(data=None) -> str:
    src = data if isinstance(data, dict) else {}
    codigo = (
        (src.get("dispositivo_codigo") or src.get("device_code") or request.args.get("dispositivo_codigo") or "")
        .strip()
    )
    if not codigo:
        first = one("SELECT codigo FROM dispositivos ORDER BY codigo ASC LIMIT 1")
        codigo = (first or {}).get("codigo") or "esteira1"
    return codigo


def _motor_response(dispositivo_codigo: str, cfg: dict, mqtt_ok=None, mqtt_payload=None, save_warning=None):
    out = {
        "dispositivo_codigo": dispositivo_codigo,
        "current": cfg,
        "defaults": dict(MOTOR_DEFAULTS),
        "is_default": _config_is_default(cfg),
        "limits": {
            "rpm": [MOTOR_RPM_MIN, MOTOR_RPM_MAX],
            "min_half_us": [MOTOR_PULSE_MIN, MOTOR_PULSE_MAX],
            "torque": [MOTOR_TORQUE_MIN, MOTOR_TORQUE_MAX],
        },
        "mqtt_ok": mqtt_ok if mqtt_ok is not None else mqtt_connected(),
        "mqtt_connected": mqtt_connected(),
        "mqtt_host": MQTT_HOST,
        "mqtt_port": MQTT_PORT,
        "mqtt_topics": [
            f"factory/default/line/1/device/{dispositivo_codigo}/motor",
            f"factory/default/line/1/device/{dispositivo_codigo}/cmd",
        ],
    }
    if mqtt_payload is not None:
        out["mqtt_payload"] = mqtt_payload
    if save_warning:
        out["save_warning"] = save_warning
    return out


@app.get("/motor/config")
def obter_motor_config():
    codigo = _motor_dispositivo()
    cfg = load_motor_config(codigo)
    return jsonify(_motor_response(codigo, cfg))


@app.put("/motor/config")
@app.post("/motor/config")
def atualizar_motor_config():
    data = request.get_json(silent=True) or {}
    codigo = _motor_dispositivo(data)
    current = load_motor_config(codigo)
    cfg = merge_motor_payload(current, data)
    save_warning = None
    try:
        save_motor_config(codigo, cfg)
    except Exception as e:
        save_warning = str(e)
        log.warning("save_motor_config: %s — MQTT segue mesmo assim", e)
    mqtt_ok, payload = publish_motor_config(codigo, cfg, reset=False)
    return jsonify(_motor_response(
        codigo, cfg, mqtt_ok=mqtt_ok, mqtt_payload=payload, save_warning=save_warning
    ))


@app.post("/motor/config/reset")
def resetar_motor_config():
    data = request.get_json(silent=True) or {}
    codigo = _motor_dispositivo(data)
    cfg = dict(MOTOR_DEFAULTS)
    save_warning = None
    try:
        save_motor_config(codigo, cfg)
    except Exception as e:
        save_warning = str(e)
        log.warning("save_motor_config reset: %s — MQTT segue mesmo assim", e)
    mqtt_ok, payload = publish_motor_config(codigo, cfg, reset=True)
    return jsonify(_motor_response(
        codigo, cfg, mqtt_ok=mqtt_ok, mqtt_payload=payload, save_warning=save_warning
    ))


@app.get("/lotes")
def listar_lotes():
    """Sugestões de lote (autocomplete) por cliente/produto."""
    cliente_id = request.args.get("cliente_id", type=int)
    produto_id = request.args.get("produto_id", type=int)
    q = (request.args.get("q") or "").strip()
    limit = min(50, max(1, int(request.args.get("limit", "20"))))

    where = ["s.lote IS NOT NULL", "TRIM(s.lote) <> ''"]
    params = {"lim": limit}

    if cliente_id:
        where.append("s.cliente_id = :cliente_id")
        params["cliente_id"] = cliente_id
    if produto_id:
        where.append("s.produto_id = :produto_id")
        params["produto_id"] = produto_id
    if q:
        where.append("s.lote LIKE :q")
        params["q"] = f"%{q}%"

    sql = f"""
        SELECT s.lote,
               COUNT(*) AS usos,
               MAX(s.inicio) AS ultimo_uso,
               MAX(s.id) AS ultima_sessao_id
        FROM sessoes_producao s
        WHERE {' AND '.join(where)}
        GROUP BY s.lote
        ORDER BY ultimo_uso DESC
        LIMIT :lim
    """
    rows = all_(sql, **params)

    # Sugere próximo lote automático (ex.: L1 -> L2) a partir do mais recente
    sugestao = None
    if rows:
        ultimo = (rows[0].get("lote") or "").strip()
        sugestao = _sugerir_proximo_lote(ultimo)
    elif cliente_id or produto_id:
        sugestao = "L1"

    return jsonify({
        "lotes": rows,
        "sugestao": sugestao,
        "peso_unitario_default_g": PESO_UNITARIO_DEFAULT_G,
    })


def _sugerir_proximo_lote(ultimo: str) -> str:
    import re
    m = re.match(r"^(.*?)(\d+)$", ultimo)
    if m:
        prefix, num = m.group(1), m.group(2)
        nxt = int(num) + 1
        return f"{prefix}{str(nxt).zfill(len(num))}"
    return f"{ultimo}-2" if ultimo else "L1"

# ====================================================
# ⚙️ SESSÕES DE PRODUÇÃO
# ====================================================
@app.post("/sessoes")
def criar_sessao():
    data = request.get_json(force=True)
    required = ["cliente_id", "produto_id", "operador_id", "dispositivo_codigo"]
    missing = [k for k in required if k not in data]
    if missing:
        return jsonify({"error": f"Campos obrigatórios faltando: {', '.join(missing)}"}), 400

    cliente_id = int(data["cliente_id"])
    produto_id = int(data["produto_id"])
    operador_id = int(data["operador_id"])
    lote = (data.get("lote") or "default").strip()[:255]
    dispositivo_codigo = (data["dispositivo_codigo"] or "").strip()
    peso_ref = data.get("peso_unitario_ref_g")

    disp = one("SELECT id FROM dispositivos WHERE codigo=:c", c=dispositivo_codigo)
    if not disp:
        return jsonify({"error": "dispositivo_codigo inválido"}), 400

    # Se lote vazio, tenta sugerir automaticamente
    if not lote or lote == "default":
        sug = listar_lotes_auto(cliente_id, produto_id)
        lote = sug or "L1"

    cols = "cliente_id, produto_id, lote, operador_id, inicio, status"
    vals = ":cliente_id, :produto_id, :lote, :operador_id, :inicio, 'ativa'"
    params = dict(
        cliente_id=cliente_id,
        produto_id=produto_id,
        lote=lote,
        operador_id=operador_id,
        inicio=now_utc_naive(),
    )

    if _column_exists("sessoes_producao", "pesagem_status"):
        cols += ", pesagem_status, peso_unitario_ref_g"
        vals += ", 'pendente', :peso_ref"
        params["peso_ref"] = float(peso_ref) if peso_ref is not None else PESO_UNITARIO_DEFAULT_G

    sessao_id = exec_(
        f"INSERT INTO sessoes_producao ({cols}) VALUES ({vals})",
        **params,
    )

    mqtt_ok = publish_esteira_sessao(dispositivo_codigo, "start", sessao_id)
    if not mqtt_ok:
        log.warning("Sessão %s criada, mas MQTT não ligou o motor (%s)", sessao_id, dispositivo_codigo)
    return jsonify({"sessao_id": sessao_id, "lote": lote, "mqtt_ok": mqtt_ok}), 201


def listar_lotes_auto(cliente_id: int | None, produto_id: int | None) -> str | None:
    where = ["s.lote IS NOT NULL", "TRIM(s.lote) <> ''"]
    params = {}
    if cliente_id:
        where.append("s.cliente_id = :cliente_id")
        params["cliente_id"] = cliente_id
    if produto_id:
        where.append("s.produto_id = :produto_id")
        params["produto_id"] = produto_id
    row = one(
        f"""
        SELECT s.lote FROM sessoes_producao s
        WHERE {' AND '.join(where)}
        ORDER BY s.id DESC LIMIT 1
        """,
        **params,
    )
    if not row:
        return "L1"
    return _sugerir_proximo_lote((row.get("lote") or "").strip())


@app.post("/sessoes/<int:sessao_id>/finalizar")
def finalizar_sessao(sessao_id: int):
    data = request.get_json(force=True) if request.data else {}
    dispositivo_codigo = (data.get("dispositivo_codigo") or "").strip()
    if not dispositivo_codigo:
        return jsonify({"error": "dispositivo_codigo obrigatório"}), 400

    simular = data.get("simular_pesagem", True)
    peso_ref = data.get("peso_unitario_ref_g")

    exec_("UPDATE sessoes_producao SET fim=:fim, status='finalizada' WHERE id=:id",
          fim=now_utc_naive(), id=sessao_id)

    mqtt_ok = publish_esteira_sessao(dispositivo_codigo, "stop", sessao_id)

    pesagem = None
    if simular and _column_exists("sessoes_producao", "pesagem_status"):
        try:
            exec_(
                "UPDATE sessoes_producao SET pesagem_status='em_andamento' WHERE id=:id",
                id=sessao_id,
            )
            pesagem = simular_pesagens(sessao_id, peso_ref_g=peso_ref)
        except Exception as e:
            log.warning("Simulação de pesagem falhou: %s", e)

    return jsonify({"ok": True, "pesagem": pesagem, "mqtt_ok": mqtt_ok})


@app.post("/sessoes/<int:sessao_id>/pesagem/simular")
def api_simular_pesagem(sessao_id: int):
    """Simula a esteira de peso após a contagem (protótipo)."""
    s = one("SELECT id, status FROM sessoes_producao WHERE id=:id", id=sessao_id)
    if not s:
        return jsonify({"error": "not found"}), 404

    data = request.get_json(silent=True) or {}
    peso_ref = data.get("peso_unitario_ref_g")
    seed = data.get("seed")

    try:
        exec_(
            "UPDATE sessoes_producao SET pesagem_status='em_andamento' WHERE id=:id",
            id=sessao_id,
        )
    except Exception:
        pass

    result = simular_pesagens(sessao_id, peso_ref_g=peso_ref, seed=seed)
    if result is None:
        return jsonify({"error": "sessão inválida"}), 404
    return jsonify(result)


@app.get("/sessoes/<int:sessao_id>/pesagens")
def listar_pesagens(sessao_id: int):
    s = one("SELECT id FROM sessoes_producao WHERE id=:id", id=sessao_id)
    if not s:
        return jsonify({"error": "not found"}), 404
    try:
        rows = all_(
            """
            SELECT item_seq, peso_g, simulado, criado_em
            FROM pesagens WHERE sessao_id=:id
            ORDER BY item_seq ASC
            """,
            id=sessao_id,
        )
    except Exception:
        rows = []
    return jsonify({"sessao_id": sessao_id, "pesagens": rows})


@app.get("/sessoes/<int:sessao_id>")
def obter_sessao(sessao_id: int):
    # 1) Confirma existência sem joins (evita 404 falso por view/coluna quebrada)
    base = one("SELECT id FROM sessoes_producao WHERE id=:id", id=sessao_id)
    if not base:
        return jsonify({
            "error": "not found",
            "sessao_id": sessao_id,
            "hint": "Sessão inexistente no banco. Inicie uma nova produção no app.",
        }), 404

    s = None
    try:
        s = one(_sessao_select_sql(), id=sessao_id)
    except Exception as e:
        log.warning("obter_sessao select completo falhou (%s): %s", sessao_id, e)

    if not s:
        try:
            s = one("""
                SELECT s.id, s.cliente_id, s.produto_id, s.lote, s.operador_id,
                       s.inicio, s.fim, s.status,
                       COALESCE((
                         SELECT SUM(l.contagem_incremental) FROM leituras l
                         WHERE l.sessao_id = s.id
                       ), 0) AS total,
                       c.nome AS cliente, p.nome AS produto
                FROM sessoes_producao s
                LEFT JOIN clientes c ON c.id = s.cliente_id
                LEFT JOIN produtos p ON p.id = s.produto_id
                WHERE s.id=:id
            """, id=sessao_id)
        except Exception as e:
            log.warning("obter_sessao fallback falhou (%s): %s", sessao_id, e)
            s = one("""
                SELECT s.id, s.cliente_id, s.produto_id, s.lote, s.operador_id,
                       s.inicio, s.fim, s.status, 0 AS total
                FROM sessoes_producao s
                WHERE s.id=:id
            """, id=sessao_id)

    if not s:
        return jsonify({"error": "not found", "sessao_id": sessao_id}), 404

    try:
        l = all_("""
            SELECT timestamp, contagem_incremental, temp_amb, temp_obj
            FROM leituras
            WHERE sessao_id=:id
            ORDER BY id DESC
            LIMIT 20
        """, id=sessao_id)
    except Exception:
        l = all_("""
            SELECT timestamp, contagem_incremental
            FROM leituras
            WHERE sessao_id=:id
            ORDER BY id DESC
            LIMIT 20
        """, id=sessao_id)
    s["ultimas_leituras"] = list(reversed(l))

    try:
        pesagens = all_(
            """
            SELECT item_seq, peso_g FROM pesagens
            WHERE sessao_id=:id ORDER BY item_seq ASC LIMIT 50
            """,
            id=sessao_id,
        )
        s["pesagens_amostra"] = pesagens
        cnt = one("SELECT COUNT(*) AS n FROM pesagens WHERE sessao_id=:id", id=sessao_id)
        s["pesagens_count"] = (cnt or {}).get("n", 0)
    except Exception:
        s["pesagens_amostra"] = []
        s["pesagens_count"] = 0

    return jsonify(s)


@app.get("/sessoes")
def listar_sessoes():
    try:
        page = max(1, int(request.args.get("page", "1")))
        size = min(100, max(1, int(request.args.get("size", "20"))))
    except Exception:
        page, size = 1, 20
    offset = (page - 1) * size

    where_sql, params = _build_sessoes_filters()
    params["size"] = size
    params["off"] = offset

    has_peso = _column_exists("sessoes_producao", "peso_total_g")
    peso_cols = (
        ", s.peso_total_g, s.peso_medio_g, COALESCE(s.pesagem_status,'pendente') AS pesagem_status"
        if has_peso else
        ", NULL AS peso_total_g, NULL AS peso_medio_g, 'pendente' AS pesagem_status"
    )

    try:
        rows = all_(
            f"""
            SELECT s.id, s.status, s.inicio, s.fim, s.lote,
                   c.nome AS cliente, p.nome AS produto,
                   COALESCE(v.total,0) AS total,
                   COALESCE(v.avg_temp_amb,0) AS temp_media_amb,
                   COALESCE(v.avg_temp_obj,0) AS temp_media_obj
                   {peso_cols}
            FROM sessoes_producao s
            JOIN clientes c ON c.id=s.cliente_id
            JOIN produtos p ON p.id=s.produto_id
            LEFT JOIN vw_totais_sessao v ON v.sessao_id=s.id
            WHERE {where_sql}
            ORDER BY s.id DESC
            LIMIT :size OFFSET :off
            """,
            **params,
        )
    except Exception:
        rows = all_(
            f"""
            SELECT s.id, s.status, s.inicio, s.fim, s.lote,
                   c.nome AS cliente, p.nome AS produto,
                   COALESCE(v.total,0) AS total,
                   0 AS temp_media_amb,
                   0 AS temp_media_obj
                   {peso_cols}
            FROM sessoes_producao s
            JOIN clientes c ON c.id=s.cliente_id
            JOIN produtos p ON p.id=s.produto_id
            LEFT JOIN vw_totais_sessao v ON v.sessao_id=s.id
            WHERE {where_sql}
            ORDER BY s.id DESC
            LIMIT :size OFFSET :off
            """,
            **params,
        )
    return jsonify({"page": page, "size": size, "rows": rows})

# ====================================================
# 📈 LEITURAS
# ====================================================
@app.post("/leituras")
def registrar_leitura():
    """
    body (duas formas):
    1️⃣ Novo formato (lote):
    {
        "sessao_id": 123,
        "device_code": "esteira1",
        "leituras": [
            {"inc": 1, "temp_amb": 27.5, "temp_obj": 30.1},
            {"inc": 1, "temp_amb": 27.6, "temp_obj": 30.3}
        ]
    }

    2️⃣ Formato antigo:
    { "sessao_id": 123, "device_code": "esteira1", "inc": 1 }
    """
    data = request.get_json(force=True)
    if not data:
        return jsonify({"error": "JSON vazio"}), 400

    sessao_id = int(data.get("sessao_id") or 0)
    device_code = (data.get("device_code") or "").strip()
    leituras = data.get("leituras")

    if sessao_id <= 0 or not device_code:
        return jsonify({"error": "sessao_id e device_code obrigatórios"}), 400

    s = one("SELECT id FROM sessoes_producao WHERE id=:id", id=sessao_id)
    if not s:
        return jsonify({"error": "sessao_id inexistente"}), 404
    disp = one("SELECT id FROM dispositivos WHERE codigo=:c", c=device_code)
    if not disp:
        return jsonify({"error": "device_code desconhecido"}), 400

    if isinstance(leituras, list) and len(leituras) > 0:
        inseridas = 0
        for leitura in leituras:
            try:
                inc = int(leitura.get("inc", 0))
                t_amb = float(leitura.get("temp_amb", 0.0))
                t_obj = float(leitura.get("temp_obj", 0.0))
            except Exception:
                continue
            if inc <= 0:
                continue

            try:
                exec_(
                    """
                    INSERT INTO leituras
                        (sessao_id, timestamp, contagem_incremental, temp_amb, temp_obj, dispositivo_id, dispositivo)
                    VALUES
                        (:sessao_id, :ts, :inc, :t_amb, :t_obj, :disp_id, :disp)
                    """,
                    sessao_id=sessao_id,
                    ts=now_utc_naive(),
                    inc=inc,
                    t_amb=t_amb,
                    t_obj=t_obj,
                    disp_id=disp["id"],
                    disp=device_code,
                )
            except OperationalError as e:
                if "Unknown column" in str(e):
                    exec_(
                        """
                        INSERT INTO leituras
                            (sessao_id, timestamp, contagem_incremental, dispositivo_id)
                        VALUES
                            (:sessao_id, :ts, :inc, :disp_id)
                        """,
                        sessao_id=sessao_id,
                        ts=now_utc_naive(),
                        inc=inc,
                        disp_id=disp["id"],
                    )
                else:
                    raise
            inseridas += 1

        return jsonify({"ok": True, "inseridas": inseridas, "sessao_id": sessao_id}), 201

    else:
        try:
            inc = int(data.get("inc") or 0)
        except Exception:
            inc = 0

        if inc <= 0:
            return jsonify({"error": "inc inválido"}), 400

        exec_(
            """
            INSERT INTO leituras
                (sessao_id, timestamp, contagem_incremental, dispositivo_id, dispositivo)
            VALUES
                (:sessao_id, :ts, :inc, :disp_id, :disp)
            """,
            sessao_id=sessao_id,
            ts=now_utc_naive(),
            inc=inc,
            disp_id=disp["id"],
            disp=device_code,
        )
        return jsonify({"ok": True, "sessao_id": sessao_id, "inc": inc}), 201


# ====================================================
# 🏁 RUN APP
# ====================================================
if __name__ == "__main__":
    app.run(host=FLASK_HOST, port=FLASK_PORT, debug=FLASK_DEBUG)
