// lib/pages/weighing_page.dart
import 'dart:async';
import 'package:flutter/material.dart';
import '../services/api_service.dart';

num _asNum(dynamic v) {
  if (v is num) return v;
  if (v is String) return num.tryParse(v) ?? 0;
  return 0;
}

/// Simula a esteira de pesagem após a contagem.
class WeighingPage extends StatefulWidget {
  final int sessaoId;
  final int totalItens;
  final Map<String, dynamic>? pesagemInicial;

  const WeighingPage({
    super.key,
    required this.sessaoId,
    required this.totalItens,
    this.pesagemInicial,
  });

  @override
  State<WeighingPage> createState() => _WeighingPageState();
}

class _WeighingPageState extends State<WeighingPage> {
  bool _running = true;
  bool _done = false;
  String? _erro;
  int _progress = 0;
  double _pesoTotal = 0;
  double _pesoMedio = 0;
  List<Map<String, dynamic>> _amostra = [];
  Timer? _anim;

  @override
  void initState() {
    super.initState();
    _boot();
  }

  @override
  void dispose() {
    _anim?.cancel();
    super.dispose();
  }

  Future<void> _boot() async {
    try {
      Map<String, dynamic>? result = widget.pesagemInicial;
      if (result == null || result['pesagens'] == null) {
        result = await ApiService.simularPesagem(widget.sessaoId);
      }

      final itens = _asNum(result['itens']).toInt();
      final total = _asNum(result['peso_total_g']).toDouble();
      final medio = _asNum(result['peso_medio_g']).toDouble();
      final list = (result['pesagens'] as List?)
              ?.map((e) => Map<String, dynamic>.from(e as Map))
              .toList() ??
          [];

      // Animação de progresso (protótipo da esteira)
      final target = itens > 0 ? itens : widget.totalItens;
      if (target <= 0) {
        setState(() {
          _done = true;
          _running = false;
          _pesoTotal = total;
          _pesoMedio = medio;
          _amostra = list;
        });
        return;
      }

      final stepMs = (2200 / target).clamp(16, 80).toInt();
      var i = 0;
      _anim = Timer.periodic(Duration(milliseconds: stepMs), (t) {
        i++;
        if (!mounted) {
          t.cancel();
          return;
        }
        setState(() {
          _progress = i.clamp(0, target);
          if (list.isNotEmpty) {
            _pesoTotal = list
                .take(_progress.clamp(0, list.length))
                .fold<double>(0, (a, e) => a + _asNum(e['peso_g']).toDouble());
          } else {
            _pesoTotal = total * (_progress / target);
          }
        });
        if (i >= target) {
          t.cancel();
          setState(() {
            _progress = target;
            _pesoTotal = total;
            _pesoMedio = medio;
            _amostra = list.take(30).toList();
            _done = true;
            _running = false;
          });
        }
      });
    } catch (e) {
      setState(() {
        _erro = e.toString();
        _running = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isLand =
        MediaQuery.of(context).orientation == Orientation.landscape;
    final target = widget.totalItens > 0 ? widget.totalItens : _progress;
    final pct = target > 0 ? (_progress / target).clamp(0.0, 1.0) : 0.0;

    final hero = _HeroScale(
      running: _running,
      done: _done,
      progress: _progress,
      target: target,
      pesoTotal: _pesoTotal,
      pesoMedio: _pesoMedio,
      pct: pct,
    );

    final details = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_erro != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Text(_erro!, style: TextStyle(color: cs.error)),
          ),
        Text(
          _done
              ? 'Pesagem concluída (simulada)'
              : 'Objetos passando na esteira de peso…',
          style: Theme.of(context).textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w700,
              ),
        ),
        const SizedBox(height: 8),
        Text(
          'Protótipo: cada unidade contada recebe um peso individual '
          'com tolerância industrial (±4%).',
          style: TextStyle(color: cs.onSurfaceVariant),
        ),
        const SizedBox(height: 16),
        if (_amostra.isNotEmpty) ...[
          Text('Amostra de pesos',
              style: Theme.of(context)
                  .textTheme
                  .titleSmall
                  ?.copyWith(fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: _amostra.take(isLand ? 18 : 12).map((e) {
              final seq = e['item_seq'];
              final g = _asNum(e['peso_g']).toDouble();
              return Chip(
                label: Text('#$seq · ${g.toStringAsFixed(1)} g'),
                visualDensity: VisualDensity.compact,
              );
            }).toList(),
          ),
        ],
        const SizedBox(height: 24),
        FilledButton.icon(
          onPressed: _done || !_running
              ? () => Navigator.of(context).popUntil((r) => r.isFirst)
              : null,
          icon: const Icon(Icons.check_circle_outline),
          label: Text(_done ? 'Voltar ao painel' : 'Aguarde…'),
        ),
      ],
    );

    return Scaffold(
      appBar: AppBar(
        title: Text('Pesagem · Sessão #${widget.sessaoId}'),
        automaticallyImplyLeading: _done,
      ),
      body: SafeArea(
        child: isLand
            ? Row(
                children: [
                  Expanded(child: Padding(padding: const EdgeInsets.all(16), child: hero)),
                  Expanded(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.all(16),
                      child: details,
                    ),
                  ),
                ],
              )
            : ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  hero,
                  const SizedBox(height: 20),
                  details,
                ],
              ),
      ),
    );
  }
}

class _HeroScale extends StatelessWidget {
  final bool running;
  final bool done;
  final int progress;
  final int target;
  final double pesoTotal;
  final double pesoMedio;
  final double pct;

  const _HeroScale({
    required this.running,
    required this.done,
    required this.progress,
    required this.target,
    required this.pesoTotal,
    required this.pesoMedio,
    required this.pct,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Card(
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          gradient: LinearGradient(
            colors: [
              const Color(0xFF13293D),
              cs.primary.withOpacity(0.95),
            ],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
        ),
        child: Column(
          children: [
            Icon(
              done ? Icons.monitor_weight : Icons.scale,
              color: Colors.white,
              size: 40,
            ),
            const SizedBox(height: 12),
            Text(
              '${(pesoTotal >= 1000 ? pesoTotal / 1000 : pesoTotal).toStringAsFixed(pesoTotal >= 1000 ? 2 : 0)}'
              '${pesoTotal >= 1000 ? ' kg' : ' g'}',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 42,
                fontWeight: FontWeight.w800,
                letterSpacing: -1,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              done
                  ? 'Média ${pesoMedio.toStringAsFixed(1)} g / unidade'
                  : 'Pesando $progress de $target',
              style: TextStyle(color: Colors.white.withOpacity(0.9)),
            ),
            const SizedBox(height: 16),
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: LinearProgressIndicator(
                value: pct,
                minHeight: 10,
                backgroundColor: Colors.white24,
                color: const Color(0xFFFBBF24),
              ),
            ),
            if (running) ...[
              const SizedBox(height: 12),
              const SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(
                  strokeWidth: 2.5,
                  color: Colors.white,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
