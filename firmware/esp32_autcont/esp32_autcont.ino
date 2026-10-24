/*
 * AUTCONT — ESP32-D controlador único
 * TB6600 + NEMA 17 | E18-D80NK | MLX90614 | HX711 | Buzzer
 *
 * Bibliotecas: PubSubClient, ArduinoJson, HX711 (bogde), Adafruit MLX90614
 * Histórico DRV8825: arduinoV4/sensor_e_motor/sensor_e_motor.ino (preservado)
 */

#if __has_include("secrets.h")
#include "secrets.h"
#endif
#include "config.h"

#include <WiFi.h>
#include <PubSubClient.h>
#include <HTTPClient.h>
#include <ArduinoJson.h>
#include <Wire.h>
#include <HX711.h>
#include <Adafruit_MLX90614.h>
#include <Preferences.h>

// ============================================================
// ESTADOS DO CICLO
// ============================================================
enum CycleState : uint8_t {
  ST_AGUARDANDO_PRODUTO = 0,
  ST_PRODUTO_DETECTADO,
  ST_POSICIONANDO,
  ST_ESTEIRA_PARANDO,
  ST_AGUARDANDO_ESTABILIZACAO,
  ST_PESANDO,
  ST_PESO_VALIDADO,
  ST_BUZZER_CONFIRMADO,
  ST_REGISTRANDO,
  ST_AGUARDANDO_RETIRADA,
  ST_CICLO_CONCLUIDO,
  ST_FALHA
};

static const char* stateName(CycleState s) {
  switch (s) {
    case ST_AGUARDANDO_PRODUTO: return "AGUARDANDO_PRODUTO";
    case ST_PRODUTO_DETECTADO: return "PRODUTO_DETECTADO";
    case ST_POSICIONANDO: return "POSICIONANDO";
    case ST_ESTEIRA_PARANDO: return "ESTEIRA_PARANDO";
    case ST_AGUARDANDO_ESTABILIZACAO: return "AGUARDANDO_ESTABILIZACAO";
    case ST_PESANDO: return "PESANDO";
    case ST_PESO_VALIDADO: return "PESO_VALIDADO";
    case ST_BUZZER_CONFIRMADO: return "BUZZER_CONFIRMADO";
    case ST_REGISTRANDO: return "REGISTRANDO";
    case ST_AGUARDANDO_RETIRADA: return "AGUARDANDO_RETIRADA";
    case ST_CICLO_CONCLUIDO: return "CICLO_CONCLUIDO";
    case ST_FALHA: return "FALHA";
    default: return "DESCONHECIDO";
  }
}

// ============================================================
// MOTOR
// ============================================================
volatile int targetRPM = DEFAULT_RPM;
volatile int currentRPM = 0;
volatile int motorDir = DEFAULT_DIR;
volatile bool motorRequested = false;
volatile bool motorRunning = false;

hw_timer_t* motorTimer = NULL;
volatile bool stepEnabled = false;
volatile bool stepState = false;
portMUX_TYPE timerMux = portMUX_INITIALIZER_UNLOCKED;

// ============================================================
// SENSOR / SESSÃO / PRODUTO
// ============================================================
volatile uint32_t lastTrigger = 0;
volatile uint32_t detectQueue = 0;   // fila ISR — não perde eventos
volatile bool countingEnabled = false;

uint32_t sessao_id = 0;
uint32_t produto_seq = 0;
uint32_t produto_id = 0;
char cycle_id[48] = "";
uint32_t detectados = 0;
uint32_t pesados = 0;
float peso_acumulado_g = 0.0f;
float ultimo_peso_g = 0.0f;
float peso_atual_g = 0.0f;
bool peso_estavel = false;

CycleState cycleState = ST_AGUARDANDO_PRODUTO;
char falha_motivo[96] = "";
unsigned long stateEnterMs = 0;
unsigned long cmd_seq_last = 0;

// ============================================================
// HX711 / MLX / BUZZER / PREFS
// ============================================================
HX711 scale;
Adafruit_MLX90614 mlx = Adafruit_MLX90614();
Preferences prefs;

bool hx711_ok = false;
bool mlx_ok = false;
float scale_cal = SCALE_CAL_DEFAULT;
float stability_tol_g = SCALE_STABILITY_TOL_G;
bool buzzer_enabled = BUZZER_ENABLED_DEFAULT;

