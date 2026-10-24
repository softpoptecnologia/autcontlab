import 'dart:async';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/api_service.dart';
import 'weighing_page.dart';

num _asNum(dynamic v) {
  if (v is num) return v;
  if (v is String) return num.tryParse(v) ?? 0;
  return 0;
}

class SessionPage extends StatefulWidget {
  final int sessaoId;
  final String dispositivoCodigo;
  const SessionPage({
    super.key,
    required this.sessaoId,
    required this.dispositivoCodigo,
  });

  @override
  State<SessionPage> createState() => _SessionPageState();
}

class _SessionPageState extends State<SessionPage> {
  Timer? _timer;
  Map<String, dynamic>? _sessao;
  String? _erro;
  bool _finalizando = false;
  double _lastTotal = 0;

  @override
  void initState() {
    super.initState();
    _carregar();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => _carregar());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _carregar() async {
    try {
      final data = await ApiService.obterSessao(widget.sessaoId);
      if (!mounted) return;
      setState(() {
        _lastTotal = _asNum(_sessao?['total']).toDouble();
        _sessao = data;
        _erro = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _erro = e.toString());
    }
  }

  Future<void> _finalizar() async {
    setState(() => _finalizando = true);
    try {
      final total = _asNum(_sessao?['total']).toInt();
      final res = await ApiService.finalizarSessao(
        sessaoId: widget.sessaoId,
        dispositivoCodigo: widget.dispositivoCodigo,
        simularPesagem: true,
      );

      final sp = await SharedPreferences.getInstance();
      await sp.remove('lastSessaoId');
      await sp.remove('lastSessaoDisp');

      _timer?.cancel();
      await _carregar();

      if (!mounted) return;

      final pesagem = res['pesagem'] is Map
          ? Map<String, dynamic>.from(res['pesagem'] as Map)
          : null;

      await Navigator.of(context).pushReplacement(
        MaterialPageRoute(
          builder: (_) => WeighingPage(
            sessaoId: widget.sessaoId,
            totalItens: total,
            pesagemInicial: pesagem,
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Erro ao finalizar: $e')),
      );
    } finally {
      if (mounted) setState(() => _finalizando = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isLand =
        MediaQuery.of(context).orientation == Orientation.landscape;

    final totalNow = _asNum(_sessao?['total']).toDouble();
    final status = (_sessao?['status'] ?? '...').toString();
    final leituras = (_sessao?['ultimas_leituras'] as List<dynamic>?) ?? [];
    final finalizada = status.toLowerCase() == 'finalizada';

    final hero = Card(
      clipBehavior: Clip.antiAlias,
      child: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [const Color(0xFF13293D), cs.primary.withOpacity(.92)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 22),
        child: Row(
          children: [
            Container(
              height: 64,
              width: 64,
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(.18),
                borderRadius: BorderRadius.circular(16),
              ),
              child: const Icon(Icons.precision_manufacturing,
                  size: 34, color: Colors.white),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Contagem ao vivo',
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          color: Colors.white, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 6),
                  TweenAnimationBuilder<double>(
                    duration: const Duration(milliseconds: 450),
                    tween: Tween<double>(begin: _lastTotal, end: totalNow),
                    builder: (_, value, __) => Text(
                      value.toStringAsFixed(0),
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 44,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  Text(
                    [
                      if (_sessao?['lote'] != null) 'Lote ${_sessao!['lote']}',
                      widget.dispositivoCodigo,
                    ].where((e) => e.toString().isNotEmpty).join(' · '),
                    style: TextStyle(color: Colors.white.withOpacity(.9)),
                  ),
                ],
              ),
            ),
            IconButton(
              onPressed: _carregar,
              icon: const Icon(Icons.refresh, color: Colors.white),
            ),
          ],
        ),
      ),
    );

    final meta = Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Produção',
                style: Theme.of(context)
                    .textTheme
                    .titleMedium
                    ?.copyWith(fontWeight: FontWeight.w700)),
            const SizedBox(height: 8),
            if (_sessao?['cliente'] != null)
              _row(Icons.business, 'Cliente', '${_sessao!['cliente']}'),
            if (_sessao?['produto'] != null)
              _row(Icons.local_drink, 'Produto', '${_sessao!['produto']}'),
            if (_sessao?['lote'] != null)
              _row(Icons.label, 'Lote', '${_sessao!['lote']}'),
          ],
        ),
      ),
    );

    final readings = Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.timeline, color: cs.primary),
                const SizedBox(width: 8),
                Text('Últimas leituras',
                    style: Theme.of(context).textTheme.titleMedium),
              ],
            ),
            const SizedBox(height: 10),
            if (leituras.isEmpty)
              const Text('Aguardando objetos na esteira…')
            else
              ...List.generate(leituras.length.clamp(0, isLand ? 8 : 12), (i) {
                final l = (leituras[i] as Map).cast<String, dynamic>();
                final inc = _asNum(l['contagem_incremental']).toInt();
                final ts = (l['timestamp'] ?? '').toString();
                return ListTile(
                  dense: true,
                  leading: CircleAvatar(
                    radius: 16,
                    backgroundColor: cs.secondaryContainer,
                    child: Text('$inc',
                        style: TextStyle(
                            color: cs.onSecondaryContainer,
                            fontWeight: FontWeight.w700)),
                  ),
                  title: const Text('Incremento'),
                  subtitle: Text(ts),
                  contentPadding: EdgeInsets.zero,
                );
              }),
          ],
        ),
      ),
    );

    final actions = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (!finalizada)
          FilledButton.icon(
            onPressed: _finalizando ? null : _finalizar,
            style: FilledButton.styleFrom(
              backgroundColor: cs.error,
              foregroundColor: Colors.white,
              minimumSize: const Size.fromHeight(52),
            ),
            icon: const Icon(Icons.stop_circle_outlined),
            label: Text(_finalizando
                ? 'Finalizando e pesando…'
                : 'Finalizar e pesar'),
          )
        else
          FilledButton.tonalIcon(
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => WeighingPage(
                    sessaoId: widget.sessaoId,
                    totalItens: totalNow.toInt(),
                  ),
                ),
              );
            },
            icon: const Icon(Icons.scale),
            label: const Text('Ver / refazer pesagem'),
          ),
      ],
    );

    return Scaffold(
      appBar: AppBar(
        title: Text('Sessão #${widget.sessaoId}'),
        actions: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Center(child: _StatusChip(status: status)),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _carregar,
        child: isLand
            ? Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: ListView(
                      padding: const EdgeInsets.all(16),
                      children: [
                        hero,
                        const SizedBox(height: 12),
                        meta,
                        const SizedBox(height: 12),
                        actions,
                      ],
                    ),
                  ),
                  Expanded(
                    child: ListView(
                      padding: const EdgeInsets.fromLTRB(0, 16, 16, 16),
                      children: [
                        if (_erro != null)
                          Text(_erro!, style: TextStyle(color: cs.error)),
                        readings,
                      ],
                    ),
                  ),
                ],
              )
            : ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  hero,
                  if (_erro != null) ...[
                    const SizedBox(height: 8),
                    Text(_erro!, style: TextStyle(color: cs.error)),
                  ],
                  const SizedBox(height: 12),
                  meta,
                  const SizedBox(height: 12),
                  readings,
                  const SizedBox(height: 16),
                  actions,
                ],
              ),
      ),
    );
  }

  Widget _row(IconData icon, String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Icon(icon, size: 18, color: Colors.blueGrey),
          const SizedBox(width: 8),
          Text('$label: ', style: const TextStyle(fontWeight: FontWeight.w600)),
          Expanded(child: Text(value, overflow: TextOverflow.ellipsis)),
        ],
      ),
    );
  }
}

class _StatusChip extends StatelessWidget {
  final String status;
  const _StatusChip({required this.status});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    Color bg;
    Color fg;
    switch (status.toLowerCase()) {
      case 'ativa':
        bg = cs.secondaryContainer;
        fg = cs.onSecondaryContainer;
        break;
      case 'finalizada':
        bg = cs.primaryContainer;
        fg = cs.onPrimaryContainer;
        break;
      default:
        bg = cs.surfaceContainerHighest;
        fg = cs.onSurfaceVariant;
    }
    return Container(
      decoration:
          BoxDecoration(color: bg, borderRadius: BorderRadius.circular(24)),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      child: Text(status,
          style: TextStyle(color: fg, fontWeight: FontWeight.w600)),
    );
  }
}
