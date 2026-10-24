# 🏭 Sistema de Contagem de Garrafas - Diagrama Visual

## Para visualizar como imagem, use um dos seguintes métodos:

### 1. **Mermaid Live Editor** (Recomendado)
Acesse: https://mermaid.live/
Cole o código abaixo:

```mermaid
graph TB
    %% Frontend Flutter
    subgraph "📱 FRONTEND - Flutter App"
        A["🏠 HomePage<br/>Painel Principal"]
        B["📝 SelectSessionPage<br/>Criar Sessão"]
        C["⏱️ SessionPage<br/>Controle Tempo Real"]
        D["📊 HistoryPage<br/>Histórico"]
        E["⚙️ SettingsPage<br/>Configurações"]
    end

    %% Backend Flask
    subgraph "🐍 BACKEND - Flask API"
        F["🌐 Flask App<br/>Port 5000"]
        G["🔗 REST Endpoints<br/>/sessoes, /leituras"]
        H["📡 MQTT Publisher<br/>Comandos ESP32"]
    end

    %% Banco de Dados
    subgraph "🗄️ BANCO DE DADOS MySQL"
        I[("📋 sessoes_producao<br/>Sessões")]
        J[("📊 leituras<br/>Dados Sensor")]
        K[("👥 clientes<br/>Clientes")]
        L[("📦 produtos<br/>Produtos")]
        M[("🔧 dispositivos<br/>Dispositivos")]
    end

    %% MQTT Broker
    subgraph "📡 MQTT BROKER"
        N["📡 MQTT Server<br/>Port 1883"]
        O["📢 Topic: factory/default/line/1/<br/>device/esteira1/cmd"]
    end

    %% Dispositivo ESP32
    subgraph "⚙️ DISPOSITIVO ESP32"
        P["📶 WiFi Connection"]
        Q["👁️ Sensor E18-D80NK<br/>Detecção Garrafas"]
        R["⚙️ Motor Stepper<br/>Controle Esteira"]
        S["🌐 HTTP Client<br/>Envio Leituras"]
        T["📡 MQTT Client<br/>Recebe Comandos"]
    end

    %% Rede
    subgraph "🌐 REDE LOCAL"
        U["📶 WiFi Network<br/>Espaço Cria"]
    end

    %% Fluxo HTTP/REST
    A -->|"HTTP GET/POST<br/>JSON"| F
    B -->|"HTTP GET/POST<br/>JSON"| F
    C -->|"HTTP GET/POST<br/>JSON"| F
    D -->|"HTTP GET/POST<br/>JSON"| F
    E -->|"HTTP GET/POST<br/>JSON"| F

    %% Fluxo Database
    F -->|"SQL INSERT/SELECT"| I
    F -->|"SQL INSERT/SELECT"| J
    F -->|"SQL SELECT"| K
    F -->|"SQL SELECT"| L
    F -->|"SQL SELECT"| M

    %% Fluxo MQTT
    F -->|"MQTT Publish<br/>Comandos"| H
    H -->|"MQTT Message"| N
    N -->|"MQTT Topic"| O
    O -->|"MQTT Subscribe"| T

    %% Fluxo ESP32
    T -->|"Comandos start/stop"| P
    P -->|"Controle"| Q
    P -->|"Controle"| R
    Q -->|"Detecção Garrafas"| S
    S -->|"HTTP POST /leituras<br/>JSON"| F

    %% Conexões de Rede
    P -.->|"WiFi"| U
    F -.->|"Network"| U
    A -.->|"Network"| U

    %% Estilos
    classDef frontend fill:#e3f2fd,stroke:#1976d2,stroke-width:3px,color:#000
    classDef backend fill:#f3e5f5,stroke:#7b1fa2,stroke-width:3px,color:#000
    classDef database fill:#e8f5e8,stroke:#388e3c,stroke-width:3px,color:#000
    classDef mqtt fill:#fff3e0,stroke:#f57c00,stroke-width:3px,color:#000
    classDef device fill:#fce4ec,stroke:#c2185b,stroke-width:3px,color:#000
    classDef network fill:#f1f8e9,stroke:#689f38,stroke-width:3px,color:#000

    class A,B,C,D,E frontend
    class F,G,H backend
    class I,J,K,L,M database
    class N,O mqtt
    class P,Q,R,S,T device
    class U network
```

### 2. **Draw.io / Diagrams.net**
Acesse: https://app.diagrams.net/
Use os componentes:
- Retângulos para componentes
- Círculos para banco de dados
- Setas para fluxo de dados
- Cores diferentes para cada camada

### 3. **Lucidchart**
Acesse: https://lucidchart.com/
Crie um diagrama de arquitetura com:
- Componentes de frontend (azul)
- Backend (roxo)
- Banco de dados (verde)
- MQTT (laranja)
- Dispositivos (rosa)

## 🎨 Cores Sugeridas:
- **Frontend**: Azul (#e3f2fd)
- **Backend**: Roxo (#f3e5f5)
- **Banco de Dados**: Verde (#e8f5e8)
- **MQTT**: Laranja (#fff3e0)
- **Dispositivos**: Rosa (#fce4ec)
- **Rede**: Verde claro (#f1f8e9)

## 📋 Componentes para Incluir:

### Frontend (Flutter)
- HomePage
- SelectSessionPage
- SessionPage
- HistoryPage
- SettingsPage

### Backend (Flask)
- Flask App
- REST Endpoints
- MQTT Publisher

### Banco de Dados
- sessoes_producao
- leituras
- clientes
- produtos
- dispositivos

### MQTT
- MQTT Server
- Topics

### Dispositivo ESP32
- WiFi Connection
- Sensor E18-D80NK
- Motor Stepper
- HTTP Client
- MQTT Client

### Rede
- WiFi Network

## 🔄 Fluxos de Dados:
1. **HTTP/REST**: Flutter ↔ Flask API
2. **SQL**: Flask API ↔ MySQL
3. **MQTT**: Flask API ↔ ESP32
4. **HTTP POST**: ESP32 → Flask API
5. **WiFi**: Rede local
