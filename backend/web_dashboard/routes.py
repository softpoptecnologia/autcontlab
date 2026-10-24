"""
Rotas do Dashboard Web com AdminLTE
"""
from flask import Blueprint, render_template, jsonify, request, send_file
from datetime import datetime, timedelta, date
from db import one, all_, exec_
import io

# Blueprint para o dashboard
dashboard_bp = Blueprint('dashboard', __name__, url_prefix='/dashboard')

# ==========================================
# PÁGINAS PRINCIPAIS
# ==========================================

@dashboard_bp.route('/')
def index():
    """Página principal do dashboard - Estatísticas ao vivo"""
    return render_template('dashboard/index.html')

@dashboard_bp.route('/filtros')
def filtros():
    """Página de filtros de contagens anteriores"""
    return render_template('dashboard/filtros.html')

@dashboard_bp.route('/cadastros')
def cadastros():
    """Página de cadastros (produtos e clientes)"""
    return render_template('dashboard/cadastros.html')

@dashboard_bp.route('/motor')
def motor():
    """Ajuste em tempo real dos parâmetros do motor da esteira"""
    return render_template('dashboard/motor.html')

@dashboard_bp.route('/estacao')
def estacao():
    """Monitoramento da estação ESP32 (esteira + balança + buzzer)"""
    return render_template('dashboard/estacao.html')

# ==========================================
# APIs - ESTATÍSTICAS EM TEMPO REAL
# ==========================================

@dashboard_bp.route('/api/stats/live')
def api_stats_live():
    """Estatísticas em tempo real"""
    try:
        # Sessões ativas
        ativas = all_("""
            SELECT COUNT(*) as total
            FROM sessoes_producao
            WHERE status = 'ativa'
        """)
        total_ativas = ativas[0]['total'] if ativas else 0
        
        # Produção do dia
        hoje = datetime.now().date()
        prod_dia = all_("""
            SELECT COALESCE(SUM(v.total), 0) as total
            FROM sessoes_producao s
            LEFT JOIN vw_totais_sessao v ON v.sessao_id = s.id
            WHERE DATE(s.inicio) = :hoje
        """, hoje=hoje)
        total_hoje = prod_dia[0]['total'] if prod_dia else 0
        
        # Produção total (todas as sessões)
        prod_total = all_("""
            SELECT COALESCE(SUM(v.total), 0) as total
            FROM sessoes_producao s
            LEFT JOIN vw_totais_sessao v ON v.sessao_id = s.id
        """)
        total_geral = prod_total[0]['total'] if prod_total else 0
        
        # Total de clientes
        clientes_count = all_("SELECT COUNT(*) as total FROM clientes")
        total_clientes = clientes_count[0]['total'] if clientes_count else 0
        
        # Total de produtos
        produtos_count = all_("SELECT COUNT(*) as total FROM produtos")
        total_produtos = produtos_count[0]['total'] if produtos_count else 0
        
        # Sessões finalizadas hoje
        finalizadas_hoje = all_("""
            SELECT COUNT(*) as total
            FROM sessoes_producao
            WHERE DATE(fim) = :hoje AND status = 'finalizada'
        """, hoje=hoje)
        total_finalizadas = finalizadas_hoje[0]['total'] if finalizadas_hoje else 0

        # Peso total do dia (simulado/real)
        peso_hoje = 0.0
        pesagens_concluidas = 0
        try:
            peso_rows = all_("""
                SELECT COALESCE(SUM(peso_total_g), 0) as peso,
                       COALESCE(SUM(CASE WHEN pesagem_status='concluida' THEN 1 ELSE 0 END),0) as n
                FROM sessoes_producao
                WHERE DATE(COALESCE(pesagem_em, fim, inicio)) = :hoje
            """, hoje=hoje)
            if peso_rows:
                peso_hoje = float(peso_rows[0].get('peso') or 0)
                pesagens_concluidas = int(peso_rows[0].get('n') or 0)
        except Exception:
            pass
        
        return jsonify({
            'sessoes_ativas': total_ativas,
            'producao_hoje': total_hoje,
            'producao_total': total_geral,
            'total_clientes': total_clientes,
            'total_produtos': total_produtos,
            'sessoes_finalizadas_hoje': total_finalizadas,
            'peso_hoje_kg': round(peso_hoje / 1000.0, 3),
            'pesagens_concluidas_hoje': pesagens_concluidas,
            'timestamp': datetime.now().isoformat()
        })
    except Exception as e:
        return jsonify({'error': str(e)}), 500

