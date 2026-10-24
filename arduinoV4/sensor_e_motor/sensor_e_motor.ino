#include <WiFi.h>
#include <PubSubClient.h>
#include <HTTPClient.h>
#include <ArduinoJson.h>

// ============================================================
// AUTCONT - ESP32 / Wemos D1 R32 + DRV8825  [HISTÓRICO]
// Preservado. Firmware atual: firmware/esp32_autcont/
// (TB6600 1/8 + HX711 + buzzer + máquina de estados)
// ============================================================

// ------------------------------------------------------------
// REDE
// ------------------------------------------------------------
const char* ssid = "Lab-Calabouco";
const char* password = "ailsonETE";

const char* mqtt_server = "10.0.0.136";
const uint16_t mqtt_port = 1883;

const char* device_code = "esteira1";

const char* api_host = "10.0.0.136";
const uint16_t api_port = 5000;
const char* api_path = "/leituras";

// ------------------------------------------------------------
// PINOS - Wemos D1 R32
//
// D6 -> GPIO 27 -> Sensor
// D3 -> GPIO 25 -> STEP
// D2 -> GPIO 26 -> DIR
// D4 -> GPIO 17 -> ENABLE
// ------------------------------------------------------------
#define SENSOR_PIN 27
#define STEP_PIN   25
#define DIR_PIN    26
#define EN_PIN     17

// ------------------------------------------------------------
// CONFIGURAÇÃO DO MOTOR
// ------------------------------------------------------------

// NEMA 17 típico: 1,8° = 200 passos/revolução
#define FULL_STEPS_PER_REV 200

/*
   IMPORTANTE:

   Para o PRIMEIRO TESTE vamos considerar PASSO INTEIRO.

   M0 = LOW
   M1 = LOW
   M2 = LOW

   Portanto:
*/
#define MICROSTEP 1

// RPM padrão
const int DEFAULT_RPM = 50;

// Sentido inicial
const int DEFAULT_DIR = 0;

// RPM mínimo/máximo permitido pelo painel
const int MIN_RPM = 5;
const int MAX_RPM = 200;

// ------------------------------------------------------------
// RAMPA
// ------------------------------------------------------------

// Começar devagar evita tranco no NEMA.
const int START_RPM = 5;

// Incremento da rampa
const int RAMP_STEP_RPM = 1;

// Intervalo entre incrementos
const int RAMP_INTERVAL_MS = 30;

// ------------------------------------------------------------
// ESTADO DO MOTOR
// ------------------------------------------------------------
volatile int targetRPM = DEFAULT_RPM;
volatile int currentRPM = 0;

volatile int motorDir = DEFAULT_DIR;

volatile bool motorRequested = false;
volatile bool motorRunning = false;

// ------------------------------------------------------------
// SENSOR
// ------------------------------------------------------------
const uint32_t REFRACT_MS = 150;

volatile uint32_t lastTrigger = 0;
volatile uint32_t bufferCount = 0;

volatile bool countingEnabled = false;

uint32_t sessao_id = 0;

// ------------------------------------------------------------
// TIMER DO MOTOR
// ------------------------------------------------------------
hw_timer_t* motorTimer = NULL;

volatile bool stepEnabled = false;
volatile bool stepState = false;

portMUX_TYPE timerMux = portMUX_INITIALIZER_UNLOCKED;

// ------------------------------------------------------------
// MQTT
// ------------------------------------------------------------
WiFiClient wifiClient;
PubSubClient client(wifiClient);

String topic_cmd;
String topic_motor;
String topic_status;

// ============================================================
// CÁLCULO DA FREQUÊNCIA DO STEP
// ============================================================

uint32_t rpmToHalfPeriodUs(int rpm) {

  if (rpm < 1) {
    rpm = 1;
  }

  /*
     Exemplo:

     200 passos/rev
     50 RPM

     passos/s =
       200 * 50 / 60
       = 166,67 pulsos/s

     Como a ISR alterna HIGH/LOW,
     usamos metade do período.
  */

  long stepsPerRev =
      (long)FULL_STEPS_PER_REV * MICROSTEP;

  double stepsPerSecond =
      ((double)rpm * stepsPerRev) / 60.0;

  double periodUs =
      1000000.0 / stepsPerSecond;

  double halfPeriodUs =
      periodUs / 2.0;

  // Proteção
  if (halfPeriodUs < 100) {
    halfPeriodUs = 100;
  }

  return (uint32_t)halfPeriodUs;
}