float temp_amb = NAN;
float temp_obj = NAN;

float weigh_samples[SCALE_WINDOW_SAMPLES];
uint8_t weigh_count = 0;
unsigned long weigh_stable_since = 0;
float validated_weight_g = 0.0f;
bool buzzer_done_this_cycle = false;
unsigned long last_cmd_id = 0;

// Buzzer não bloqueante
enum BuzzerMode : uint8_t { BZ_IDLE, BZ_SUCCESS, BZ_ERROR };
BuzzerMode bzMode = BZ_IDLE;
uint8_t bzBeepsLeft = 0;
bool bzOn = false;
unsigned long bzNextMs = 0;

// ============================================================
// MQTT
// ============================================================
WiFiClient wifiClient;
PubSubClient client(wifiClient);
String topic_cmd, topic_motor, topic_status, topic_event;

// ============================================================
// UTIL
// ============================================================
uint32_t rpmToHalfPeriodUs(int rpm) {
  if (rpm < 1) rpm = 1;
  long stepsPerRev = (long)FULL_STEPS_PER_REV * MICROSTEP;
  double stepsPerSecond = ((double)rpm * stepsPerRev) / 60.0;
  double halfPeriodUs = (1000000.0 / stepsPerSecond) / 2.0;
  if (halfPeriodUs < 50) halfPeriodUs = 50;
  return (uint32_t)halfPeriodUs;
}

void IRAM_ATTR motorISR() {
  if (!stepEnabled) return;
  stepState = !stepState;
  // TB6600 ânodo comum: nível LOW conduz o opto (pulso ativo LOW)
  digitalWrite(STEP_PIN, stepState ? LOW : HIGH);
}

void setupMotorTimer() {
  motorTimer = timerBegin(1000000);
  timerAttachInterrupt(motorTimer, &motorISR);
  timerAlarm(motorTimer, rpmToHalfPeriodUs(START_RPM), true, 0);
  timerStart(motorTimer);
}

void updateMotorTimer(int rpm) {
  if (!motorTimer) return;
  timerAlarm(motorTimer, rpmToHalfPeriodUs(rpm), true, 0);
}

void setMotorDirection(int dir) {
  motorDir = dir ? 1 : 0;
  digitalWrite(DIR_PIN, motorDir ? HIGH : LOW);
  delay(2);
}

void motorStart() {
  if (motorRequested) return;
  motorRequested = true;
  setMotorDirection(motorDir);
  currentRPM = START_RPM;
  updateMotorTimer(currentRPM);
  stepState = false;
  digitalWrite(STEP_PIN, STEP_IDLE_LEVEL);
  stepEnabled = true;
  motorRunning = true;
  Serial.printf("MOTOR START rpm=%d\n", currentRPM);
}

void motorStop() {
  if (!motorRequested && !motorRunning) return;
  motorRequested = false;
  Serial.println("MOTOR STOP solicitado");
}

void motorTask(void* param) {
  unsigned long lastRamp = 0;
  for (;;) {
    unsigned long now = millis();
    if (motorRequested) {
      if (!motorRunning) {
        currentRPM = START_RPM;
        updateMotorTimer(currentRPM);
        stepEnabled = true;
        motorRunning = true;
      }
      if (currentRPM < targetRPM) {
        if (now - lastRamp >= RAMP_INTERVAL_MS) {
          currentRPM += RAMP_STEP_RPM;
          if (currentRPM > targetRPM) currentRPM = targetRPM;
          updateMotorTimer(currentRPM);
          lastRamp = now;
        }
      } else if (currentRPM > targetRPM) {
        if (now - lastRamp >= RAMP_INTERVAL_MS) {
          currentRPM -= RAMP_STEP_RPM;
          if (currentRPM < targetRPM) currentRPM = targetRPM;
          updateMotorTimer(currentRPM);
          lastRamp = now;
        }
      }
    } else if (motorRunning) {
      if (currentRPM > START_RPM) {
        if (now - lastRamp >= RAMP_INTERVAL_MS) {
          currentRPM -= RAMP_STEP_RPM;
          if (currentRPM < START_RPM) currentRPM = START_RPM;
          updateMotorTimer(currentRPM);
          lastRamp = now;
        }
      } else {
        stepEnabled = false;
        digitalWrite(STEP_PIN, STEP_IDLE_LEVEL);
        currentRPM = 0;
        motorRunning = false;
        Serial.println("Motor parado (TB6600 sem ENA — eixo pode permanecer energizado).");
      }
    }
    vTaskDelay(pdMS_TO_TICKS(5));
  }
}