@dashboard_bp.route('/api/stats/sessoes-ativas')
def api_sessoes_ativas():
    """Todas as sessões com somatório acumulado"""
    try:
        # Busca todas as sessões (ativas e finalizadas) com totais acumulados
        sessoes = all_("""
            SELECT s.id as sessao_id,
                   s.inicio,
                   s.fim,
                   s.lote,
                   s.status,
                   c.nome as cliente,
                   p.nome as produto,
                   COALESCE(SUM(l.contagem_incremental), 0) as total_acumulado,
                   COUNT(l.id) as total_leituras,
                   COALESCE(AVG(l.temp_amb), 0) as temp_media_amb,
                   COALESCE(AVG(l.temp_obj), 0) as temp_media_obj,
                   s.peso_total_g,
                   s.peso_medio_g,
                   COALESCE(s.pesagem_status, 'pendente') as pesagem_status
            FROM sessoes_producao s
            JOIN clientes c ON c.id = s.cliente_id
            JOIN produtos p ON p.id = s.produto_id
            LEFT JOIN leituras l ON l.sessao_id = s.id
            GROUP BY s.id, s.inicio, s.fim, s.lote, s.status, c.nome, p.nome,
                     s.peso_total_g, s.peso_medio_g, s.pesagem_status
            ORDER BY s.id DESC
            LIMIT 100
        """)
        
        # Converte datas para string ISO
        for sessao in sessoes:
            if isinstance(sessao['inicio'], datetime):
                sessao['inicio'] = sessao['inicio'].isoformat()
            elif hasattr(sessao['inicio'], 'isoformat'):
                sessao['inicio'] = sessao['inicio'].isoformat()
            if sessao.get('fim'):
                if isinstance(sessao['fim'], datetime):
                    sessao['fim'] = sessao['fim'].isoformat()
                elif hasattr(sessao['fim'], 'isoformat'):
                    sessao['fim'] = sessao['fim'].isoformat()
            # Garante que valores são números
            sessao['total_acumulado'] = int(sessao['total_acumulado']) if sessao['total_acumulado'] else 0
            sessao['total_leituras'] = int(sessao['total_leituras']) if sessao['total_leituras'] else 0
            sessao['temp_media_amb'] = float(sessao['temp_media_amb']) if sessao['temp_media_amb'] else 0.0
            sessao['temp_media_obj'] = float(sessao['temp_media_obj']) if sessao['temp_media_obj'] else 0.0
            sessao['peso_total_g'] = float(sessao['peso_total_g']) if sessao.get('peso_total_g') else None
            sessao['peso_medio_g'] = float(sessao['peso_medio_g']) if sessao.get('peso_medio_g') else None
        
        return jsonify({'sessoes': sessoes})
    except Exception as e:
        # Se falhar (colunas de temperatura não existem), tenta sem elas
        try:
            sessoes = all_("""
                SELECT s.id as sessao_id,
                       s.inicio,
                       s.fim,
                       s.lote,
                       s.status,
                       c.nome as cliente,
                       p.nome as produto,
                       COALESCE(SUM(l.contagem_incremental), 0) as total_acumulado,
                       COUNT(l.id) as total_leituras,
                       0 as temp_media_amb,
                       0 as temp_media_obj
                FROM sessoes_producao s
                JOIN clientes c ON c.id = s.cliente_id
                JOIN produtos p ON p.id = s.produto_id
                LEFT JOIN leituras l ON l.sessao_id = s.id
                GROUP BY s.id, s.inicio, s.fim, s.lote, s.status, c.nome, p.nome
                ORDER BY s.id DESC
                LIMIT 100
            """)
            
            # Converte datas para string ISO
            for sessao in sessoes:
                if isinstance(sessao['inicio'], datetime):
                    sessao['inicio'] = sessao['inicio'].isoformat()
                elif hasattr(sessao['inicio'], 'isoformat'):
                    sessao['inicio'] = sessao['inicio'].isoformat()
                if sessao.get('fim'):
                    if isinstance(sessao['fim'], datetime):
                        sessao['fim'] = sessao['fim'].isoformat()
                    elif hasattr(sessao['fim'], 'isoformat'):
                        sessao['fim'] = sessao['fim'].isoformat()
                sessao['total_acumulado'] = int(sessao['total_acumulado']) if sessao['total_acumulado'] else 0
                sessao['total_leituras'] = int(sessao['total_leituras']) if sessao['total_leituras'] else 0
            
            return jsonify({'sessoes': sessoes})
        except Exception as e2:
            return jsonify({'error': str(e2)}), 500

