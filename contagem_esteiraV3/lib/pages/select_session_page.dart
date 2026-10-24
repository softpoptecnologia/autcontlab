// lib/pages/select_session_page.dart
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/api_service.dart';
import 'session_page.dart';
import '../widgets/custom_card.dart';
import '../widgets/section_header.dart';

class SelectSessionPage extends StatefulWidget {
  const SelectSessionPage({super.key});

  @override
  State<SelectSessionPage> createState() => _SelectSessionPageState();
}

class _SelectSessionPageState extends State<SelectSessionPage> {
  final _formKey = GlobalKey<FormState>();
  final _loteCtrl = TextEditingController();
  int? _clienteId;
  int? _produtoId;
  int? _operadorId = 1;
  String? _dispositivoCodigo;
  double _pesoRef = 350;
  bool _loading = false;
  bool _loadingData = true;
  String? _erro;
  String? _loteSugestao;

  List<Map<String, dynamic>> _clientes = [];
  List<Map<String, dynamic>> _produtos = [];
  List<Map<String, dynamic>> _dispositivos = [];
  List<String> _lotes = [];

  @override
  void initState() {
    super.initState();
    _carregarTudo();
  }

  @override
  void dispose() {
    _loteCtrl.dispose();
    super.dispose();
  }

  Future<void> _carregarTudo() async {
    setState(() {
      _erro = null;
      _loadingData = true;
    });
    try {
      await _carregarPrefs();
      final results = await Future.wait([
        ApiService.getClientes(),
        ApiService.getProdutos(),
        ApiService.getDispositivos(),
      ]);
      _clientes = results[0];
      _produtos = results[1];
      _dispositivos = results[2];
      _clienteId ??= _clientes.isNotEmpty ? _clientes.first['id'] as int : null;
      _produtoId ??= _produtos.isNotEmpty ? _produtos.first['id'] as int : null;
      _dispositivoCodigo ??= _dispositivos.isNotEmpty
          ? _dispositivos.first['codigo'] as String
          : null;
      await _carregarLotes();
    } catch (e) {
      _erro = e.toString();
    } finally {
      if (mounted) setState(() => _loadingData = false);
    }
  }

  Future<void> _carregarLotes() async {
    try {
      final data = await ApiService.getLotes(
        clienteId: _clienteId,
        produtoId: _produtoId,
      );
      final list = (data['lotes'] as List?)
              ?.map((e) => (e is Map ? e['lote'] : e)?.toString() ?? '')
              .where((s) => s.isNotEmpty)
              .toList() ??
          [];
      _lotes = list;
      _loteSugestao = data['sugestao']?.toString();
      final ref = data['peso_unitario_default_g'];
      if (ref is num) _pesoRef = ref.toDouble();

      // Auto-carrega lote se campo vazio
      if (_loteCtrl.text.trim().isEmpty && _loteSugestao != null) {
        _loteCtrl.text = _loteSugestao!;
      }
      if (mounted) setState(() {});
    } catch (_) {
      // silencioso — lote continua editável
    }
  }

  Future<void> _carregarPrefs() async {
    final sp = await SharedPreferences.getInstance();
    _clienteId = sp.getInt('clienteId');
    _produtoId = sp.getInt('produtoId');
    _operadorId = sp.getInt('operadorId') ?? 1;
    final lote = sp.getString('lote');
    if (lote != null && lote.isNotEmpty) _loteCtrl.text = lote;
    _dispositivoCodigo =
        sp.getString('dispositivoCodigo') ?? _dispositivoCodigo;
    _pesoRef = sp.getDouble('pesoUnitarioRefG') ?? 350;
  }