void IRAM_ATTR sensorISR() {
  uint32_t now = millis();
  if (!countingEnabled) return;
  if (now - lastTrigger <= SENSOR_REFRACT_MS) return;
  lastTrigger = now;
  portENTER_CRITICAL_ISR(&timerMux);
  detectQueue++;
  portEXIT_CRITICAL_ISR(&timerMux);
}

// ============================================================
// BUZZER
// ============================================================
void buzzerOff() {
  digitalWrite(BUZZER_PIN, LOW);
  bzOn = false;
}

void buzzerStart(BuzzerMode mode) {
  if (!buzzer_enabled && mode == BZ_SUCCESS) return;
  bzMode = mode;
  bzBeepsLeft = (mode == BZ_ERROR) ? BUZZER_ERROR_BEEPS : BUZZER_SUCCESS_BEEPS;
  bzOn = true;
  digitalWrite(BUZZER_PIN, HIGH);
  bzNextMs = millis() + BUZZER_BEEP_MS;
}

bool buzzerBusy() { return bzMode != BZ_IDLE; }

void buzzerTick() {
  if (bzMode == BZ_IDLE) return;
  unsigned long now = millis();
  if (now < bzNextMs) return;
  if (bzOn) {
    digitalWrite(BUZZER_PIN, LOW);
    bzOn = false;
    bzBeepsLeft--;
    if (bzBeepsLeft == 0) {
      bzMode = BZ_IDLE;
      return;
    }
    bzNextMs = now + BUZZER_GAP_MS;
  } else {
    digitalWrite(BUZZER_PIN, HIGH);
    bzOn = true;
    bzNextMs = now + BUZZER_BEEP_MS;
  }
}

// ============================================================
// BALANÇA
// ============================================================
bool scaleInit() {
  scale.begin(HX711_DOUT, HX711_SCK);
  delay(200);
  if (!scale.is_ready()) {
    Serial.println("HX711 indisponivel");
    hx711_ok = false;
    return false;
  }
  scale.set_scale(scale_cal);
  scale.tare(15);
  hx711_ok = true;
  Serial.printf("HX711 OK cal=%.3f\n", scale_cal);
  return true;
}

float scaleReadRaw() {
  if (!hx711_ok || !scale.is_ready()) return NAN;
  return scale.get_units(1);
}

float scaleReadFiltered() {
  if (!hx711_ok) return NAN;
  const int n = 5;
  float buf[5];
  int got = 0;
  for (int i = 0; i < n; i++) {
    if (!scale.is_ready()) {
      delay(2);
      continue;
    }
    buf[got++] = scale.get_units(1);
  }
  if (got == 0) return NAN;
  // mediana simples
  for (int i = 0; i < got - 1; i++) {
    for (int j = i + 1; j < got; j++) {
      if (buf[j] < buf[i]) {
        float t = buf[i];
        buf[i] = buf[j];
        buf[j] = t;
      }
    }
  }
  return buf[got / 2];
}

void scaleDoTare() {
  if (!hx711_ok) return;
  scale.tare(20);
  Serial.println("Tara OK");
}

void scaleCalibrate(float known_g) {
  if (!hx711_ok || known_g <= 0) return;
  scale.set_scale();
  float raw = scale.get_units(20);
  if (fabs(raw) < 1e-3) return;
  scale_cal = raw / known_g;
  scale.set_scale(scale_cal);
  prefs.begin("autcont", false);
  prefs.putFloat("scale_cal", scale_cal);
  prefs.end();
  Serial.printf("Calibracao: cal=%.4f (ref=%.1fg)\n", scale_cal, known_g);
}