@dashboard_bp.route('/api/stats/leituras-live')
def api_leituras_live():
    """Últimas leituras ao vivo"""
    try:
        # Tenta buscar com colunas de temperatura primeiro
        try:
            leituras = all_("""
                SELECT l.id, l.timestamp, l.contagem_incremental,
                       COALESCE(l.temp_amb, 0) as temp_amb,
                       COALESCE(l.temp_obj, 0) as temp_obj,
                       s.id as sessao_id, s.status,
                       c.nome as cliente, p.nome as produto,
                       d.codigo as dispositivo
                FROM leituras l
                JOIN sessoes_producao s ON s.id = l.sessao_id
                JOIN clientes c ON c.id = s.cliente_id
                JOIN produtos p ON p.id = s.produto_id
                LEFT JOIN dispositivos d ON d.id = l.dispositivo_id
                WHERE DATE(l.timestamp) >= DATE_SUB(CURDATE(), INTERVAL 1 DAY)
                ORDER BY l.timestamp DESC
                LIMIT 100
            """)
        except Exception:
            # Se falhar (colunas de temperatura não existem), busca sem elas
            leituras = all_("""
                SELECT l.id, l.timestamp, l.contagem_incremental,
                       0 as temp_amb,
                       0 as temp_obj,
                       s.id as sessao_id, s.status,
                       c.nome as cliente, p.nome as produto,
                       d.codigo as dispositivo
                FROM leituras l
                JOIN sessoes_producao s ON s.id = l.sessao_id
                JOIN clientes c ON c.id = s.cliente_id
                JOIN produtos p ON p.id = s.produto_id
                LEFT JOIN dispositivos d ON d.id = l.dispositivo_id
                WHERE DATE(l.timestamp) >= DATE_SUB(CURDATE(), INTERVAL 1 DAY)
                ORDER BY l.timestamp DESC
                LIMIT 100
            """)
        
        # Converte datas para string ISO
        for l in leituras:
            if isinstance(l['timestamp'], datetime):
                l['timestamp'] = l['timestamp'].isoformat()
            elif hasattr(l['timestamp'], 'isoformat'):
                l['timestamp'] = l['timestamp'].isoformat()
            # Garante que temperaturas são números
            if 'temp_amb' in l:
                l['temp_amb'] = float(l['temp_amb']) if l['temp_amb'] else 0.0
            if 'temp_obj' in l:
                l['temp_obj'] = float(l['temp_obj']) if l['temp_obj'] else 0.0
        
        return jsonify({'leituras': leituras})
    except Exception as e:
        return jsonify({'error': str(e)}), 500

