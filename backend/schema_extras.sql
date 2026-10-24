-- View de totais por sessão (contagem + pesagem)
CREATE OR REPLACE VIEW vw_totais_sessao AS
SELECT s.id AS sessao_id,
       COALESCE(SUM(l.contagem_incremental), 0) AS total,
       COALESCE(AVG(l.temp_amb), 0) AS avg_temp_amb,
       COALESCE(AVG(l.temp_obj), 0) AS avg_temp_obj
FROM sessoes_producao s
LEFT JOIN leituras l ON l.sessao_id = s.id
GROUP BY s.id;

-- Colunas de pesagem na sessão (idempotente via procedure simples)
-- Execute uma vez; ignore erro se coluna já existir.
-- ALTER TABLE sessoes_producao ADD COLUMN peso_total_g DECIMAL(12,2) NULL;
-- ALTER TABLE sessoes_producao ADD COLUMN peso_medio_g DECIMAL(12,3) NULL;
-- ALTER TABLE sessoes_producao ADD COLUMN pesagem_status VARCHAR(32) NULL DEFAULT 'pendente';
-- ALTER TABLE sessoes_producao ADD COLUMN pesagem_em DATETIME NULL;
-- ALTER TABLE sessoes_producao ADD COLUMN peso_unitario_ref_g DECIMAL(12,3) NULL;

-- Tabela de pesagens individuais (esteira de peso)
CREATE TABLE IF NOT EXISTS pesagens (
  id BIGINT AUTO_INCREMENT PRIMARY KEY,
  sessao_id INT NOT NULL,
  item_seq INT NOT NULL,
  peso_g DECIMAL(12,3) NOT NULL,
  simulado TINYINT(1) NOT NULL DEFAULT 1,
  criado_em DATETIME NOT NULL,
  INDEX idx_pesagens_sessao (sessao_id),
  CONSTRAINT fk_pesagens_sessao FOREIGN KEY (sessao_id)
    REFERENCES sessoes_producao(id) ON DELETE CASCADE
);

-- Índice composto (acelera inserts/consultas por sessão/tempo)
-- CREATE INDEX IF NOT EXISTS idx_leituras_sessao_ts ON leituras (sessao_id, timestamp);

-- Configuração ao vivo do motor (por dispositivo). Padrões = firmware.
CREATE TABLE IF NOT EXISTS configuracao_motor (
  dispositivo_codigo VARCHAR(64) NOT NULL PRIMARY KEY,
  rpm INT NOT NULL,
  direcao TINYINT(1) NOT NULL DEFAULT 0,
  hold TINYINT(1) NOT NULL DEFAULT 1,
  min_half_us INT NOT NULL DEFAULT 400,
  motor_enabled TINYINT(1) NOT NULL DEFAULT 1,
  atualizado_em DATETIME NOT NULL
);