bool stabilityPush(float sample, float& out_mean) {
  if (isnan(sample)) return false;
  if (weigh_count < SCALE_WINDOW_SAMPLES) {
    weigh_samples[weigh_count++] = sample;
  } else {
    for (int i = 1; i < SCALE_WINDOW_SAMPLES; i++) {
      weigh_samples[i - 1] = weigh_samples[i];
    }
    weigh_samples[SCALE_WINDOW_SAMPLES - 1] = sample;
  }
  if (weigh_count < SCALE_WINDOW_SAMPLES) return false;

  float minv = weigh_samples[0], maxv = weigh_samples[0], sum = 0;
  for (int i = 0; i < SCALE_WINDOW_SAMPLES; i++) {
    float v = weigh_samples[i];
    if (v < minv) minv = v;
    if (v > maxv) maxv = v;
    sum += v;
  }
  out_mean = sum / SCALE_WINDOW_SAMPLES;
  return (maxv - minv) <= stability_tol_g;
}

void stabilityReset() {
  weigh_count = 0;
  weigh_stable_since = 0;
}

// ============================================================
// TEMPERATURA
// ============================================================
void tempTick() {
  if (!mlx_ok) {
    temp_amb = NAN;
    temp_obj = NAN;
    return;
  }
  float a = mlx.readAmbientTempC();
  float o = mlx.readObjectTempC();
  if (isnan(a) || isnan(o) || a < -40 || a > 125 || o < -70 || o > 380) {
    temp_amb = NAN;
    temp_obj = NAN;
  } else {
    temp_amb = a;
    temp_obj = o;
  }
}

// ============================================================
// HTTP / MQTT
// ============================================================
String apiUrl(const char* path) {
  String url = "http://";
  url += API_HOST;
  url += ":";
  url += String(API_PORT);
  url += path;
  return url;
}

bool postJson(const char* path, const String& payload) {
  if (WiFi.status() != WL_CONNECTED) return false;
  HTTPClient http;
  http.begin(apiUrl(path));
  http.addHeader("Content-Type", "application/json");
  int code = http.POST(payload);
  http.end();
  return code >= 200 && code < 300;
}

bool postContagem(uint32_t inc) {
  if (inc == 0 || sessao_id == 0) return true;
  StaticJsonDocument<384> doc;
  doc["sessao_id"] = sessao_id;
  doc["device_code"] = DEVICE_CODE;
  doc["inc"] = inc;
  if (!isnan(temp_amb)) doc["temp_amb"] = temp_amb;
  if (!isnan(temp_obj)) doc["temp_obj"] = temp_obj;
  String payload;
  serializeJson(doc, payload);
  return postJson(API_PATH_LEITURAS, payload);
}

bool postPesagem() {
  if (sessao_id == 0) return false;
  StaticJsonDocument<768> doc;
  doc["sessao_id"] = sessao_id;
  doc["device_code"] = DEVICE_CODE;
  doc["produto_id"] = produto_id;
  doc["cycle_id"] = cycle_id;
  doc["peso_g"] = validated_weight_g;
  doc["peso_estavel"] = true;
  doc["buzzer_acionado"] = buzzer_done_this_cycle;
  doc["status"] = "pesado";
  if (!isnan(temp_amb)) doc["temp_amb"] = temp_amb;
  if (!isnan(temp_obj)) doc["temp_obj"] = temp_obj;
  String payload;
  serializeJson(doc, payload);
  return postJson(API_PATH_PESAGENS, payload);
}

void publishEvent(JsonDocument& doc) {
  if (!client.connected()) return;
  String out;
  serializeJson(doc, out);
  client.publish(topic_event.c_str(), out.c_str(), false);
}

