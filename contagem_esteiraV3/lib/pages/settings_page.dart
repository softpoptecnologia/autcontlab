// lib/pages/settings_page.dart

import 'package:flutter/material.dart';
import '../widgets/custom_card.dart';
import '../widgets/section_header.dart';
import '../services/api_service.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  final _apiController = TextEditingController();
  bool _loading = false;
  bool? _online;
  String? _erro;
  List<Map<String, dynamic>> _dispositivos = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _apiController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final url = await ApiService.getBaseUrl();
    _apiController.text = url;
    await _testHealth();
    try {
      _dispositivos = await ApiService.getDispositivos();
    } catch (_) {
      _dispositivos = [];
    }
    if (mounted) setState(() {});
  }

  Future<void> _testHealth() async {
    try {
      _online = await ApiService.checkHealth();
    } catch (_) {
      _online = false;
    }
    if (mounted) setState(() {});
  }

  Future<void> _saveApiUrl() async {
    setState(() {
      _loading = true;
      _erro = null;
    });
    try {
      await ApiService.setBaseUrl(_apiController.text);
      await _testHealth();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(_online == true
                ? 'URL salva · API online'
                : 'URL salva · API offline — confira IP/porta'),
          ),
        );
      }
    } catch (e) {
      setState(() => _erro = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _detectApi() async {
    setState(() {
      _loading = true;
      _erro = null;
    });
    try {
      final url = await ApiService.ensureBaseUrl(force: true);
      _apiController.text = url;
      await _testHealth();
      try {
        _dispositivos = await ApiService.getDispositivos();
      } catch (_) {
        _dispositivos = [];
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(_online == true
                ? 'API encontrada em $url'
                : 'Não achei a API. Suba o Flask e use o IP deste PC na porta 5000.'),
          ),
        );
      }
    } catch (e) {
      setState(() => _erro = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Configurações')),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            CustomCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SectionHeader(
                    title: 'Conexão com a API',
                    icon: Icons.cloud_outlined,
                    color: cs.primary,
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Icon(
                        _online == true
                            ? Icons.check_circle
                            : Icons.error_outline,
                        color: _online == true ? Colors.green : Colors.red,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        _online == null
                            ? 'Verificando…'
                            : (_online! ? 'API online' : 'API offline'),
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: _apiController,
                    decoration: const InputDecoration(
                      labelText: 'URL da API',
                      hintText: 'Ex: http://192.169.0.129:5000',
                      helperText:
                          'Mesmo IP do computador que roda o Flask. Porta 5000.',
                    ),
                  ),
                  if (_erro != null) ...[
                    const SizedBox(height: 8),
                    Text(_erro!, style: TextStyle(color: cs.error)),
                  ],
                  const SizedBox(height: 12),
                  FilledButton.icon(
                    onPressed: _loading ? null : _saveApiUrl,
                    icon: _loading
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(
                              color: Colors.white,
                              strokeWidth: 2,
                            ),
                          )
                        : const Icon(Icons.save),
                    label: Text(_loading ? 'Salvando...' : 'Salvar e testar'),
                  ),
                  const SizedBox(height: 8),
                  OutlinedButton.icon(
                    onPressed: _loading ? null : _detectApi,
                    icon: const Icon(Icons.wifi_find),
                    label: const Text('Detectar API automaticamente'),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            CustomCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SectionHeader(
                    title: 'Dispositivos cadastrados',
                    icon: Icons.memory_outlined,
                    color: cs.primary,
                  ),
                  const SizedBox(height: 8),
                  if (_dispositivos.isEmpty)
                    const Text('Nenhum dispositivo encontrado na API.')
                  else
                    ..._dispositivos.map((d) => ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: Icon(Icons.developer_board, color: cs.primary),
                          title: Text('${d['codigo']}'),
                          subtitle: Text(
                            (d['descricao'] ?? '').toString().isEmpty
                                ? 'Esteira de contagem'
                                : '${d['descricao']}',
                          ),
                        )),
                ],
              ),
            ),
            const SizedBox(height: 16),
            CustomCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SectionHeader(
                    title: 'Fluxo do protótipo',
                    icon: Icons.account_tree_outlined,
                    color: cs.primary,
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    '1. Contagem na esteira (sensor)\n'
                    '2. Finalizar sessão\n'
                    '3. Pesagem simulada por unidade (próxima esteira)\n'
                    '4. Dados no painel web com filtros de produção',
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
