import streamlit as st
from datetime import datetime

st.set_page_config(
    page_title="🍾 CRIA Bebidas Dashboard",
    layout="wide",
    initial_sidebar_state="expanded"
)

# ==========================================
# CABEÇALHO
# ==========================================
st.title("🍾 CRIA Bebidas")
st.markdown("#### Painel Integrado de Produção e Análise")
st.divider()

# ==========================================
# CARDS DE RESUMO GERAL
# ==========================================
col1, col2, col3, col4 = st.columns(4)

col1.metric("Sessões Ativas", "3", "↑ 1 hoje")
col2.metric("Produção Total", "12.480", "+320")
col3.metric("Clientes Ativos", "5")
col4.metric("Dispositivos Online", "4 / 5")

st.markdown("### 📦 Estatísticas Gerais")

col_a, col_b = st.columns([2, 1])
with col_a:
    st.image("https://cdn-icons-png.flaticon.com/512/3500/3500833.png", width=60)
    st.markdown("""
    **Bem-vindo ao Painel CRIA Bebidas!**
    
    Acompanhe a produção em tempo real, configure parâmetros da linha e visualize métricas de desempenho industrial integradas.
    """)
with col_b:
    st.info(f"📅 Atualizado em: {datetime.now().strftime('%d/%m/%Y %H:%M:%S')}")

st.markdown("---")

# ==========================================
# LINKS DE NAVEGAÇÃO
# ==========================================
st.markdown("""
### 🔗 Seções do Sistema

- 📊 [**Estatísticas Gerais**](Estatísticas_Gerais)
- ⚙️ [**Operação e Filtros Avançados**](Operação_e_Filtros)
""")

st.caption("Softpop Sistemas • Projeto CRIA Bebidas • Edge IoT & MQTT")