void publishStatus(bool retain = true) {
  if (!client.connected()) return;
  StaticJsonDocument<768> doc;
  doc["type"] = "station_status";
  doc["device_code"] = DEVICE_CODE;
  doc["sessao_id"] = sessao_id;
  doc["cycle_state"] = stateName(cycleState);
  doc["falha"] = falha_motivo;
  doc["rpm"] = targetRPM;
  doc["current_rpm"] = currentRPM;
  doc["dir"] = motorDir;
  doc["motor_enabled"] = motorRequested;
  doc["motor_running"] = motorRunning;
  doc["counting"] = countingEnabled;
  doc["detectados"] = detectados;
  doc["pesados"] = pesados;
  doc["peso_atual_g"] = isnan(peso_atual_g) ? 0 : peso_atual_g;
  doc["ultimo_peso_g"] = ultimo_peso_g;
  doc["peso_acumulado_g"] = peso_acumulado_g;
  doc["peso_estavel"] = peso_estavel;
  doc["hx711_ok"] = hx711_ok;
  doc["mlx_ok"] = mlx_ok;
  doc["buzzer_enabled"] = buzzer_enabled;
  doc["buzzer_busy"] = buzzerBusy();
  doc["stability_tol_g"] = stability_tol_g;
  doc["produto_id"] = produto_id;
  doc["cycle_id"] = cycle_id;
  if (!isnan(temp_amb)) doc["temp_amb"] = temp_amb;
  else doc["temp_amb"] = nullptr;
  if (!isnan(temp_obj)) doc["temp_obj"] = temp_obj;
  else doc["temp_obj"] = nullptr;
  String out;
  serializeJson(doc, out);
  client.publish(topic_status.c_str(), out.c_str(), retain);
}

void enterState(CycleState s, const char* motivo = "") {
  cycleState = s;
  stateEnterMs = millis();
  if (motivo && motivo[0]) {
    strncpy(falha_motivo, motivo, sizeof(falha_motivo) - 1);
    falha_motivo[sizeof(falha_motivo) - 1] = 0;
  } else if (s != ST_FALHA) {
    falha_motivo[0] = 0;
  }
  Serial.printf("ESTADO -> %s %s\n", stateName(s), falha_motivo);
  StaticJsonDocument<384> ev;
  ev["type"] = "cycle_state";
  ev["state"] = stateName(s);
  ev["sessao_id"] = sessao_id;
  ev["produto_id"] = produto_id;
  ev["cycle_id"] = cycle_id;
  if (falha_motivo[0]) ev["falha"] = falha_motivo;
  publishEvent(ev);
  publishStatus(false);
}

void beginProductCycle() {
  produto_seq++;
  produto_id = produto_seq;
  snprintf(cycle_id, sizeof(cycle_id), "%u-%u", sessao_id, produto_id);
  detectados++;
  validated_weight_g = 0;
  buzzer_done_this_cycle = false;
  peso_estavel = false;
  stabilityReset();
  enterState(ST_PRODUTO_DETECTADO);

  StaticJsonDocument<384> ev;
  ev["type"] = "produto_detectado";
  ev["sessao_id"] = sessao_id;
  ev["produto_id"] = produto_id;
  ev["cycle_id"] = cycle_id;
  publishEvent(ev);
}

static uint32_t pendingCountRetry = 0;

void applyMotorConfig(JsonDocument& doc) {
  if (!doc["rpm"].isNull()) {
    int rpm = doc["rpm"].as<int>();
    if (rpm < MIN_RPM) rpm = MIN_RPM;
    if (rpm > MAX_RPM) rpm = MAX_RPM;
    targetRPM = rpm;
  }
  if (!doc["dir"].isNull()) {
    int newDir = doc["dir"].as<int>() ? 1 : 0;
    if (!motorRunning) {
      motorDir = newDir;
      setMotorDirection(motorDir);
    } else if (newDir != motorDir) {
      Serial.println("Direcao ignorada: pare o motor antes.");
    }
  }
  if (!doc["motor_enabled"].isNull()) {
    if (doc["motor_enabled"].as<bool>()) motorStart();
    else motorStop();
  }
  if (!doc["stability_tol_g"].isNull()) {
    float t = doc["stability_tol_g"].as<float>();
    if (t > 0.1f && t < 50.0f) stability_tol_g = t;
  }
  publishStatus();
}

void handleStart(uint32_t id) {
  sessao_id = id;
  countingEnabled = true;
  produto_seq = 0;
  detectados = 0;
  pesados = 0;
  peso_acumulado_g = 0;
  ultimo_peso_g = 0;
  pendingCountRetry = 0;
  enterState(ST_AGUARDANDO_PRODUTO);
  motorStart();
  publishStatus();
}

void handleStop(uint32_t id) {
  (void)id;
  countingEnabled = false;
  motorStop();
  if (cycleState != ST_AGUARDANDO_PRODUTO && cycleState != ST_CICLO_CONCLUIDO) {
    enterState(ST_FALHA, "sessao_interrompida");
  } else {
    enterState(ST_AGUARDANDO_PRODUTO);
  }
  publishStatus();
}

