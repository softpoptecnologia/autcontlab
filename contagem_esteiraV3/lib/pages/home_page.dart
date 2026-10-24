// lib/pages/home_page.dart
import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/api_service.dart';
import 'session_page.dart';
import 'weighing_page.dart';

num _asNum(dynamic v) {
  if (v is num) return v;
  if (v is String) return num.tryParse(v) ?? 0;
  return 0;
}

DateTime? _parseWhen(dynamic v) {
  if (v == null) return null;
  return DateTime.tryParse(v.toString());
}

String _fmtHMS(Duration d) {
  final h = d.inHours.remainder(100).toString().padLeft(2, '0');
  final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
  final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
  return '$h:$m:$s';
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with WidgetsBindingObserver {
  int _navIndex = 0;
  int? _lastSessaoId;
  String? _lastDisp;
  Map<String, dynamic>? _sessao;
  String? _erro;
  bool _apiOnline = false;
  Timer? _ticker;
  Timer? _pollTimer;
  Duration _elapsed = Duration.zero;
  double _mediaMin = 0;
  int _lastTotal = 0;

  static const _ink = Color(0xFF0C1A24);
  static const _steel = Color(0xFF16324A);
  static const _accent = Color(0xFFC45C26);
  static const _line = Color(0xFFC9D6E2);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) => _tick());
    _pollTimer = Timer.periodic(const Duration(seconds: 2), (_) => _pollData());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _ticker?.cancel();
    _pollTimer?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _load();
  }

  Future<void> _clearSessaoLocal() async {
    final sp = await SharedPreferences.getInstance();
    await sp.remove('lastSessaoId');
    await sp.remove('lastSessaoDisp');
    _lastSessaoId = null;
    _lastDisp = null;
    _sessao = null;
  }

  Future<void> _load() async {
    setState(() => _erro = null);
    try {
      await ApiService.ensureBaseUrl(force: !_apiOnline);
      _apiOnline = await ApiService.checkHealth();
      if (!_apiOnline) {
        final url = await ApiService.getBaseUrl();
        _erro =
            'API offline em $url. Confira se o Flask está rodando na porta 5000 e o IP na tela de configurações.';
      }
      final sp = await SharedPreferences.getInstance();
      _lastSessaoId = sp.getInt('lastSessaoId');
      _lastDisp = sp.getString('lastSessaoDisp');

      if (_lastSessaoId != null) {
        try {
          final s = await ApiService.obterSessao(_lastSessaoId!);
          if ((s['status'] ?? '').toString().toLowerCase() == 'finalizada') {
            await _clearSessaoLocal();
          } else {
            _sessao = s;
            _lastTotal = _asNum(s['total']).toInt();
          }
        } on ApiException catch (e) {
          // ID antigo no celular / sessão apagada no banco
          if (e.statusCode == 404) {
            await _clearSessaoLocal();
          } else {
            rethrow;
          }
        }
      } else {
        _sessao = null;
      }
      _recomputeMetrics();
    } catch (e) {
      _erro = e.toString();
    }
    if (mounted) setState(() {});
  }

  Future<void> _pollData() async {
    if (_lastSessaoId == null) return;
    try {
      final s = await ApiService.obterSessao(_lastSessaoId!);
      if ((s['status'] ?? '').toString().toLowerCase() == 'finalizada') {
        await _clearSessaoLocal();
        if (mounted) setState(() {});
      } else if (mounted) {
        setState(() {
          _lastTotal = _asNum(_sessao?['total']).toInt();
          _sessao = s;
          _recomputeMetrics();
        });
      }
    } on ApiException catch (e) {
      if (e.statusCode == 404) {
        await _clearSessaoLocal();
        if (mounted) setState(() {});
      }
    } catch (e) {
      debugPrint('Erro no polling: $e');
    }
  }

  void _tick() {
    if (_sessao == null) return;
    final inicio = _parseWhen(_sessao!['inicio']);
    if (inicio == null) return;
    _elapsed = DateTime.now().difference(inicio);
    _recomputeMetrics();
    if (mounted) setState(() {});
  }

  void _recomputeMetrics() {
    final total = _asNum(_sessao?['total']).toDouble();
    final mins = max(1, _elapsed.inSeconds / 60.0);
    _mediaMin = total / mins;
  }

  List<num> _serieUltimas() {
    final l = (_sessao?['ultimas_leituras'] as List<dynamic>?) ?? [];
    int sum = 0;
    final series = <int>[];
    for (final e in l) {
      final m = (e as Map).cast<String, dynamic>();
      sum += _asNum(m['contagem_incremental']).toInt();
      series.add(sum);
    }
    return series.isEmpty ? [0] : series;
  }

  Future<void> _finalizarSessao() async {
    if (_lastSessaoId == null) return;
    try {
      final total = _asNum(_sessao?['total']).toInt();
      final res = await ApiService.finalizarSessao(
        sessaoId: _lastSessaoId!,
        dispositivoCodigo: _lastDisp ?? '',
        simularPesagem: true,
      );
      final sid = _lastSessaoId!;
      final pesagem = res['pesagem'] is Map
          ? Map<String, dynamic>.from(res['pesagem'] as Map)
          : null;

      final sp = await SharedPreferences.getInstance();
      await sp.remove('lastSessaoId');
      await sp.remove('lastSessaoDisp');
      await _load();
      if (!mounted) return;

      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => WeighingPage(
            sessaoId: sid,
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
    }
  }

  @override
  Widget build(BuildContext context) {
    final isLand =
        MediaQuery.of(context).orientation == Orientation.landscape;
    final totalAtual = _asNum(_sessao?['total']).toInt();
    final statusAtual = (_sessao?['status'] ?? '').toString().toLowerCase();
    final ativa = _lastSessaoId != null && statusAtual == 'ativa';

    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFFE6EEF4), Color(0xFFEDF2F6), Color(0xFFE8E0D8)],
          ),
        ),
        child: SafeArea(
          child: RefreshIndicator(
            color: _accent,
            onRefresh: _load,
            child: CustomScrollView(
              physics: const AlwaysScrollableScrollPhysics(),
              slivers: [
                SliverToBoxAdapter(child: _topBar(ativa)),
                if (_erro != null)
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                      child: _ErrorBanner(
                        text: _erro!,
                        onOpenSettings: () => Navigator.pushNamed(
                                context, '/settings')
                            .then((_) => _load()),
                      ),
                    ),
                  ),
                SliverPadding(
                  padding: EdgeInsets.fromLTRB(
                    isLand ? 20 : 16,
                    12,
                    isLand ? 20 : 16,
                    24,
                  ),
                  sliver: SliverToBoxAdapter(
                    child: isLand
                        ? Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Expanded(
                                flex: 6,
                                child: _CounterConsole(
                                  ativa: ativa,
                                  total: totalAtual,
                                  lastTotal: _lastTotal,
                                  onAnimEnd: () {
                                    if (mounted) {
                                      setState(() => _lastTotal = totalAtual);
                                    }
                                  },
                                  lote: _sessao?['lote']?.toString(),
                                  onStart: () => Navigator.pushNamed(
                                          context, '/start')
                                      .then((_) => _load()),
                                  onStop: _finalizarSessao,
                                  onOpen: ativa
                                      ? () => Navigator.push(
                                            context,
                                            MaterialPageRoute(
                                              builder: (_) => SessionPage(
                                                sessaoId: _lastSessaoId!,
                                                dispositivoCodigo:
                                                    _lastDisp ?? '',
                                              ),
                                            ),
                                          ).then((_) => _load())
                                      : null,
                                ),
                              ),
                              const SizedBox(width: 16),
                              Expanded(
                                flex: 5,
                                child: Column(
                                  children: [
                                    _SessionMeta(
                                      ativa: ativa,
                                      sessao: _sessao,
                                      sessaoId: _lastSessaoId,
                                      disp: _lastDisp,
                                      elapsed: _elapsed,
                                      mediaMin: _mediaMin,
                                    ),
                                    if (ativa) ...[
                                      const SizedBox(height: 12),
                                      _SparkPanel(data: _serieUltimas()),
                                    ],
                                  ],
                                ),
                              ),
                            ],
                          )
                        : Column(
                            children: [
                              _CounterConsole(
                                ativa: ativa,
                                total: totalAtual,
                                lastTotal: _lastTotal,
                                onAnimEnd: () {
                                  if (mounted) {
                                    setState(() => _lastTotal = totalAtual);
                                  }
                                },
                                lote: _sessao?['lote']?.toString(),
                                onStart: () => Navigator.pushNamed(
                                        context, '/start')
                                    .then((_) => _load()),
                                onStop: _finalizarSessao,
                                onOpen: ativa
                                    ? () => Navigator.push(
                                          context,
                                          MaterialPageRoute(
                                            builder: (_) => SessionPage(
                                              sessaoId: _lastSessaoId!,
                                              dispositivoCodigo:
                                                  _lastDisp ?? '',
                                            ),
                                          ),
                                        ).then((_) => _load())
                                    : null,
                              ),
                              const SizedBox(height: 14),
                              _SessionMeta(
                                ativa: ativa,
                                sessao: _sessao,
                                sessaoId: _lastSessaoId,
                                disp: _lastDisp,
                                elapsed: _elapsed,
                                mediaMin: _mediaMin,
                              ),
                              if (ativa) ...[
                                const SizedBox(height: 14),
                                _SparkPanel(data: _serieUltimas()),
                              ],
                            ],
                          ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _navIndex,
        onDestinationSelected: (i) async {
          setState(() => _navIndex = i);
          switch (i) {
            case 0:
              await _load();
              break;
            case 1:
              await Navigator.pushNamed(context, '/start');
              await _load();
              break;
            case 2:
              await Navigator.pushNamed(context, '/history');
              await _load();
              break;
            case 3:
              await Navigator.pushNamed(context, '/settings');
              await _load();
              break;
          }
        },
        destinations: const [
          NavigationDestination(
              icon: Icon(Icons.dashboard_outlined),
              selectedIcon: Icon(Icons.dashboard),
              label: 'Central'),
          NavigationDestination(
              icon: Icon(Icons.play_arrow_rounded), label: 'Iniciar'),
          NavigationDestination(icon: Icon(Icons.history), label: 'Histórico'),
          NavigationDestination(
              icon: Icon(Icons.settings_outlined), label: 'Config'),
        ],
      ),
    );
  }

  Widget _topBar(bool ativa) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 12, 0),
      child: Row(
        children: [
          Container(
            width: 42,
            height: 42,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                colors: [_accent, Color(0xFFA8481C)],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text(
              'CRIA',
              style: GoogleFonts.spaceGrotesk(
                color: Colors.white,
                fontWeight: FontWeight.w700,
                fontSize: 11,
                letterSpacing: 0.4,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Central de Produção',
                  style: GoogleFonts.spaceGrotesk(
                    fontWeight: FontWeight.w700,
                    fontSize: 18,
                    color: _ink,
                  ),
                ),
                Text(
                  ativa ? 'Linha em operação' : 'Linha em espera',
                  style: TextStyle(
                    color: _steel.withOpacity(0.75),
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
          _StatusChip(online: _apiOnline),
          IconButton(
            onPressed: () =>
                Navigator.pushNamed(context, '/settings').then((_) => _load()),
            icon: const Icon(Icons.settings_outlined, color: _steel),
          ),
        ],
      ),
    );
  }
}

class _StatusChip extends StatelessWidget {
  final bool online;
  const _StatusChip({required this.online});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: online ? const Color(0xFFE7F6EE) : const Color(0xFFFEE2E2),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(
          color: online ? const Color(0xFFB7E0C8) : const Color(0xFFFECACA),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.circle,
            size: 8,
            color: online ? const Color(0xFF1F7A4C) : const Color(0xFFB42318),
          ),
          const SizedBox(width: 6),
          Text(
            online ? 'API' : 'OFF',
            style: GoogleFonts.ibmPlexMono(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              color: online ? const Color(0xFF1F7A4C) : const Color(0xFFB42318),
            ),
          ),
        ],
      ),
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  final String text;
  final VoidCallback? onOpenSettings;
  const _ErrorBanner({required this.text, this.onOpenSettings});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: const Color(0xFFFEE2E2),
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        onTap: onOpenSettings,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: const Color(0xFFFECACA)),
          ),
          child: Row(
            children: [
              const Icon(Icons.error_outline, color: Color(0xFFB42318)),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  text,
                  style: const TextStyle(color: Color(0xFFB42318)),
                ),
              ),
              if (onOpenSettings != null)
                const Icon(Icons.settings_outlined, color: Color(0xFFB42318)),
            ],
          ),
        ),
      ),
    );
  }
}

