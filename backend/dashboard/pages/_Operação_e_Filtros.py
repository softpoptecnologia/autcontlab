import os
import streamlit as st
import pandas as pd
import requests
from datetime import datetime, timedelta

API_URL = os.getenv("API_URL", "http://127.0.0.1:5000")

st.title("⚙️ Operação e Filtros Avançados")

def get_json(endpoint):
    try:
        r = requests.get(f"{API_URL}{endpoint}")
        return r.json() if r.status_code == 200 else []
    except:
        return []

# --- FILTROS ---
clientes = get_json("/clientes")
produtos = get_json("/produtos")
cliente_opts = {"Todos": None} | {c["nome"]: c["id"] for c in clientes}
produto_opts = {"Todos": None} | {p["nome"]: p["id"] for p in produtos}
status_opts = {"Todos": None, "Ativa": "ativa", "Finalizada": "finalizada"}

st.sidebar.header("🎛️ Filtros de Produção")

sel_cliente = st.sidebar.selectbox("Cliente", list(cliente_opts.keys()))
sel_produto = st.sidebar.selectbox("Produto", list(produto_opts.keys()))
sel_status = st.sidebar.selectbox("Status", list(status_opts.keys()))
col1, col2 = st.sidebar.columns(2)
inicio_de = col1.date_input("De", datetime.now() - timedelta(days=7))
inicio_ate = col2.date_input("Até", datetime.now())

# --- FILTRAR SESSÕES ---
params = []
if cliente_opts[sel_cliente]:
    params.append(f"cliente_id={cliente_opts[sel_cliente]}")
if produto_opts[sel_produto]:
    params.append(f"produto_id={produto_opts[sel_produto]}")
if status_opts[sel_status]:
    params.append(f"status={status_opts[sel_status]}")
if inicio_de:
    params.append(f"inicio_de={inicio_de}")
if inicio_ate:
    params.append(f"inicio_ate={inicio_ate}")
query_str = "?" + "&".join(params) if params else ""

sessoes = get_json(f"/sessoes{query_str}")
rows = sessoes.get("rows", []) if isinstance(sessoes, dict) else sessoes

if not rows:
    st.warning("Nenhuma sessão encontrada com os filtros.")
    st.stop()

df = pd.DataFrame(rows)
df["inicio"] = pd.to_datetime(df["inicio"])
df["fim"] = pd.to_datetime(df["fim"])

st.dataframe(df[["id", "cliente", "produto", "lote", "status", "total"]],
             use_container_width=True, hide_index=True)

st.caption("Filtros avançados aplicados ao histórico de produção.")