// ============================================================
// ISR DO MOTOR
// ============================================================

void IRAM_ATTR motorISR() {

  if (!stepEnabled) {
    return;
  }

  stepState = !stepState;

  digitalWrite(STEP_PIN, stepState ? HIGH : LOW);
}

// ============================================================
// CONFIGURA TIMER
// ============================================================

void setupMotorTimer() {

  motorTimer = timerBegin(1000000);

  timerAttachInterrupt(
      motorTimer,
      &motorISR
  );

  timerAlarm(
      motorTimer,
      rpmToHalfPeriodUs(START_RPM),
      true,
      0
  );

  timerStart(motorTimer);
}

// ============================================================
// ATUALIZA VELOCIDADE
// ============================================================

void updateMotorTimer(int rpm) {

  if (!motorTimer) {
    return;
  }

  timerAlarm(
      motorTimer,
      rpmToHalfPeriodUs(rpm),
      true,
      0
  );
}

// ============================================================
// HABILITA DRIVER
// ============================================================

void enableDriver() {

  /*
     DRV8825:

     EN = LOW  -> habilitado
     EN = HIGH -> desabilitado
  */

  digitalWrite(EN_PIN, LOW);

  delay(2);
}

// ============================================================
// DESABILITA DRIVER
// ============================================================

void disableDriver() {

  stepEnabled = false;

  digitalWrite(STEP_PIN, LOW);

  stepState = false;

  digitalWrite(EN_PIN, HIGH);
}

// ============================================================
// DIREÇÃO
// ============================================================

void setMotorDirection(int dir) {

  motorDir = dir ? 1 : 0;

  digitalWrite(
      DIR_PIN,
      motorDir ? HIGH : LOW
  );

  delay(2);
}

// ============================================================
// START MOTOR
// ============================================================

void motorStart() {

  if (motorRequested) {
    return;
  }

  Serial.println();
  Serial.println("==============================");
  Serial.println("MOTOR START");
  Serial.println("==============================");

  motorRequested = true;

  setMotorDirection(motorDir);

  enableDriver();

  currentRPM = START_RPM;

  updateMotorTimer(currentRPM);

  stepEnabled = true;

  motorRunning = true;

  Serial.printf(
      "RPM inicial: %d\n",
      currentRPM
  );
}

// ============================================================
// SOLICITA STOP
// ============================================================

void motorStop() {

  if (!motorRequested &&
      !motorRunning) {

    return;
  }

  Serial.println();
  Serial.println("==============================");
  Serial.println("MOTOR STOP solicitado");
  Serial.println("==============================");

  motorRequested = false;
}

// ============================================================
// TASK DO MOTOR
// ============================================================

void motorTask(void* param) {

  unsigned long lastRamp = 0;

  for (;;) {

    unsigned long now = millis();

    // --------------------------------------------------------
    // MOTOR DEVE GIRAR
    // --------------------------------------------------------

    if (motorRequested) {

      if (!motorRunning) {

        enableDriver();

        currentRPM = START_RPM;

        updateMotorTimer(currentRPM);

        stepEnabled = true;

        motorRunning = true;
      }

      // ------------------------------------------------------
      // RAMPA DE ACELERAÇÃO
      // ------------------------------------------------------

      if (currentRPM < targetRPM) {

        if (now - lastRamp >= RAMP_INTERVAL_MS) {

          currentRPM += RAMP_STEP_RPM;

          if (currentRPM > targetRPM) {
            currentRPM = targetRPM;
          }

          updateMotorTimer(currentRPM);

          lastRamp = now;
        }
      }

      // ------------------------------------------------------
      // DIMINUI RPM SE O PAINEL REDUZIR
      // ------------------------------------------------------

      else if (currentRPM > targetRPM) {

        if (now - lastRamp >= RAMP_INTERVAL_MS) {

          currentRPM -= RAMP_STEP_RPM;

          if (currentRPM < targetRPM) {
            currentRPM = targetRPM;
          }

          updateMotorTimer(currentRPM);

          lastRamp = now;
        }
      }
    }

    // --------------------------------------------------------
    // MOTOR DEVE PARAR
    // --------------------------------------------------------

    else {

      if (motorRunning) {

        // rampa de desaceleração
        if (currentRPM > START_RPM) {

          if (now - lastRamp >= RAMP_INTERVAL_MS) {

            currentRPM -= RAMP_STEP_RPM;

            if (currentRPM < START_RPM) {
              currentRPM = START_RPM;
            }

            updateMotorTimer(currentRPM);

            lastRamp = now;
          }
        }

        else {

          stepEnabled = false;

          currentRPM = 0;

          motorRunning = false;

          disableDriver();

          Serial.println(
              "Motor completamente parado."
          );
        }
      }
    }

    vTaskDelay(pdMS_TO_TICKS(5));
  }
}