void mqttCallback(char* topic, byte* payload, unsigned int length) {
  String msg;
  msg.reserve(length + 1);
  for (unsigned int i = 0; i < length; i++) msg += (char)payload[i];
  Serial.printf("MQTT [%s]: %s\n", topic, msg.c_str());

  StaticJsonDocument<768> doc;
  if (deserializeJson(doc, msg)) {
    Serial.println("JSON MQTT invalido");
    return;
  }

  // Anti-replay simples
  if (!doc["cmd_id"].isNull()) {
    unsigned long cid = doc["cmd_id"].as<unsigned long>();
    if (cid != 0 && cid <= last_cmd_id) {
      Serial.println("cmd_id duplicado/antigo ignorado");
      return;
    }
    if (cid != 0) last_cmd_id = cid;
  }

  const char* action = doc["action"] | "";
  uint32_t s_id = doc["sessao_id"] | 0;

  if (strcmp(action, "start") == 0) {
    applyMotorConfig(doc);
    handleStart(s_id);
    return;
  }
  if (strcmp(action, "stop") == 0) {
    handleStop(s_id);
    return;
  }
  if (strcmp(action, "config") == 0 || strcmp(action, "reset_config") == 0) {
    applyMotorConfig(doc);
    return;
  }
  if (strcmp(action, "tara") == 0) {
    scaleDoTare();
    publishStatus(false);
    return;
  }
  if (strcmp(action, "calibrar") == 0) {
    float known = doc["peso_conhecido_g"] | doc["known_g"] | 0.0f;
    if (known > 0) scaleCalibrate(known);
    publishStatus(false);
    return;
  }
  if (strcmp(action, "buzzer_config") == 0) {
    if (!doc["enabled"].isNull()) buzzer_enabled = doc["enabled"].as<bool>();
    prefs.begin("autcont", false);
    prefs.putBool("buzzer", buzzer_enabled);
    prefs.end();
    publishStatus(false);
    return;
  }
  if (strcmp(action, "ack_falha") == 0 || strcmp(action, "reset_falha") == 0) {
    if (cycleState == ST_FALHA) {
      motorStop();
      enterState(ST_AGUARDANDO_PRODUTO);
      if (countingEnabled) motorStart();
    }
    return;
  }

  String receivedTopic = String(topic);
  if (receivedTopic.endsWith("/motor")) {
    applyMotorConfig(doc);
  }
}

void mqttReconnect() {
  while (!client.connected()) {
    String clientId = String("autcont-") + WiFi.macAddress();
    clientId.replace(":", "");
    Serial.print("MQTT...");
    // LWT offline
    String lwt = "{\"type\":\"lwt\",\"status\":\"offline\",\"device_code\":\"" DEVICE_CODE "\"}";
    if (client.connect(clientId.c_str(), topic_status.c_str(), 1, true, lwt.c_str())) {
      Serial.println("OK");
      client.subscribe(topic_cmd.c_str());
      client.subscribe(topic_motor.c_str());
      StaticJsonDocument<128> online;
      online["type"] = "lwt";
      online["status"] = "online";
      online["device_code"] = DEVICE_CODE;
      String o;
      serializeJson(online, o);
      client.publish(topic_status.c_str(), o.c_str(), true);
      publishStatus();
    } else {
      Serial.printf("falha rc=%d\n", client.state());
      delay(2000);
    }
  }
}