@dashboard_bp.route('/api/stats/graficos')
def api_graficos():
    """Dados para gráficos"""
    try:
        # Produção por dia (últimos 30 dias)
        dias = all_("""
            SELECT DATE(s.inicio) as dia,
                   COALESCE(SUM(v.total), 0) as total
            FROM sessoes_producao s
            LEFT JOIN vw_totais_sessao v ON v.sessao_id = s.id
            WHERE s.inicio >= DATE_SUB(CURDATE(), INTERVAL 30 DAY)
            GROUP BY DATE(s.inicio)
            ORDER BY dia ASC
        """)
        
        # Converte datas para string ISO (formato YYYY-MM-DD)
        for d in dias:
            dia_val = d['dia']
            if isinstance(dia_val, (datetime, date)):
                d['dia'] = dia_val.strftime('%Y-%m-%d')
            elif hasattr(dia_val, 'isoformat'):
                d['dia'] = dia_val.isoformat()
            elif isinstance(dia_val, str):
                # Se já for string, garante formato correto
                if 'T' in dia_val:
                    d['dia'] = dia_val.split('T')[0]
                elif len(dia_val) == 10:
                    d['dia'] = dia_val
            else:
                d['dia'] = str(dia_val)
        
        # Produção por cliente
        por_cliente = all_("""
            SELECT c.nome as cliente,
                   COALESCE(SUM(v.total), 0) as total
            FROM sessoes_producao s
            JOIN clientes c ON c.id = s.cliente_id
            LEFT JOIN vw_totais_sessao v ON v.sessao_id = s.id
            GROUP BY c.id, c.nome
            ORDER BY total DESC
            LIMIT 10
        """)
        
        # Produção por produto
        por_produto = all_("""
            SELECT p.nome as produto,
                   COALESCE(SUM(v.total), 0) as total
            FROM sessoes_producao s
            JOIN produtos p ON p.id = s.produto_id
            LEFT JOIN vw_totais_sessao v ON v.sessao_id = s.id
            GROUP BY p.id, p.nome
            ORDER BY total DESC
            LIMIT 10
        """)
        
        return jsonify({
            'producao_por_dia': dias,
            'producao_por_cliente': por_cliente,
            'producao_por_produto': por_produto
        })
    except Exception as e:
        return jsonify({'error': str(e)}), 500

# ==========================================
# APIs - FILTROS E HISTÓRICO
# ==========================================

def _filtros_where():
    cliente_id = request.args.get('cliente_id', type=int)
    produto_id = request.args.get('produto_id', type=int)
    status = request.args.get('status')
    lote = (request.args.get('lote') or '').strip()
    q = (request.args.get('q') or '').strip()
    inicio_de = request.args.get('inicio_de')
    inicio_ate = request.args.get('inicio_ate')
    pesagem_status = request.args.get('pesagem_status')

    sql_extra = ""
    params = {}

    if cliente_id:
        sql_extra += " AND s.cliente_id = :cliente_id"
        params['cliente_id'] = cliente_id
    if produto_id:
        sql_extra += " AND s.produto_id = :produto_id"
        params['produto_id'] = produto_id
    if status:
        sql_extra += " AND s.status = :status"
        params['status'] = status
    if lote:
        sql_extra += " AND s.lote LIKE :lote"
        params['lote'] = f"%{lote}%"
    if q:
        sql_extra += " AND (c.nome LIKE :q OR p.nome LIKE :q OR s.lote LIKE :q OR CAST(s.id AS CHAR) LIKE :q)"
        params['q'] = f"%{q}%"
    if inicio_de:
        sql_extra += " AND DATE(s.inicio) >= :inicio_de"
        params['inicio_de'] = inicio_de
    if inicio_ate:
        sql_extra += " AND DATE(s.inicio) <= :inicio_ate"
        params['inicio_ate'] = inicio_ate
    if pesagem_status:
        sql_extra += " AND COALESCE(s.pesagem_status,'pendente') = :pesagem_status"
        params['pesagem_status'] = pesagem_status

    return sql_extra, params


def _sessoes_filtro_sql(limit=None):
    sql_extra, params = _filtros_where()
    sql = f"""
        SELECT s.id, s.inicio, s.fim, s.status, s.lote,
               c.nome as cliente, p.nome as produto,
               COALESCE(v.total, 0) as total,
               s.peso_total_g, s.peso_medio_g,
               COALESCE(s.pesagem_status, 'pendente') as pesagem_status
        FROM sessoes_producao s
        JOIN clientes c ON c.id = s.cliente_id
        JOIN produtos p ON p.id = s.produto_id
        LEFT JOIN vw_totais_sessao v ON v.sessao_id = s.id
        WHERE 1=1
        {sql_extra}
        ORDER BY s.id DESC
    """
    if limit:
        sql += f" LIMIT {int(limit)}"
    return sql, params


