// lib/services/api_service.dart

import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

class ApiException implements Exception {
  final int? statusCode;
  final String message;
  final String? body;

  ApiException(this.message, {this.statusCode, this.body});

  @override
  String toString() =>
      'ApiException(${statusCode ?? '-'}) $message${body != null ? ' | $body' : ''}';
}

class ApiService {
  static const _kApiBaseUrlKey = 'apiBaseUrl';
  /// Mesmo host/porta do firmware ESP32 e do .env (FLASK_PORT=5000).
  static const String defaultBaseUrl = 'http://192.169.0.129:5000';
  static const Duration _timeout = Duration(seconds: 12);
  static const Duration _probeTimeout = Duration(seconds: 2);

  static String? _cachedBase;
  static Completer<String>? _discovering;

  static Future<String> getBaseUrl() async {
    if (_cachedBase != null) return _cachedBase!;
    return ensureBaseUrl();
  }

  static Future<void> setBaseUrl(String url) async {
    final n = _normalizeBaseUrl(url);
    final sp = await SharedPreferences.getInstance();
    await sp.setString(_kApiBaseUrlKey, n);
    _cachedBase = n;
  }

  /// Encontra uma API que responda /health. Se a URL salva estiver velha
  /// (IP/porta de outra rede), tenta localhost, emulador e o IP da esteira.
  static Future<String> ensureBaseUrl({bool force = false}) async {
    if (!force && _cachedBase != null) return _cachedBase!;
    if (force) _cachedBase = null;
    if (_discovering != null) return _discovering!.future;

    final c = Completer<String>();
    _discovering = c;
    try {
      final sp = await SharedPreferences.getInstance();
      final saved = _normalizeBaseUrl(sp.getString(_kApiBaseUrlKey) ?? '');
      for (final url in _candidateUrls(saved)) {
        if (await _healthOk(url)) {
          _cachedBase = url;
          if (url != saved) {
            await sp.setString(_kApiBaseUrlKey, url);
          }
          c.complete(url);
          return url;
        }
      }
      final fallback = saved.isNotEmpty ? saved : defaultBaseUrl;
      _cachedBase = fallback;
      c.complete(fallback);
      return fallback;
    } catch (e, st) {
      c.completeError(e, st);
      rethrow;
    } finally {
      _discovering = null;
    }
  }

  static List<String> _candidateUrls(String saved) {
    final list = <String>[];
    void add(String u) {
      u = _normalizeBaseUrl(u);
      if (u.isEmpty || list.contains(u)) return;
      list.add(u);
    }

    final stale = saved.contains('192.168.0.104') ||
        saved.contains('192.168.11.100');
    if (!stale) add(saved);

    if (kIsWeb) {
      final host = Uri.base.host;
      if (host.isNotEmpty && host != 'localhost') {
        add('http://$host:5000');
        add('http://$host:5010');
      }
      add('http://127.0.0.1:5000');
      add('http://localhost:5000');
      add('http://127.0.0.1:5010');
    }

    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
      add('http://10.0.2.2:5000');
      add('http://10.0.2.2:5010');
    }