// ============================================================
// MÁQUINA DE ESTADOS DO CICLO
// ============================================================
void cycleTick() {
  unsigned long now = millis();
  peso_atual_g = scaleReadFiltered();
  if (!isnan(peso_atual_g)) {
    // ruído pequeno perto de zero
  }

  // Consome detecções da ISR somente em AGUARDANDO
  uint32_t pending = 0;
  portENTER_CRITICAL(&timerMux);
  pending = detectQueue;
  detectQueue = 0;
  portEXIT_CRITICAL(&timerMux);

  if (pending > 0) {
    if (cycleState == ST_AGUARDANDO_PRODUTO && countingEnabled && sessao_id > 0) {
      // um produto por ciclo; extras ficam na fila
      beginProductCycle();
      if (pending > 1) {
        portENTER_CRITICAL(&timerMux);
        detectQueue += (pending - 1);
        portEXIT_CRITICAL(&timerMux);
      }
      if (!postContagem(1)) pendingCountRetry++;
    } else {
      // não descartar — devolve à fila
      portENTER_CRITICAL(&timerMux);
      detectQueue += pending;
      portEXIT_CRITICAL(&timerMux);
    }
  }

  if (pendingCountRetry > 0 && postContagem(pendingCountRetry)) {
    pendingCountRetry = 0;
  }

  switch (cycleState) {
    case ST_AGUARDANDO_PRODUTO:
      break;

    case ST_PRODUTO_DETECTADO:
      enterState(ST_POSICIONANDO);
      break;

    case ST_POSICIONANDO:
      // Critério verificável: peso acima do limiar de presença (produto na plataforma)
      if (!hx711_ok) {
        enterState(ST_FALHA, "hx711_indisponivel");
        motorStop();
        buzzerStart(BZ_ERROR);
        break;
      }
      if (!isnan(peso_atual_g) && peso_atual_g >= SCALE_PRESENCE_G) {
        enterState(ST_ESTEIRA_PARANDO);
        motorStop();
      } else if (now - stateEnterMs > SCALE_POSITION_TIMEOUT_MS) {
        enterState(ST_FALHA, "produto_nao_posicionado");
        motorStop();
        buzzerStart(BZ_ERROR);
      }
      break;

    case ST_ESTEIRA_PARANDO:
      if (!motorRunning) {
        enterState(ST_AGUARDANDO_ESTABILIZACAO);
      } else if (now - stateEnterMs > 5000) {
        // força avanço se rampa demorar
        enterState(ST_AGUARDANDO_ESTABILIZACAO);
      }
      break;

    case ST_AGUARDANDO_ESTABILIZACAO:
      if (now - stateEnterMs >= SCALE_SETTLE_MS) {
        stabilityReset();
        enterState(ST_PESANDO);
      }
      break;

    case ST_PESANDO: {
      float mean = 0;
      bool win_ok = stabilityPush(peso_atual_g, mean);
      if (win_ok) {
        if (weigh_stable_since == 0) weigh_stable_since = now;
        if (now - weigh_stable_since >= SCALE_STABLE_MS) {
          validated_weight_g = mean;
          peso_estavel = true;
          enterState(ST_PESO_VALIDADO);
        }
      } else {
        weigh_stable_since = 0;
      }
      if (now - stateEnterMs > SCALE_WEIGH_TIMEOUT_MS) {
        enterState(ST_FALHA, "peso_instavel");
        buzzerStart(BZ_ERROR);
      }
      break;
    }

    case ST_PESO_VALIDADO:
      buzzerStart(BZ_SUCCESS);
      enterState(ST_BUZZER_CONFIRMADO);
      break;

    case ST_BUZZER_CONFIRMADO:
      if (!buzzerBusy()) {
        buzzer_done_this_cycle = true;
        enterState(ST_REGISTRANDO);
      }
      break;

    case ST_REGISTRANDO: {
      bool ok = postPesagem();
      StaticJsonDocument<384> ev;
      ev["type"] = "peso_validado";
      ev["action"] = "peso_validado";
      ev["sessao_id"] = sessao_id;
      ev["produto_id"] = produto_id;
      ev["cycle_id"] = cycle_id;
      ev["peso_g"] = validated_weight_g;
      ev["estavel"] = true;
      ev["buzzer_acionado"] = true;
      publishEvent(ev);

      if (ok) {
        pesados++;
        ultimo_peso_g = validated_weight_g;
        peso_acumulado_g += validated_weight_g;
        enterState(ST_AGUARDANDO_RETIRADA);
      } else {
        // não perde o ciclo — tenta de novo até timeout
        if (now - stateEnterMs > 10000) {
          enterState(ST_FALHA, "falha_registro_api");
          buzzerStart(BZ_ERROR);
        }
      }
      break;
    }

    case ST_AGUARDANDO_RETIRADA:
      if (!isnan(peso_atual_g) && peso_atual_g <= SCALE_EMPTY_G) {
        enterState(ST_CICLO_CONCLUIDO);
      } else if (now - stateEnterMs > SCALE_REMOVE_TIMEOUT_MS) {
        enterState(ST_FALHA, "produto_nao_retirado");
        buzzerStart(BZ_ERROR);
      }
      break;

    case ST_CICLO_CONCLUIDO: {
      StaticJsonDocument<256> ev;
      ev["type"] = "ciclo_concluido";
      ev["sessao_id"] = sessao_id;
      ev["produto_id"] = produto_id;
      ev["cycle_id"] = cycle_id;
      ev["status"] = "concluido";
      publishEvent(ev);
      // libera esteira para próximo
      if (countingEnabled) motorStart();
      enterState(ST_AGUARDANDO_PRODUTO);
      break;
    }

    case ST_FALHA:
      // bloqueio até ack_falha via MQTT — sem retomada automática
      break;
  }
}