class _CounterConsole extends StatelessWidget {
  final bool ativa;
  final int total;
  final int lastTotal;
  final VoidCallback onAnimEnd;
  final String? lote;
  final VoidCallback onStart;
  final VoidCallback onStop;
  final VoidCallback? onOpen;

  const _CounterConsole({
    required this.ativa,
    required this.total,
    required this.lastTotal,
    required this.onAnimEnd,
    required this.lote,
    required this.onStart,
    required this.onStop,
    this.onOpen,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(22),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: ativa
              ? const [Color(0xFF0C1A24), Color(0xFF16324A), Color(0xFF8B3A18)]
              : const [Color(0xFF0C1A24), Color(0xFF16324A)],
        ),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF0C1A24).withOpacity(0.28),
            blurRadius: 24,
            offset: const Offset(0, 12),
          ),
        ],
      ),
      padding: const EdgeInsets.fromLTRB(22, 20, 22, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Text(
                'CONTAGEM',
                style: GoogleFonts.ibmPlexSans(
                  color: Colors.white70,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1.2,
                  fontSize: 12,
                ),
              ),
              const Spacer(),
              if (ativa)
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                  decoration: BoxDecoration(
                    color: const Color(0xFF22C55E).withOpacity(0.18),
                    borderRadius: BorderRadius.circular(999),
                    border: Border.all(
                        color: const Color(0xFF4ADE80).withOpacity(0.5)),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.circle, size: 8, color: Color(0xFF4ADE80)),
                      const SizedBox(width: 6),
                      Text(
                        'AO VIVO',
                        style: GoogleFonts.ibmPlexMono(
                          color: const Color(0xFFBBF7D0),
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
          const SizedBox(height: 10),
          TweenAnimationBuilder<int>(
            duration: const Duration(milliseconds: 380),
            tween: Tween(begin: lastTotal, end: total),
            onEnd: onAnimEnd,
            builder: (_, value, __) => Text(
              value.toString().padLeft(1, '0'),
              textAlign: TextAlign.center,
              style: GoogleFonts.ibmPlexMono(
                color: Colors.white,
                fontSize: 76,
                fontWeight: FontWeight.w700,
                height: 1,
                letterSpacing: -2,
              ),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            lote != null ? 'Lote $lote' : 'Aguardando produção',
            textAlign: TextAlign.center,
            style: GoogleFonts.spaceGrotesk(
              color: Colors.white70,
              fontWeight: FontWeight.w600,
              fontSize: 15,
            ),
          ),
          const SizedBox(height: 20),
          Row(
            children: [
              Expanded(
                child: FilledButton(
                  onPressed: ativa ? onOpen : onStart,
                  style: FilledButton.styleFrom(
                    backgroundColor: ativa
                        ? Colors.white.withOpacity(0.12)
                        : const Color(0xFFC45C26),
                    foregroundColor: Colors.white,
                    minimumSize: const Size.fromHeight(50),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                      side: ativa
                          ? BorderSide(color: Colors.white.withOpacity(0.2))
                          : BorderSide.none,
                    ),
                  ),
                  child: Text(
                    ativa ? 'Abrir sessão' : 'Iniciar produção',
                    style: GoogleFonts.spaceGrotesk(fontWeight: FontWeight.w700),
                  ),
                ),
              ),
              if (ativa) ...[
                const SizedBox(width: 10),
                Expanded(
                  child: FilledButton(
                    onPressed: onStop,
                    style: FilledButton.styleFrom(
                      backgroundColor: const Color(0xFFB42318),
                      foregroundColor: Colors.white,
                      minimumSize: const Size.fromHeight(50),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                    ),
                    child: Text(
                      'Parar e pesar',
                      style:
                          GoogleFonts.spaceGrotesk(fontWeight: FontWeight.w700),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

class _SessionMeta extends StatelessWidget {
  final bool ativa;
  final Map<String, dynamic>? sessao;
  final int? sessaoId;
  final String? disp;
  final Duration elapsed;
  final double mediaMin;

  const _SessionMeta({
    required this.ativa,
    required this.sessao,
    required this.sessaoId,
    required this.disp,
    required this.elapsed,
    required this.mediaMin,
  });

  @override
  Widget build(BuildContext context) {
    if (!ativa) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: const Color(0xFFC9D6E2)),
        ),
        child: Row(
          children: [
            Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                color: const Color(0xFFF3E0D4),
                borderRadius: BorderRadius.circular(14),
              ),
              child: const Icon(Icons.factory_outlined, color: Color(0xFFC45C26)),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Linha pronta',
                    style: GoogleFonts.spaceGrotesk(
                      fontWeight: FontWeight.w700,
                      fontSize: 16,
                    ),
                  ),
                  const SizedBox(height: 4),
                  const Text(
                    'Inicie uma produção. Ao finalizar, a esteira de peso é simulada automaticamente.',
                    style: TextStyle(color: Color(0xFF5B6B7A), height: 1.35),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    }

    return Column(
      children: [
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: const Color(0xFFC9D6E2)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Sessão #$sessaoId',
                style: GoogleFonts.spaceGrotesk(
                  fontWeight: FontWeight.w700,
                  fontSize: 16,
                ),
              ),
              const SizedBox(height: 10),
              _metaRow('Cliente', '${sessao?['cliente'] ?? '—'}'),
              _metaRow('Produto', '${sessao?['produto'] ?? '—'}'),
              _metaRow('Lote', '${sessao?['lote'] ?? '—'}'),
              _metaRow('Dispositivo', disp ?? '—'),
            ],
          ),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: _MetricBox(
                label: 'TEMPO',
                value: _fmtHMS(elapsed),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _MetricBox(
                label: 'UN / MIN',
                value: mediaMin.toStringAsFixed(1),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _metaRow(String k, String v) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          SizedBox(
            width: 92,
            child: Text(
              k,
              style: const TextStyle(
                color: Color(0xFF5B6B7A),
                fontWeight: FontWeight.w600,
                fontSize: 13,
              ),
            ),
          ),
          Expanded(
            child: Text(
              v,
              style: GoogleFonts.ibmPlexSans(
                fontWeight: FontWeight.w600,
                fontSize: 14,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}

class _MetricBox extends StatelessWidget {
  final String label;
  final String value;
  const _MetricBox({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFC9D6E2)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: GoogleFonts.ibmPlexSans(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.8,
              color: const Color(0xFF5B6B7A),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            value,
            style: GoogleFonts.ibmPlexMono(
              fontSize: 22,
              fontWeight: FontWeight.w700,
              color: const Color(0xFF0C1A24),
            ),
          ),
        ],
      ),
    );
  }
}

class _SparkPanel extends StatelessWidget {
  final List<num> data;
  const _SparkPanel({required this.data});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: const Color(0xFFC9D6E2)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Evolução da contagem',
            style: GoogleFonts.spaceGrotesk(
              fontWeight: FontWeight.w700,
              fontSize: 15,
            ),
          ),
          const SizedBox(height: 12),
          SizedBox(
            height: 120,
            width: double.infinity,
            child: CustomPaint(
              painter: _SparkPainter(
                data.map((e) => e.toDouble()).toList(),
                const Color(0xFFC45C26),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SparkPainter extends CustomPainter {
  final List<double> d;
  final Color color;
  _SparkPainter(this.d, this.color);

  @override
  void paint(Canvas c, Size s) {
    if (d.isEmpty) return;
    final minV = d.reduce(min);
    final maxV = d.reduce(max);
    final range = (maxV - minV).abs() < 1e-6 ? 1.0 : (maxV - minV);

    final fill = Path();
    final stroke = Path();
    for (var i = 0; i < d.length; i++) {
      final x = (d.length == 1) ? 0.0 : i / (d.length - 1) * s.width;
      final y = s.height - ((d[i] - minV) / range) * s.height;
      if (i == 0) {
        stroke.moveTo(x, y);
        fill.moveTo(x, s.height);
        fill.lineTo(x, y);
      } else {
        stroke.lineTo(x, y);
        fill.lineTo(x, y);
      }
    }
    fill.lineTo(s.width, s.height);
    fill.close();

    c.drawPath(
      fill,
      Paint()..color = color.withOpacity(0.12),
    );
    c.drawPath(
      stroke,
      Paint()
        ..color = color
        ..strokeWidth = 2.6
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round,
    );
  }

  @override
  bool shouldRepaint(covariant _SparkPainter old) =>
      old.d.length != d.length || old.color != color;
}
