import 'package:intl/intl.dart';

/// Parses money typed in either Brazilian format (1.234,56 / 1234,56)
/// or international format (1,234.56 / 1234.56).
double? parseMoney(String raw) => parseDecimal(raw);

/// An exchange rate or a unit price: up to six decimal places, and a lone
/// dot is always the decimal mark (a rate has no thousands).
double? parseRate(String raw) =>
    parseDecimal(raw, decimals: 6, thousands: false);

/// A number typed in the Brazilian or the international format, with at
/// most [decimals] decimal places. With [thousands], "1.234" is 1234.
double? parseDecimal(String raw, {int decimals = 2, bool thousands = true}) {
  var value = raw
      .replaceAll('US\$', '')
      .replaceAll('R\$', '')
      .replaceAll('\u00A0', '')
      .replaceAll(' ', '')
      .trim();
  if (value.isEmpty) return null;

  final hasComma = value.contains(',');
  final hasDot = value.contains('.');

  if (hasComma && hasDot) {
    if (value.lastIndexOf(',') > value.lastIndexOf('.')) {
      value = value.replaceAll('.', '').replaceAll(',', '.');
    } else {
      value = value.replaceAll(',', '');
    }
  } else if (hasComma) {
    value = value.replaceAll('.', '').replaceAll(',', '.');
  } else if (thousands && RegExp(r'^-?\d{1,3}(\.\d{3})+$').hasMatch(value)) {
    value = value.replaceAll('.', '');
  }

  if (!RegExp('^-?\\d+(\\.\\d{1,$decimals})?\$').hasMatch(value)) return null;
  final parsed = double.tryParse(value);
  return parsed != null && parsed.isFinite ? parsed : null;
}

String ptDate(DateTime date) => DateFormat('dd/MM/yyyy', 'pt_BR').format(date);

String ptShortDate(DateTime date) => DateFormat('dd/MM', 'pt_BR').format(date);

/// "1 dia", "25 dias": never "25 dia(s)".
String ptCount(int count, String singular, [String? plural]) =>
    '$count ${count == 1 ? singular : plural ?? '${singular}s'}';

String ptMonthYear(DateTime date) {
  final value = DateFormat('MMMM yyyy', 'pt_BR').format(date);
  if (value.isEmpty) return value;
  return '${value[0].toUpperCase()}${value.substring(1)}';
}

/// What deleting a category in use leaves behind, told before confirming.
/// Null when nothing uses it.
String? categoryInUseWarning(({int entries, int recurring, int budgets}) uses) {
  final parts = [
    if (uses.entries > 0) ptCount(uses.entries, 'lançamento'),
    if (uses.recurring > 0)
      ptCount(uses.recurring, 'recorrente', 'recorrentes'),
    if (uses.budgets > 0) ptCount(uses.budgets, 'orçamento'),
  ];
  if (parts.isEmpty) return null;
  final list = parts.length == 1
      ? parts.single
      : '${parts.sublist(0, parts.length - 1).join(', ')} e ${parts.last}';
  final many = uses.entries + uses.recurring + uses.budgets > 1;
  return '$list ${many ? 'usam' : 'usa'} esta categoria e ${many ? 'ficam' : 'fica'} sem categoria. Para manter o histórico junto, troque a categoria deles antes de excluir.';
}
