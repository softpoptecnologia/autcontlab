// lib/pages/history_page.dart

import 'dart:async';
import 'package:flutter/material.dart';
import '../services/api_service.dart';
import 'session_page.dart';
import '../widgets/custom_card.dart';
import '../widgets/history_item.dart';

class HistoryPage extends StatefulWidget {
  const HistoryPage({super.key});

  @override
  State<HistoryPage> createState() => _HistoryPageState();
}

class _HistoryPageState extends State<HistoryPage> {
  bool _loading = true;
  String? _erro;
  int _page = 1;
  final _rows = <Map<String, dynamic>>[];
  final _searchCtrl = TextEditingController();
  Timer? _debounce;

  String? _status;
  int? _clienteId;
  int? _produtoId;
  List<Map<String, dynamic>> _clientes = [];
  List<Map<String, dynamic>> _produtos = [];

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _bootstrap() async {
    try {
      final results = await Future.wait([
        ApiService.getClientes(),
        ApiService.getProdutos(),
      ]);
      _clientes = results[0];
      _produtos = results[1];
    } catch (_) {}
    await _load();
  }

  Future<void> _load({bool append = false}) async {
    setState(() {
      _loading = true;
      _erro = null;
    });
    try {
      final res = await ApiService.listarSessoes(
        page: _page,
        size: 20,
        q: _searchCtrl.text.trim().isEmpty ? null : _searchCtrl.text.trim(),
        clienteId: _clienteId,
        produtoId: _produtoId,
        status: _status,
      );
      if (append) {
        _rows.addAll(res);
      } else {
        _rows
          ..clear()
          ..addAll(res);
      }
    } catch (e) {
      _erro = e.toString();
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _onSearchChanged(String _) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 400), () {
      _page = 1;
      _load();
    });
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isLand =
        MediaQuery.of(context).orientation == Orientation.landscape;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Histórico de produção'),
      ),
      body: RefreshIndicator(
        onRefresh: () async {
          _page = 1;
          await _load();
        },
        child: ListView(
          padding: EdgeInsets.symmetric(
            horizontal: isLand ? 24 : 16,
            vertical: 16,
          ),
          children: [
            if (_erro != null) Text(_erro!, style: TextStyle(color: cs.error)),
            CustomCard(
              child: Column(
                children: [
                  TextField(
                    controller: _searchCtrl,
                    onChanged: _onSearchChanged,
                    decoration: InputDecoration(
                      hintText: 'Buscar cliente, produto, lote ou ID…',
                      prefixIcon: const Icon(Icons.search),
                      suffixIcon: _searchCtrl.text.isEmpty
                          ? null
                          : IconButton(
                              icon: const Icon(Icons.clear),
                              onPressed: () {
                                _searchCtrl.clear();
                                _page = 1;
                                _load();
                              },
                            ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      FilterChip(
                        label: const Text('Todas'),
                        selected: _status == null,
                        onSelected: (_) {
                          setState(() => _status = null);
                          _page = 1;
                          _load();
                        },
                      ),
                      FilterChip(
                        label: const Text('Ativas'),
                        selected: _status == 'ativa',
                        onSelected: (_) {
                          setState(() => _status = 'ativa');
                          _page = 1;
                          _load();
                        },
                      ),
                      FilterChip(
                        label: const Text('Finalizadas'),
                        selected: _status == 'finalizada',
                        onSelected: (_) {
                          setState(() => _status = 'finalizada');
                          _page = 1;
                          _load();
                        },
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: DropdownButtonFormField<int?>(
                          value: _clienteId,
                          isExpanded: true,
                          decoration: const InputDecoration(
                            labelText: 'Cliente',
                            isDense: true,
                          ),
                          items: [
                            const DropdownMenuItem(
                                value: null, child: Text('Todos')),
                            ..._clientes.map((c) => DropdownMenuItem(
                                  value: c['id'] as int,
                                  child: Text(c['nome'] as String,
                                      overflow: TextOverflow.ellipsis),
                                )),
                          ],
                          onChanged: (v) {
                            setState(() => _clienteId = v);
                            _page = 1;
                            _load();
                          },
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: DropdownButtonFormField<int?>(
                          value: _produtoId,
                          isExpanded: true,
                          decoration: const InputDecoration(
                            labelText: 'Produto',
                            isDense: true,
                          ),
                          items: [
                            const DropdownMenuItem(
                                value: null, child: Text('Todos')),
                            ..._produtos.map((p) => DropdownMenuItem(
                                  value: p['id'] as int,
                                  child: Text(p['nome'] as String,
                                      overflow: TextOverflow.ellipsis),
                                )),
                          ],
                          onChanged: (v) {
                            setState(() => _produtoId = v);
                            _page = 1;
                            _load();
                          },
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            if (_loading && _rows.isEmpty)
              const Center(child: CircularProgressIndicator())
            else if (_rows.isEmpty)
              const Center(child: Text('Nenhum registro encontrado.'))
            else
              ..._rows.map((r) {
                final int id = r['id'] is String
                    ? int.tryParse(r['id']) ?? 0
                    : (r['id'] as num?)?.toInt() ?? 0;
                final int total = r['total'] is String
                    ? int.tryParse(r['total']) ?? 0
                    : (r['total'] as num?)?.toInt() ?? 0;

                return HistoryItem(
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => SessionPage(
                        sessaoId: id,
                        dispositivoCodigo:
                            (r['dispositivo_codigo'] ?? '').toString(),
                      ),
                    ),
                  ),
                  status: (r['status'] ?? '').toString(),
                  id: id,
                  cliente: (r['cliente'] ?? '').toString(),
                  produto: (r['produto'] ?? '').toString(),
                  lote: (r['lote'] ?? '').toString(),
                  total: total,
                  pesoTotalG: r['peso_total_g'],
                  pesagemStatus: (r['pesagem_status'] ?? '').toString(),
                  inicio: (r['inicio'] ?? '').toString(),
                  fim: (r['fim'] ?? '').toString(),
                );
              }),
            if (_rows.isNotEmpty && !_loading)
              Align(
                alignment: Alignment.center,
                child: FilledButton.tonalIcon(
                  onPressed: () async {
                    _page++;
                    await _load(append: true);
                  },
                  icon: const Icon(Icons.expand_more),
                  label: const Text('Carregar mais'),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
