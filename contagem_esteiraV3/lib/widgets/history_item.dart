// lib/widgets/history_item.dart
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

class HistoryItem extends StatelessWidget {
  final int id;
  final String status;
  final String cliente;
  final String produto;
  final String lote;
  final int total;
  final dynamic pesoTotalG;
  final String pesagemStatus;
  final String inicio;
  final String fim;
  final VoidCallback? onTap;

  const HistoryItem({
    super.key,
    required this.id,
    required this.status,
    required this.cliente,
    required this.produto,
    this.lote = '',
    required this.total,
    this.pesoTotalG,
    this.pesagemStatus = '',
    required this.inicio,
    required this.fim,
    this.onTap,
  });

  DateTime? _parse(String s) => s.isEmpty ? null : DateTime.tryParse(s);
  String _fmt(DateTime? dt) => dt == null
      ? ''
      : DateFormat('dd/MM/yyyy - HH:mm', 'pt_BR').format(dt.toLocal());

  String _fmtPeso() {
    if (pesoTotalG == null) return '';
    final n = pesoTotalG is num
        ? (pesoTotalG as num).toDouble()
        : double.tryParse('$pesoTotalG') ?? 0;
    if (n <= 0) return '';
    if (n >= 1000) return '${(n / 1000).toStringAsFixed(2)} kg';
    return '${n.toStringAsFixed(0)} g';
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    Color bg, fg;
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

    final dtInicio = _parse(inicio);
    final dtFim = _parse(fim);
    final peso = _fmtPeso();

    return Card(
      margin: const EdgeInsets.symmetric(vertical: 8.0),
      child: ListTile(
        onTap: onTap,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 16.0, vertical: 10.0),
        title: Text(
          'Sessão #$id · $cliente',
          style: const TextStyle(fontWeight: FontWeight.bold),
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              [
                produto,
                if (lote.isNotEmpty) 'Lote $lote',
              ].join(' · '),
              overflow: TextOverflow.ellipsis,
            ),
            Text('Início: ${_fmt(dtInicio)}'),
            if (dtFim != null) Text('Fim: ${_fmt(dtFim)}'),
            if (peso.isNotEmpty)
              Text(
                'Peso: $peso'
                '${pesagemStatus.isNotEmpty ? ' · $pesagemStatus' : ''}',
                style: TextStyle(
                    color: cs.primary, fontWeight: FontWeight.w600),
              ),
          ],
        ),
        trailing: ConstrainedBox(
          constraints: const BoxConstraints(minWidth: 84),
          child: FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerRight,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Container(
                  decoration: BoxDecoration(
                    color: bg,
                    borderRadius: BorderRadius.circular(24),
                  ),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  child: Text(status,
                      style:
                          TextStyle(color: fg, fontWeight: FontWeight.w600)),
                ),
                const SizedBox(height: 8),
                Text(
                  '$total',
                  textAlign: TextAlign.right,
                  style: const TextStyle(
                      fontSize: 20, fontWeight: FontWeight.w800),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