@dashboard_bp.route('/api/filtros/sessoes')
def api_filtros_sessoes():
    """Lista sessões com filtros"""
    try:
        try:
            sql, params = _sessoes_filtro_sql(limit=1000)
            rows = all_(sql, **params)
        except Exception:
            # Fallback sem colunas de peso
            sql_extra, params = _filtros_where()
            rows = all_(f"""
                SELECT s.id, s.inicio, s.fim, s.status, s.lote,
                       c.nome as cliente, p.nome as produto,
                       COALESCE(v.total, 0) as total
                FROM sessoes_producao s
                JOIN clientes c ON c.id = s.cliente_id
                JOIN produtos p ON p.id = s.produto_id
                LEFT JOIN vw_totais_sessao v ON v.sessao_id = s.id
                WHERE 1=1 {sql_extra}
                ORDER BY s.id DESC LIMIT 1000
            """, **params)
            for r in rows:
                r['peso_total_g'] = None
                r['peso_medio_g'] = None
                r['pesagem_status'] = 'pendente'
        return jsonify({'sessoes': rows})
    except Exception as e:
        return jsonify({'error': str(e)}), 500

@dashboard_bp.route('/api/filtros/export-excel')
def api_export_excel():
    """Exporta sessões filtradas para Excel"""
    try:
        from openpyxl import Workbook
        from openpyxl.styles import Font, Alignment

        try:
            sql, params = _sessoes_filtro_sql()
            rows = all_(sql, **params)
        except Exception:
            sql_extra, params = _filtros_where()
            rows = all_(f"""
                SELECT s.id, s.inicio, s.fim, s.status, s.lote,
                       c.nome as cliente, p.nome as produto,
                       COALESCE(v.total, 0) as total
                FROM sessoes_producao s
                JOIN clientes c ON c.id = s.cliente_id
                JOIN produtos p ON p.id = s.produto_id
                LEFT JOIN vw_totais_sessao v ON v.sessao_id = s.id
                WHERE 1=1 {sql_extra}
                ORDER BY s.id DESC
            """, **params)

        wb = Workbook()
        ws = wb.active
        ws.title = "Sessões de Produção"

        headers = ['ID', 'Cliente', 'Produto', 'Lote', 'Início', 'Fim', 'Status',
                   'Total', 'Peso Total (g)', 'Peso Médio (g)', 'Pesagem']
        ws.append(headers)

        for cell in ws[1]:
            cell.font = Font(bold=True)
            cell.alignment = Alignment(horizontal='center')

        for row in rows:
            ws.append([
                row['id'],
                row['cliente'],
                row['produto'],
                row.get('lote', ''),
                row['inicio'].strftime('%d/%m/%Y %H:%M:%S') if row['inicio'] else '',
                row['fim'].strftime('%d/%m/%Y %H:%M:%S') if row['fim'] else '',
                row['status'],
                row['total'],
                row.get('peso_total_g') or '',
                row.get('peso_medio_g') or '',
                row.get('pesagem_status') or '',
            ])

        for col in ws.columns:
            max_length = 0
            col_letter = col[0].column_letter
            for cell in col:
                try:
                    if len(str(cell.value)) > max_length:
                        max_length = len(str(cell.value))
                except Exception:
                    pass
            ws.column_dimensions[col_letter].width = min(max_length + 2, 50)

        output = io.BytesIO()
        wb.save(output)
        output.seek(0)

        filename = f"sessoes_producao_{datetime.now().strftime('%Y%m%d_%H%M%S')}.xlsx"
        return send_file(
            output,
            mimetype='application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
            as_attachment=True,
            download_name=filename
        )
    except Exception as e:
        return jsonify({'error': str(e)}), 500

