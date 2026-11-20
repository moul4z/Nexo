import '../models/models.dart';
import 'finance_rules.dart';
import 'transaction_metadata_service.dart';

class TransactionFilter {
  String? accountId, categoryId, status, source, expenseClass;
  DateTime? from, to;
  double? minimum, maximum;
  bool installmentsOnly = false;
  TransactionFilter copy() => TransactionFilter()
    ..accountId = accountId
    ..categoryId = categoryId
    ..status = status
    ..source = source
    ..expenseClass = expenseClass
    ..from = from
    ..to = to
    ..minimum = minimum
    ..maximum = maximum
    ..installmentsOnly = installmentsOnly;

  /// How many filters are set, for the badge on the filter button.
  int get count =>
      [
        accountId,
        categoryId,
        status,
        source,
        expenseClass,
        from,
        minimum,
        maximum,
      ].where((v) => v != null).length +
      (installmentsOnly ? 1 : 0);

  /// The amount a search text stands for ("55,90", "R$ 55", "1.200,00"),
  /// in cents; null when it is not an amount.
  static int? searchedCents(String query) {
    final t = query.trim().toLowerCase().replaceAll('r\$', '').trim();
    if (!RegExp(r'^\d{1,3}(\.\d{3})*(,\d{1,2})?$|^\d+([,.]\d{1,2})?$')
        .hasMatch(t)) {
      return null;
    }
    // "1.200,00" and "1200,00" are thousands; "12.5" is a decimal point.
    final normal = t.contains(',')
        ? t.replaceAll('.', '').replaceAll(',', '.')
        : RegExp(r'^\d{1,3}(\.\d{3})+$').hasMatch(t)
            ? t.replaceAll('.', '')
            : t;
    final v = double.tryParse(normal);
    return v == null ? null : (v * 100).round();
  }

  bool matches(AppTransaction tx, TransactionMetadata meta) {
    final date = DateTime(tx.date.year, tx.date.month, tx.date.day);
    return (accountId == null || tx.accountId == accountId) &&
        (categoryId == null || tx.categoryId == categoryId) &&
        (status == null || meta.status == status) &&
        (expenseClass == null || meta.expenseClass == expenseClass) &&
        (source == null || meta.source == source) &&
        (from == null || !date.isBefore(from!)) &&
        (to == null || !date.isAfter(to!)) &&
        (minimum == null || tx.amount >= minimum!) &&
        (maximum == null || tx.amount <= maximum!) &&
        (!installmentsOnly || (meta.installmentTotal ?? 0) > 1);
  }

  static bool matchesType(
          AppTransaction tx, TransactionMetadata meta, String type) =>
      type == 'all' ||
      (type == 'neutral'
          ? FinanceRules.isNeutral(tx, meta)
          : tx.type == type && !FinanceRules.isNeutral(tx, meta));
}