// ============================================================
// SENSOR
// ============================================================

void IRAM_ATTR sensorISR() {

  uint32_t now = millis();

  if (!countingEnabled) {
    return;
  }

  if (now - lastTrigger <= REFRACT_MS) {
    return;
  }

  portENTER_CRITICAL_ISR(&timerMux);

  bufferCount++;

  portEXIT_CRITICAL_ISR(&timerMux);

  lastTrigger = now;
}

// ============================================================
// URL API
// ============================================================

String apiURL() {

  String url = "http://";

  url += api_host;
  url += ":";
  url += String(api_port);
  url += api_path;

  return url;
}

// ============================================================
// ENVIA CONTAGEM PARA API
// ============================================================

bool postBatch(uint32_t inc) {

  if (inc == 0) {
    return true;
  }

  if (sessao_id == 0) {
    return false;
  }

  if (WiFi.status() != WL_CONNECTED) {
    return false;
  }

  HTTPClient http;

  http.begin(apiURL());

  http.addHeader(
      "Content-Type",
      "application/json"
  );

  StaticJsonDocument<256> doc;

  doc["sessao_id"] = sessao_id;
  doc["device_code"] = device_code;
  doc["inc"] = inc;

  String payload;

  serializeJson(
      doc,
      payload
  );

  int code =
      http.POST(payload);

  http.end();

  return (
      code >= 200 &&
      code < 300
  );
}

// ============================================================
// PUBLICA STATUS MOTOR
// ============================================================

void publishMotorStatus() {

  if (!client.connected()) {
    return;
  }

  StaticJsonDocument<256> doc;

  doc["type"] = "motor_config";

  doc["rpm"] =
      targetRPM;

  doc["current_rpm"] =
      currentRPM;

  doc["dir"] =
      motorDir;

  doc["motor_enabled"] =
      motorRequested;

  doc["motor_running"] =
      motorRunning;

  doc["counting"] =
      countingEnabled;

  String output;

  serializeJson(
      doc,
      output
  );

  client.publish(
      topic_status.c_str(),
      output.c_str(),
      true
  );
}

// ============================================================
// CONFIGURAÇÃO RECEBIDA VIA MQTT
// ============================================================

void applyMotorConfig(JsonDocument& doc) {

  // ----------------------------------------------------------
  // RPM
  // ----------------------------------------------------------

  if (!doc["rpm"].isNull()) {

    int rpm =
        doc["rpm"].as<int>();

    if (rpm < MIN_RPM) {
      rpm = MIN_RPM;
    }

    if (rpm > MAX_RPM) {
      rpm = MAX_RPM;
    }

    targetRPM = rpm;

    Serial.printf(
        "Nova RPM alvo: %d\n",
        targetRPM
    );
  }

  // ----------------------------------------------------------
  // DIREÇÃO
  // ----------------------------------------------------------

  if (!doc["dir"].isNull()) {

    int newDir =
        doc["dir"].as<int>() ? 1 : 0;

    /*
       Não alteramos DIR instantaneamente
       enquanto o motor gira.

       Para teste, somente altera parado.
    */

    if (!motorRunning) {

      motorDir = newDir;

      setMotorDirection(
          motorDir
      );

      Serial.printf(
          "Nova direcao: %d\n",
          motorDir
      );
    }

    else if (newDir != motorDir) {

      Serial.println(
          "Direcao ignorada: pare o motor antes de inverter."
      );
    }
  }

  // ----------------------------------------------------------
  // motor_enabled
  // ----------------------------------------------------------

  if (!doc["motor_enabled"].isNull()) {

    bool enabled =
        doc["motor_enabled"].as<bool>();

    if (enabled) {
      motorStart();
    }
    else {
      motorStop();
    }
  }

  publishMotorStatus();
}