@dashboard_bp.route('/api/filtros/export-pdf')
def api_export_pdf():
    """Exporta sessões filtradas para PDF"""
    try:
        from reportlab.lib import colors
        from reportlab.lib.pagesizes import A4, landscape
        from reportlab.platypus import SimpleDocTemplate, Table, TableStyle, Paragraph, Spacer
        from reportlab.lib.styles import getSampleStyleSheet
        from reportlab.lib.units import inch

        try:
            sql, params = _sessoes_filtro_sql(limit=500)
            rows = all_(sql, **params)
        except Exception:
            sql_extra, params = _filtros_where()
            rows = all_(f"""
                SELECT s.id, s.inicio, s.fim, s.status, s.lote,
                       c.nome as cliente, p.nome as produto,
                       COALESCE(v.total, 0) as total
                FROM sessoes_producao s
                JOIN clientes c ON c.id = s.cliente_id
                JOIN produtos p ON p.id = s.produto_id
                LEFT JOIN vw_totais_sessao v ON v.sessao_id = s.id
                WHERE 1=1 {sql_extra}
                ORDER BY s.id DESC LIMIT 500
            """, **params)

        buffer = io.BytesIO()
        doc = SimpleDocTemplate(buffer, pagesize=landscape(A4))
        elements = []
        styles = getSampleStyleSheet()

        title = Paragraph("Relatório de Produção — CRIA Bebidas", styles['Title'])
        elements.append(title)
        elements.append(Spacer(1, 0.15*inch))
        date_str = f"Gerado em: {datetime.now().strftime('%d/%m/%Y %H:%M:%S')}"
        elements.append(Paragraph(date_str, styles['Normal']))
        elements.append(Spacer(1, 0.2*inch))

        data = [['ID', 'Cliente', 'Produto', 'Lote', 'Início', 'Status', 'Qtd', 'Peso(g)', 'Méd(g)']]

        for row in rows:
            inicio_str = row['inicio'].strftime('%d/%m/%Y %H:%M') if row['inicio'] else ''
            peso = row.get('peso_total_g')
            medio = row.get('peso_medio_g')
            data.append([
                str(row['id']),
                (row['cliente'] or '')[:18],
                (row['produto'] or '')[:18],
                str(row.get('lote', '') or '')[:12],
                inicio_str,
                row['status'],
                str(row['total']),
                f"{peso:.0f}" if peso else '-',
                f"{medio:.1f}" if medio else '-',
            ])

        table = Table(data, repeatRows=1)
        table.setStyle(TableStyle([
            ('BACKGROUND', (0, 0), (-1, 0), colors.HexColor('#1B3A4B')),
            ('TEXTCOLOR', (0, 0), (-1, 0), colors.whitesmoke),
            ('ALIGN', (0, 0), (-1, -1), 'CENTER'),
            ('FONTNAME', (0, 0), (-1, 0), 'Helvetica-Bold'),
            ('FONTSIZE', (0, 0), (-1, 0), 9),
            ('BOTTOMPADDING', (0, 0), (-1, 0), 10),
            ('BACKGROUND', (0, 1), (-1, -1), colors.HexColor('#F7F9FB')),
            ('GRID', (0, 0), (-1, -1), 0.4, colors.HexColor('#CBD5E1')),
            ('FONTSIZE', (0, 1), (-1, -1), 7),
            ('ROWBACKGROUNDS', (0, 1), (-1, -1), [colors.white, colors.HexColor('#EEF2F6')]),
        ]))

        elements.append(table)
        doc.build(elements)
        buffer.seek(0)

        filename = f"sessoes_producao_{datetime.now().strftime('%Y%m%d_%H%M%S')}.pdf"
        return send_file(
            buffer,
            mimetype='application/pdf',
            as_attachment=True,
            download_name=filename
        )
    except Exception as e:
        return jsonify({'error': str(e)}), 500

@dashboard_bp.route('/api/filtros/lotes')
def api_filtros_lotes():
    """Lista lotes distintos para filtro."""
    try:
        cliente_id = request.args.get('cliente_id', type=int)
        produto_id = request.args.get('produto_id', type=int)
        where = "WHERE s.lote IS NOT NULL AND TRIM(s.lote) <> ''"
        params = {}
        if cliente_id:
            where += " AND s.cliente_id = :cliente_id"
            params['cliente_id'] = cliente_id
        if produto_id:
            where += " AND s.produto_id = :produto_id"
            params['produto_id'] = produto_id
        rows = all_(f"""
            SELECT DISTINCT s.lote FROM sessoes_producao s
            {where}
            ORDER BY s.lote ASC
            LIMIT 200
        """, **params)
        return jsonify({'lotes': [r['lote'] for r in rows]})
    except Exception as e:
        return jsonify({'error': str(e)}), 500