    add(defaultBaseUrl);
    add('http://192.169.0.129:5010');
    add('http://127.0.0.1:5000');
    add('http://localhost:5000');
    if (stale) add(saved);
    return list;
  }

  static Future<bool> _healthOk(String base) async {
    try {
      final uri = Uri.parse('$base/health');
      final r = await http
          .get(uri, headers: _jsonHeaders)
          .timeout(_probeTimeout);
      if (r.statusCode != 200) return false;
      final decoded = jsonDecode(r.body);
      return decoded is Map && decoded['ok'] == true;
    } catch (_) {
      return false;
    }
  }

  static String _normalizeBaseUrl(String url) {
    var u = url.trim();
    if (u.endsWith('/')) u = u.substring(0, u.length - 1);
    return u;
  }

  static Map<String, String> get _jsonHeaders => const {
        'Accept': 'application/json',
      };

  static Map<String, String> get _postHeaders => const {
        'Content-Type': 'application/json; charset=utf-8',
        'Accept': 'application/json',
      };

  static Uri _join(String base, String path, [Map<String, String>? qp]) {
    final b = base.endsWith('/') ? base.substring(0, base.length - 1) : base;
    final p = path.startsWith('/') ? path : '/$path';
    final u = Uri.parse('$b$p');
    return qp == null ? u : u.replace(queryParameters: qp);
  }

  static Future<http.Response> _getRaw(String path,
      {Map<String, String>? query}) async {
    final base = await getBaseUrl();
    final uri = _join(base, path, query);
    try {
      return await http.get(uri, headers: _jsonHeaders).timeout(_timeout);
    } on TimeoutException {
      throw ApiException('Tempo de resposta esgotado (GET $path) em $base');
    } catch (e) {
      throw ApiException('Falha de rede (GET $path) em $base: $e');
    }
  }

  static Future<http.Response> _postRaw(
      String path, Map<String, dynamic> body) async {
    final base = await getBaseUrl();
    final uri = _join(base, path);
    try {
      return await http
          .post(uri, headers: _postHeaders, body: jsonEncode(body))
          .timeout(_timeout);
    } on TimeoutException {
      throw ApiException('Tempo de resposta esgotado (POST $path) em $base');
    } catch (e) {
      throw ApiException('Falha de rede (POST $path) em $base: $e');
    }
  }

  static dynamic _decode(String body) {
    try {
      return jsonDecode(body);
    } catch (_) {
      return body;
    }
  }

  static Map<String, dynamic> _ensureMap(dynamic decoded, String onError) {
    if (decoded is Map<String, dynamic>) return decoded;
    if (decoded is Map) return Map<String, dynamic>.from(decoded);
    throw ApiException(onError, body: decoded.toString());
  }

  static List<Map<String, dynamic>> _ensureListOfMap(
      dynamic decoded, String onError) {
    if (decoded is List) {
      return decoded.map<Map<String, dynamic>>((e) {
        if (e is Map<String, dynamic>) return e;
        return Map<String, dynamic>.from(e as Map);
      }).toList();
    }
    throw ApiException(onError, body: decoded.toString());
  }

  static Future<bool> checkHealth() async {
    try {
      await ensureBaseUrl();
      final r = await _getRaw('/health');
      if (r.statusCode != 200) return false;
      final decoded = _decode(r.body);
      return decoded is Map && decoded['ok'] == true;
    } catch (_) {
      return false;
    }
  }

  static Future<List<Map<String, dynamic>>> getClientes() async {
    final r = await _getRaw('/clientes');
    if (r.statusCode != 200) {
      throw ApiException('Falha ao carregar clientes',
          statusCode: r.statusCode, body: r.body);
    }
    return _ensureListOfMap(_decode(r.body), 'Resposta inválida em /clientes');
  }

  static Future<List<Map<String, dynamic>>> getProdutos() async {
    final r = await _getRaw('/produtos');
    if (r.statusCode != 200) {
      throw ApiException('Falha ao carregar produtos',
          statusCode: r.statusCode, body: r.body);
    }
    return _ensureListOfMap(_decode(r.body), 'Resposta inválida em /produtos');
  }

  static Future<List<Map<String, dynamic>>> getDispositivos() async {
    final r = await _getRaw('/dispositivos');
    if (r.statusCode != 200) {
      throw ApiException('Falha ao carregar dispositivos',
          statusCode: r.statusCode, body: r.body);
    }
    return _ensureListOfMap(
        _decode(r.body), 'Resposta inválida em /dispositivos');
  }

  /// Sugestões de lote + próximo lote automático.
  static Future<Map<String, dynamic>> getLotes({
    int? clienteId,
    int? produtoId,
    String? q,
  }) async {
    final query = <String, String>{};
    if (clienteId != null) query['cliente_id'] = '$clienteId';
    if (produtoId != null) query['produto_id'] = '$produtoId';
    if (q != null && q.isNotEmpty) query['q'] = q;
    final r = await _getRaw('/lotes', query: query.isEmpty ? null : query);
    if (r.statusCode != 200) {
      throw ApiException('Falha ao carregar lotes',
          statusCode: r.statusCode, body: r.body);
    }
    return _ensureMap(_decode(r.body), 'Resposta inválida em /lotes');
  }

  static Future<List<Map<String, dynamic>>> listarSessoes({
    int page = 1,
    int size = 20,
    String? q,
    int? clienteId,
    int? produtoId,
    String? status,
    String? lote,
  }) async {
    final query = <String, String>{
      'page': '$page',
      'size': '$size',
    };
    if (q != null && q.isNotEmpty) query['q'] = q;
    if (clienteId != null) query['cliente_id'] = '$clienteId';
    if (produtoId != null) query['produto_id'] = '$produtoId';
    if (status != null && status.isNotEmpty) query['status'] = status;
    if (lote != null && lote.isNotEmpty) query['lote'] = lote;

    final r = await _getRaw('/sessoes', query: query);
    if (r.statusCode != 200) {
      throw ApiException('Falha ao listar sessões',
          statusCode: r.statusCode, body: r.body);
    }
    final decoded = _decode(r.body);
    final map = _ensureMap(decoded, 'Resposta inválida em /sessoes');
    final rows = map['rows'];
    if (rows is List) {
      return rows
          .map<Map<String, dynamic>>(
              (e) => Map<String, dynamic>.from(e as Map))
          .toList();
    }
    if (decoded is List) {
      return _ensureListOfMap(decoded, 'Resposta inválida em /sessoes');
    }
    throw ApiException('Campo "rows" ausente em /sessoes', body: r.body);
  }

  static Future<Map<String, dynamic>> criarSessao({
    required int clienteId,
    required int produtoId,
    required String lote,
    required int operadorId,
    required String dispositivoCodigo,
    double? pesoUnitarioRefG,
  }) async {
    final body = <String, dynamic>{
      'cliente_id': clienteId,
      'produto_id': produtoId,
      'lote': lote,
      'operador_id': operadorId,
      'dispositivo_codigo': dispositivoCodigo,
    };
    if (pesoUnitarioRefG != null) {
      body['peso_unitario_ref_g'] = pesoUnitarioRefG;
    }

    final r = await _postRaw('/sessoes', body);
    if (r.statusCode != 201) {
      throw ApiException('Falha ao iniciar sessão',
          statusCode: r.statusCode, body: r.body);
    }
    return _ensureMap(_decode(r.body), 'Resposta inválida ao criar sessão');
  }

  static Future<Map<String, dynamic>> obterSessao(int sessaoId) async {
    final r = await _getRaw('/sessoes/$sessaoId');
    if (r.statusCode == 404) {
      throw ApiException('Sessão #$sessaoId não encontrada',
          statusCode: 404, body: r.body);
    }
    if (r.statusCode != 200) {
      throw ApiException('Falha ao obter sessão',
          statusCode: r.statusCode, body: r.body);
    }
    return _ensureMap(_decode(r.body), 'Resposta inválida em /sessoes/:id');
  }

  static Future<Map<String, dynamic>> finalizarSessao({
    required int sessaoId,
    required String dispositivoCodigo,
    bool simularPesagem = true,
    double? pesoUnitarioRefG,
  }) async {
    final body = <String, dynamic>{
      'dispositivo_codigo': dispositivoCodigo,
      'simular_pesagem': simularPesagem,
    };
    if (pesoUnitarioRefG != null) {
      body['peso_unitario_ref_g'] = pesoUnitarioRefG;
    }
    final r = await _postRaw('/sessoes/$sessaoId/finalizar', body);
    if (r.statusCode != 200) {
      throw ApiException('Falha ao finalizar sessão',
          statusCode: r.statusCode, body: r.body);
    }
    return _ensureMap(_decode(r.body), 'Resposta inválida ao finalizar');
  }

  static Future<Map<String, dynamic>> simularPesagem(
    int sessaoId, {
    double? pesoUnitarioRefG,
  }) async {
    final body = <String, dynamic>{};
    if (pesoUnitarioRefG != null) {
      body['peso_unitario_ref_g'] = pesoUnitarioRefG;
    }
    final r = await _postRaw('/sessoes/$sessaoId/pesagem/simular', body);
    if (r.statusCode != 200) {
      throw ApiException('Falha ao simular pesagem',
          statusCode: r.statusCode, body: r.body);
    }
    return _ensureMap(_decode(r.body), 'Resposta inválida na pesagem');
  }

  static Future<List<Map<String, dynamic>>> listarPesagens(int sessaoId) async {
    final r = await _getRaw('/sessoes/$sessaoId/pesagens');
    if (r.statusCode != 200) {
      throw ApiException('Falha ao listar pesagens',
          statusCode: r.statusCode, body: r.body);
    }
    final map = _ensureMap(_decode(r.body), 'Resposta inválida em /pesagens');
    final list = map['pesagens'];
    if (list is List) {
      return list
          .map<Map<String, dynamic>>(
              (e) => Map<String, dynamic>.from(e as Map))
          .toList();
    }
    return [];
  }
}