// ============================================================
// START DE SESSÃO
// ============================================================

void handleStart(uint32_t id) {

  sessao_id = id;

  countingEnabled = true;

  motorStart();

  Serial.printf(
      "START sessao %u\n",
      id
  );

  publishMotorStatus();
}

// ============================================================
// STOP DE SESSÃO
// ============================================================

void handleStop(uint32_t id) {

  countingEnabled = false;

  motorStop();

  Serial.printf(
      "STOP sessao %u\n",
      id
  );

  publishMotorStatus();
}

// ============================================================
// CALLBACK MQTT
// ============================================================

void mqttCallback(
    char* topic,
    byte* payload,
    unsigned int length
) {

  String msg;

  for (
      unsigned int i = 0;
      i < length;
      i++
  ) {

    msg +=
        (char)payload[i];
  }

  Serial.println();
  Serial.printf(
      "MQTT [%s]: %s\n",
      topic,
      msg.c_str()
  );

  StaticJsonDocument<512> doc;

  DeserializationError error =
      deserializeJson(
          doc,
          msg
      );

  if (error) {

    Serial.println(
        "JSON MQTT invalido."
    );

    return;
  }

  const char* action =
      doc["action"] | "";

  uint32_t s_id =
      doc["sessao_id"] | 0;

  // ----------------------------------------------------------
  // START
  // ----------------------------------------------------------

  if (
      strcmp(
          action,
          "start"
      ) == 0
  ) {

    applyMotorConfig(doc);

    handleStart(s_id);

    return;
  }

  // ----------------------------------------------------------
  // STOP
  // ----------------------------------------------------------

  if (
      strcmp(
          action,
          "stop"
      ) == 0
  ) {

    handleStop(s_id);

    return;
  }

  // ----------------------------------------------------------
  // CONFIG
  // ----------------------------------------------------------

  if (
      strcmp(
          action,
          "config"
      ) == 0
  ) {

    applyMotorConfig(doc);

    return;
  }

  // ----------------------------------------------------------
  // TÓPICO /motor
  // ----------------------------------------------------------

  String receivedTopic =
      String(topic);

  if (
      receivedTopic.endsWith(
          "/motor"
      )
  ) {

    applyMotorConfig(doc);

    return;
  }
}

// ============================================================
// MQTT RECONNECT
// ============================================================

void mqttReconnect() {

  while (!client.connected()) {

    Serial.print(
        "Conectando MQTT..."
    );

    String clientId =
        String("esteira-") +
        WiFi.macAddress();

    clientId.replace(
        ":",
        ""
    );

    if (
        client.connect(
            clientId.c_str()
        )
    ) {

      Serial.println("OK");

      client.subscribe(
          topic_cmd.c_str()
      );

      client.subscribe(
          topic_motor.c_str()
      );

      publishMotorStatus();
    }

    else {

      Serial.printf(
          "falha rc=%d\n",
          client.state()
      );

      delay(2000);
    }
  }
}

// ============================================================
// TASK DE REDE
// ============================================================