  Future<void> _salvarPrefs() async {
    final sp = await SharedPreferences.getInstance();
    if (_clienteId != null) await sp.setInt('clienteId', _clienteId!);
    if (_produtoId != null) await sp.setInt('produtoId', _produtoId!);
    if (_operadorId != null) await sp.setInt('operadorId', _operadorId!);
    await sp.setString('lote', _loteCtrl.text.trim());
    await sp.setDouble('pesoUnitarioRefG', _pesoRef);
    if (_dispositivoCodigo != null) {
      await sp.setString('dispositivoCodigo', _dispositivoCodigo!);
    }
  }

  Future<void> _iniciar() async {
    if (!_formKey.currentState!.validate()) return;
    if (_clienteId == null ||
        _produtoId == null ||
        _dispositivoCodigo == null) {
      setState(() => _erro = 'Selecione cliente, produto e dispositivo.');
      return;
    }
    setState(() {
      _erro = null;
      _loading = true;
    });

    try {
      final lote = _loteCtrl.text.trim().isEmpty
          ? (_loteSugestao ?? 'L1')
          : _loteCtrl.text.trim();

      final res = await ApiService.criarSessao(
        clienteId: _clienteId!,
        produtoId: _produtoId!,
        lote: lote,
        operadorId: _operadorId ?? 1,
        dispositivoCodigo: _dispositivoCodigo!,
        pesoUnitarioRefG: _pesoRef,
      );

      final sessaoId = res['sessao_id'] as int;
      await _salvarPrefs();
      final sp = await SharedPreferences.getInstance();
      await sp.setInt('lastSessaoId', sessaoId);
      await sp.setString('lastSessaoDisp', _dispositivoCodigo!);
      if (!mounted) return;
      if (res['mqtt_ok'] == false) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Sessão criada, mas o motor pode não ter ligado (MQTT). Confira o ESP e o broker.',
            ),
          ),
        );
      }
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(
          builder: (_) => SessionPage(
            sessaoId: sessaoId,
            dispositivoCodigo: _dispositivoCodigo!,
          ),
        ),
      );
    } catch (e) {
      setState(() => _erro = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final col = Theme.of(context).colorScheme;
    final isLand =
        MediaQuery.of(context).orientation == Orientation.landscape;

    final form = Form(
      key: _formKey,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SectionHeader(
            title: 'Dados da produção',
            icon: Icons.tune,
            color: col.primary,
          ),
          const SizedBox(height: 16),
          DropdownButtonFormField<int>(
            value: _clienteId,
            items: _clientes
                .map((c) => DropdownMenuItem<int>(
                    value: c['id'] as int,
                    child: Text(c['nome'] as String)))
                .toList(),
            onChanged: (v) async {
              setState(() => _clienteId = v);
              await _carregarLotes();
            },
            decoration: const InputDecoration(
              labelText: 'Cliente',
              prefixIcon: Icon(Icons.business_outlined),
            ),
            validator: (v) => v == null ? 'Selecione um cliente' : null,
          ),
          const SizedBox(height: 14),
          DropdownButtonFormField<int>(
            value: _produtoId,
            items: _produtos
                .map((p) => DropdownMenuItem<int>(
                    value: p['id'] as int,
                    child: Text(p['nome'] as String)))
                .toList(),
            onChanged: (v) async {
              setState(() => _produtoId = v);
              await _carregarLotes();
            },
            decoration: const InputDecoration(
              labelText: 'Produto',
              prefixIcon: Icon(Icons.local_drink_outlined),
            ),
            validator: (v) => v == null ? 'Selecione um produto' : null,
          ),
          const SizedBox(height: 14),
          TextFormField(
            initialValue: '${_operadorId ?? 1}',
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(
              labelText: 'Operador ID',
              prefixIcon: Icon(Icons.badge_outlined),
            ),
            validator: (v) {
              final n = int.tryParse((v ?? '').trim());
              if (n == null || n <= 0) return 'Informe um inteiro > 0';
              return null;
            },
            onChanged: (v) => _operadorId = int.tryParse(v.trim()) ?? 1,
          ),
          const SizedBox(height: 14),
          Autocomplete<String>(
            initialValue: TextEditingValue(text: _loteCtrl.text),
            optionsBuilder: (tv) {
              final q = tv.text.toLowerCase();
              if (q.isEmpty) return _lotes;
              return _lotes.where((l) => l.toLowerCase().contains(q));
            },
            onSelected: (v) {
              _loteCtrl.text = v;
              setState(() {});
            },
            fieldViewBuilder: (ctx, controller, focus, onSubmit) {
              // sync with our controller content once
              if (controller.text != _loteCtrl.text &&
                  _loteCtrl.text.isNotEmpty &&
                  controller.text.isEmpty) {
                controller.text = _loteCtrl.text;
              }
              return TextFormField(
                controller: controller,
                focusNode: focus,
                decoration: InputDecoration(
                  labelText: 'Lote (carregado automaticamente)',
                  prefixIcon: const Icon(Icons.confirmation_number_outlined),
                  helperText: _loteSugestao != null
                      ? 'Sugestão: $_loteSugestao'
                      : 'Histórico de lotes do cliente/produto',
                  suffixIcon: IconButton(
                    tooltip: 'Usar sugestão',
                    onPressed: _loteSugestao == null
                        ? null
                        : () {
                            controller.text = _loteSugestao!;
                            _loteCtrl.text = _loteSugestao!;
                            setState(() {});
                          },
                    icon: const Icon(Icons.auto_awesome),
                  ),
                ),
                onChanged: (v) => _loteCtrl.text = v,
                validator: (v) =>
                    (v == null || v.trim().isEmpty) ? 'Informe o lote' : null,
              );
            },
          ),
          const SizedBox(height: 14),
          DropdownButtonFormField<String>(
            value: _dispositivoCodigo,
            items: _dispositivos
                .map((d) => DropdownMenuItem<String>(
                    value: d['codigo'] as String,
                    child: Text(
                        '${d['codigo']}${(d['descricao'] as String).isNotEmpty ? ' - ${d['descricao']}' : ''}')))
                .toList(),
            onChanged: (v) => setState(() => _dispositivoCodigo = v),
            decoration: const InputDecoration(
              labelText: 'Esteira / dispositivo',
              prefixIcon: Icon(Icons.memory_outlined),
            ),
            validator: (v) =>
                (v == null || v.isEmpty) ? 'Selecione um dispositivo' : null,
          ),
          const SizedBox(height: 14),
          TextFormField(
            initialValue: _pesoRef.toStringAsFixed(0),
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(
              labelText: 'Peso unitário ref. (g)',
              prefixIcon: Icon(Icons.scale_outlined),
              helperText: 'Usado na simulação da esteira de peso',
            ),
            onChanged: (v) {
              final n = double.tryParse(v.replaceAll(',', '.'));
              if (n != null && n > 0) _pesoRef = n;
            },
          ),
          const SizedBox(height: 24),
          FilledButton.icon(
            onPressed: _loading ? null : _iniciar,
            icon: const Icon(Icons.play_arrow_rounded),
            label: Text(_loading ? 'Iniciando...' : 'Iniciar produção'),
          ),
        ],
      ),
    );

    return Scaffold(
      appBar: AppBar(
        title: const Text('Nova produção'),
      ),
      body: RefreshIndicator(
        onRefresh: _carregarTudo,
        child: LayoutBuilder(
          builder: (context, constraints) {
            return SingleChildScrollView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: EdgeInsets.symmetric(
                horizontal: isLand ? 24 : 16,
                vertical: 16,
              ),
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  minHeight: constraints.maxHeight - 32,
                  maxWidth: isLand ? 720 : double.infinity,
                ),
                child: Align(
                  alignment: Alignment.topCenter,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (_erro != null)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child:
                              Text(_erro!, style: TextStyle(color: col.error)),
                        ),
                      if (_loadingData)
                        const Padding(
                          padding: EdgeInsets.symmetric(vertical: 48),
                          child: Center(child: CircularProgressIndicator()),
                        )
                      else
                        CustomCard(child: form),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}
