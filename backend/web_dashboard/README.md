# Dashboard Web - CRIA Bebidas

Dashboard web desenvolvido com Flask e AdminLTE para visualização e administração do sistema de contagem de garrafas.

## Estrutura

```
backend/
├── web_dashboard/
│   ├── __init__.py
│   ├── routes.py          # Rotas e APIs do dashboard
│   └── README.md
├── templates/
│   └── dashboard/
│       ├── base.html      # Template base com AdminLTE
│       ├── index.html     # Página principal (estatísticas ao vivo)
│       ├── filtros.html   # Página de filtros e histórico
│       └── cadastros.html  # Página de cadastros (produtos e clientes)
└── app.py                 # App Flask principal (registra o blueprint)
```

## Funcionalidades

### 1. Dashboard Principal (`/dashboard/`)
- **Estatísticas em tempo real:**
  - Sessões ativas
  - Produção do dia
  - Produção total
  - Sessões finalizadas hoje

- **Gráficos:**
  - Produção por dia (últimos 30 dias)
  - Top 10 clientes
  - Top 10 produtos

- **Leituras ao vivo:**
  - Últimas 20 leituras em tempo real
  - Atualização automática a cada 5 segundos

### 2. Filtros e Histórico (`/dashboard/filtros`)
- **Filtros avançados:**
  - Cliente
  - Produto
  - Status (ativa/finalizada)
  - Período (data início de/até)

- **Exportação:**
  - Exportar para Excel (.xlsx)
  - Exportar para PDF (.pdf)

### 3. Cadastros (`/dashboard/cadastros`)
- **CRUD de Produtos:**
  - Criar
  - Editar
  - Excluir
  - Listar

- **CRUD de Clientes:**
  - Criar
  - Editar
  - Excluir
  - Listar

## APIs Disponíveis

### Estatísticas
- `GET /dashboard/api/stats/live` - Estatísticas em tempo real
- `GET /dashboard/api/stats/leituras-live` - Últimas leituras ao vivo
- `GET /dashboard/api/stats/graficos` - Dados para gráficos

### Filtros
- `GET /dashboard/api/filtros/sessoes` - Lista sessões com filtros
- `GET /dashboard/api/filtros/export-excel` - Exporta Excel
- `GET /dashboard/api/filtros/export-pdf` - Exporta PDF

### Produtos
- `GET /dashboard/api/produtos` - Lista produtos
- `POST /dashboard/api/produtos` - Cria produto
- `PUT /dashboard/api/produtos/<id>` - Atualiza produto
- `DELETE /dashboard/api/produtos/<id>` - Deleta produto

### Clientes
- `GET /dashboard/api/clientes` - Lista clientes
- `POST /dashboard/api/clientes` - Cria cliente
- `PUT /dashboard/api/clientes/<id>` - Atualiza cliente
- `DELETE /dashboard/api/clientes/<id>` - Deleta cliente

## Dependências

As dependências já foram adicionadas ao `requirements.txt`:
- `openpyxl==3.1.2` - Para exportação Excel
- `reportlab==4.0.7` - Para exportação PDF

## Acesso

Após iniciar o servidor Flask, acesse:
- **Dashboard:** http://localhost:5000/dashboard/
- **Filtros:** http://localhost:5000/dashboard/filtros
- **Cadastros:** http://localhost:5000/dashboard/cadastros

## Tecnologias Utilizadas

- **Backend:** Flask (Python)
- **Frontend:** AdminLTE 3.2 (Bootstrap 4)
- **Gráficos:** Chart.js 4.4.0
- **Exportação:** openpyxl (Excel), reportlab (PDF)

## Notas

- O dashboard usa AdminLTE via CDN (não precisa instalar localmente)
- As estatísticas são atualizadas automaticamente a cada 5 segundos
- Os gráficos são atualizados a cada 30 segundos
- As exportações respeitam os filtros aplicados


