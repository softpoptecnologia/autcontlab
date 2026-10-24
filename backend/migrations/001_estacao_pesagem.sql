-- Migração incremental AUTCONT: pesagem real + status da estação
-- Idempotente o quanto possível; ignore erros de "já existe".

ALTER TABLE pesagens ADD COLUMN cycle_id VARCHAR(64) NULL;
ALTER TABLE pesagens ADD COLUMN produto_seq INT NULL;
ALTER TABLE pesagens ADD COLUMN peso_estavel TINYINT(1) NULL DEFAULT 1;
ALTER TABLE pesagens ADD COLUMN temp_amb DECIMAL(8,2) NULL;
ALTER TABLE pesagens ADD COLUMN temp_obj DECIMAL(8,2) NULL;
ALTER TABLE pesagens ADD COLUMN buzzer_acionado TINYINT(1) NULL DEFAULT 0;
ALTER TABLE pesagens ADD COLUMN status VARCHAR(32) NULL DEFAULT 'pesado';
ALTER TABLE pesagens ADD COLUMN dispositivo_id INT NULL;

-- CREATE UNIQUE INDEX uq_pesagens_sessao_cycle ON pesagens (sessao_id, cycle_id);

CREATE TABLE IF NOT EXISTS dispositivo_status (
  dispositivo_codigo VARCHAR(64) NOT NULL PRIMARY KEY,
  payload_json JSON NULL,
  cycle_state VARCHAR(48) NULL,
  peso_atual_g DECIMAL(12,3) NULL,
  ultimo_peso_g DECIMAL(12,3) NULL,
  peso_acumulado_g DECIMAL(12,3) NULL,
  detectados INT NULL DEFAULT 0,
  pesados INT NULL DEFAULT 0,
  hx711_ok TINYINT(1) NULL,
  mlx_ok TINYINT(1) NULL,
  buzzer_enabled TINYINT(1) NULL,
  motor_running TINYINT(1) NULL,
  rpm INT NULL,
  temp_amb DECIMAL(8,2) NULL,
  temp_obj DECIMAL(8,2) NULL,
  falha VARCHAR(128) NULL,
  atualizado_em DATETIME NOT NULL
);