void networkTask(void* param) {

  unsigned long lastPost =
      millis();

  for (;;) {

    // MQTT
    if (!client.connected()) {

      mqttReconnect();
    }

    client.loop();

    // --------------------------------------------------------
    // ENVIO DA CONTAGEM
    // --------------------------------------------------------

    if (
        millis() - lastPost >= 1000
    ) {

      uint32_t count = 0;

      portENTER_CRITICAL(
          &timerMux
      );

      count =
          bufferCount;

      bufferCount = 0;

      portEXIT_CRITICAL(
          &timerMux
      );

      if (count > 0) {

        if (!postBatch(count)) {

          // devolve ao buffer se falhar
          portENTER_CRITICAL(
              &timerMux
          );

          bufferCount += count;

          portEXIT_CRITICAL(
              &timerMux
          );
        }
        else {

          Serial.printf(
              "Contagem enviada: %u\n",
              count
          );
        }
      }

      lastPost =
          millis();
    }

    vTaskDelay(
        pdMS_TO_TICKS(20)
    );
  }
}

// ============================================================
// SETUP
// ============================================================

void setup() {

  Serial.begin(115200);

  delay(500);

  Serial.println();
  Serial.println(
      "================================"
  );

  Serial.println(
      "AUTCONT - DRV8825"
  );

  Serial.println(
      "================================"
  );

  // ----------------------------------------------------------
  // PINOS MOTOR
  // ----------------------------------------------------------

  pinMode(
      STEP_PIN,
      OUTPUT
  );

  pinMode(
      DIR_PIN,
      OUTPUT
  );

  pinMode(
      EN_PIN,
      OUTPUT
  );

  digitalWrite(
      STEP_PIN,
      LOW
  );

  digitalWrite(
      DIR_PIN,
      motorDir ? HIGH : LOW
  );

  // começa DESABILITADO
  digitalWrite(
      EN_PIN,
      HIGH
  );

  // ----------------------------------------------------------
  // SENSOR
  // ----------------------------------------------------------

  pinMode(
      SENSOR_PIN,
      INPUT
  );

  attachInterrupt(
      digitalPinToInterrupt(
          SENSOR_PIN
      ),
      sensorISR,
      RISING
  );

  // ----------------------------------------------------------
  // TIMER MOTOR
  // ----------------------------------------------------------

  setupMotorTimer();

  // ----------------------------------------------------------
  // TASK MOTOR
  // ----------------------------------------------------------

  xTaskCreatePinnedToCore(
      motorTask,
      "motorTask",
      4096,
      NULL,
      2,
      NULL,
      1
  );

  // ----------------------------------------------------------
  // WIFI
  // ----------------------------------------------------------

  WiFi.begin(
      ssid,
      password
  );

  Serial.print(
      "Conectando WiFi"
  );

  while (
      WiFi.status() !=
      WL_CONNECTED
  ) {

    Serial.print(".");

    delay(300);
  }

  Serial.println();

  Serial.print(
      "IP: "
  );

  Serial.println(
      WiFi.localIP()
  );

  // ----------------------------------------------------------
  // MQTT
  // ----------------------------------------------------------

  client.setServer(
      mqtt_server,
      mqtt_port
  );

  client.setCallback(
      mqttCallback
  );

  client.setBufferSize(512);

  String base =
      String(
          "factory/default/line/1/device/"
      )
      +
      device_code;

  topic_cmd =
      base + "/cmd";

  topic_motor =
      base + "/motor";

  topic_status =
      base + "/status";

  // ----------------------------------------------------------
  // TASK REDE
  // ----------------------------------------------------------

  xTaskCreatePinnedToCore(
      networkTask,
      "networkTask",
      8192,
      NULL,
      1,
      NULL,
      0
  );

  Serial.println();
  Serial.println(
      "Sistema pronto."
  );

  Serial.println(
      "Motor aguardando comando MQTT."
  );

  Serial.printf(
      "STEP GPIO: %d\n",
      STEP_PIN
  );

  Serial.printf(
      "DIR GPIO: %d\n",
      DIR_PIN
  );

  Serial.printf(
      "ENABLE GPIO: %d\n",
      EN_PIN
  );

  Serial.printf(
      "RPM alvo: %d\n",
      targetRPM
  );
}

// ============================================================
// LOOP
// ============================================================

void loop() {

  delay(1000);

  // diagnóstico periódico
  if (motorRunning) {

    Serial.printf(
        "[MOTOR] RPM=%d alvo=%d DIR=%d EN=%d\n",
        currentRPM,
        targetRPM,
        motorDir,
        digitalRead(EN_PIN)
    );
  }
}