import streamlit as st
import pandas as pd
import requests
from datetime import datetime, timedelta

API_URL = "http://127.0.0.1:5000"

st.title("📊 Estatísticas Gerais")

def get_json(endpoint):
    try:
        r = requests.get(f"{API_URL}{endpoint}")
        return r.json() if r.status_code == 200 else []
    except:
        return []

# Dados básicos
sessoes = get_json("/sessoes")
rows = sessoes.get("rows", []) if isinstance(sessoes, dict) else sessoes
df = pd.DataFrame(rows)

if df.empty:
    st.warning("Nenhuma sessão encontrada.")
    st.stop()

# --- KPIs ---
total = df["total"].sum()
ativas = (df["status"] == "ativa").sum()
finalizadas = (df["status"] == "finalizada").sum()

col1, col2, col3 = st.columns(3)
col1.metric("Produção Total", total)
col2.metric("Sessões Ativas", ativas)
col3.metric("Finalizadas", finalizadas)

st.divider()

# --- GRÁFICOS ---
df["inicio"] = pd.to_datetime(df["inicio"])
df["dia"] = df["inicio"].dt.date
prod_por_dia = df.groupby("dia")["total"].sum().reset_index()

st.subheader("📈 Produção por Dia")
st.line_chart(prod_por_dia.set_index("dia")["total"], use_container_width=True)

# --- PRODUÇÃO POR CLIENTE ---
prod_por_cliente = df.groupby("cliente")["total"].sum().sort_values(ascending=False)
st.subheader("🏭 Produção por Cliente")
st.bar_chart(prod_por_cliente, use_container_width=True)

st.caption("📅 Dados agregados a partir das sessões registradas no sistema.")