# ==========================================
# APIs - CRUD PRODUTOS
# ==========================================

@dashboard_bp.route('/api/produtos', methods=['GET'])
def api_produtos_list():
    """Lista produtos"""
    try:
        rows = all_("SELECT id, nome FROM produtos ORDER BY nome ASC")
        return jsonify({'produtos': rows})
    except Exception as e:
        return jsonify({'error': str(e)}), 500

@dashboard_bp.route('/api/produtos', methods=['POST'])
def api_produtos_create():
    """Cria produto"""
    try:
        data = request.get_json()
        nome = data.get('nome', '').strip()
        if not nome:
            return jsonify({'error': 'Nome é obrigatório'}), 400
        
        produto_id = exec_("INSERT INTO produtos (nome) VALUES (:nome)", nome=nome)
        return jsonify({'id': produto_id, 'nome': nome}), 201
    except Exception as e:
        return jsonify({'error': str(e)}), 500

@dashboard_bp.route('/api/produtos/<int:produto_id>', methods=['PUT'])
def api_produtos_update(produto_id):
    """Atualiza produto"""
    try:
        data = request.get_json()
        nome = data.get('nome', '').strip()
        if not nome:
            return jsonify({'error': 'Nome é obrigatório'}), 400
        
        exec_("UPDATE produtos SET nome = :nome WHERE id = :id", nome=nome, id=produto_id)
        return jsonify({'id': produto_id, 'nome': nome})
    except Exception as e:
        return jsonify({'error': str(e)}), 500

@dashboard_bp.route('/api/produtos/<int:produto_id>', methods=['DELETE'])
def api_produtos_delete(produto_id):
    """Deleta produto"""
    try:
        exec_("DELETE FROM produtos WHERE id = :id", id=produto_id)
        return jsonify({'ok': True})
    except Exception as e:
        return jsonify({'error': str(e)}), 500

# ==========================================
# APIs - CRUD CLIENTES
# ==========================================

@dashboard_bp.route('/api/clientes', methods=['GET'])
def api_clientes_list():
    """Lista clientes"""
    try:
        rows = all_("SELECT id, nome FROM clientes ORDER BY nome ASC")
        return jsonify({'clientes': rows})
    except Exception as e:
        return jsonify({'error': str(e)}), 500

@dashboard_bp.route('/api/clientes', methods=['POST'])
def api_clientes_create():
    """Cria cliente"""
    try:
        data = request.get_json()
        nome = data.get('nome', '').strip()
        if not nome:
            return jsonify({'error': 'Nome é obrigatório'}), 400
        
        cliente_id = exec_("INSERT INTO clientes (nome) VALUES (:nome)", nome=nome)
        return jsonify({'id': cliente_id, 'nome': nome}), 201
    except Exception as e:
        return jsonify({'error': str(e)}), 500

@dashboard_bp.route('/api/clientes/<int:cliente_id>', methods=['PUT'])
def api_clientes_update(cliente_id):
    """Atualiza cliente"""
    try:
        data = request.get_json()
        nome = data.get('nome', '').strip()
        if not nome:
            return jsonify({'error': 'Nome é obrigatório'}), 400
        
        exec_("UPDATE clientes SET nome = :nome WHERE id = :id", nome=nome, id=cliente_id)
        return jsonify({'id': cliente_id, 'nome': nome})
    except Exception as e:
        return jsonify({'error': str(e)}), 500

@dashboard_bp.route('/api/clientes/<int:cliente_id>', methods=['DELETE'])
def api_clientes_delete(cliente_id):
    """Deleta cliente"""
    try:
        exec_("DELETE FROM clientes WHERE id = :id", id=cliente_id)
        return jsonify({'ok': True})
    except Exception as e:
        return jsonify({'error': str(e)}), 500