void networkTask(void* param) {
  unsigned long lastStatus = 0;
  unsigned long lastTemp = 0;
  for (;;) {
    if (!client.connected()) mqttReconnect();
    client.loop();
    buzzerTick();

    unsigned long now = millis();
    if (now - lastTemp >= 1000) {
      tempTick();
      lastTemp = now;
    }
    if (now - lastStatus >= STATUS_INTERVAL_MS) {
      publishStatus(false);
      lastStatus = now;
    }
    vTaskDelay(pdMS_TO_TICKS(10));
  }
}

// ============================================================
// SETUP / LOOP
// ============================================================
void setup() {
  Serial.begin(115200);
  delay(400);
  Serial.println("\n================================");
  Serial.println("AUTCONT ESP32-D | TB6600+HX711+Buzzer");
  Serial.println("================================");

  pinMode(STEP_PIN, OUTPUT);
  pinMode(DIR_PIN, OUTPUT);
  pinMode(BUZZER_PIN, OUTPUT);
  digitalWrite(STEP_PIN, STEP_IDLE_LEVEL);
  digitalWrite(DIR_PIN, motorDir ? HIGH : LOW);
  buzzerOff();

  pinMode(SENSOR_PIN, INPUT_PULLUP);
  attachInterrupt(digitalPinToInterrupt(SENSOR_PIN), sensorISR, FALLING);

  prefs.begin("autcont", true);
  scale_cal = prefs.getFloat("scale_cal", SCALE_CAL_DEFAULT);
  buzzer_enabled = prefs.getBool("buzzer", BUZZER_ENABLED_DEFAULT);
  prefs.end();

  Wire.begin(I2C_SDA, I2C_SCL);
  mlx_ok = mlx.begin();
  if (!mlx_ok) Serial.println("MLX90614 indisponivel — sem temperaturas ficticias");
  else Serial.println("MLX90614 OK");

  scaleInit();

  setupMotorTimer();
  xTaskCreatePinnedToCore(motorTask, "motorTask", 4096, NULL, 2, NULL, 1);

  WiFi.begin(WIFI_SSID, WIFI_PASSWORD);
  Serial.print("WiFi");
  while (WiFi.status() != WL_CONNECTED) {
    Serial.print(".");
    delay(300);
  }
  Serial.println();
  Serial.print("IP: ");
  Serial.println(WiFi.localIP());

  client.setServer(MQTT_HOST, MQTT_PORT);
  client.setCallback(mqttCallback);
  client.setBufferSize(1024);

  String base = String("factory/default/line/1/device/") + DEVICE_CODE;
  topic_cmd = base + "/cmd";
  topic_motor = base + "/motor";
  topic_status = base + "/status";
  topic_event = base + "/event";

  xTaskCreatePinnedToCore(networkTask, "networkTask", 10240, NULL, 1, NULL, 0);

  enterState(ST_AGUARDANDO_PRODUTO);
  Serial.println("Pronto. Aguardando MQTT start.");
  Serial.printf("Pinos STEP=%d DIR=%d SENSOR=%d HX711=%d/%d BUZZER=%d\n",
                STEP_PIN, DIR_PIN, SENSOR_PIN, HX711_DOUT, HX711_SCK, BUZZER_PIN);
  Serial.printf("Microstep=%d RPM padrao=%d\n", MICROSTEP, DEFAULT_RPM);
}

void loop() {
  cycleTick();
  delay(20);
}
