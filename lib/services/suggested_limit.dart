import '../models/models.dart';
import '../models/transaction_metadata.dart';
import 'finance_rules.dart';

/// A monthly limit to suggest for a category: the median of the real
/// spending of the last three closed months (no one-off spending, neutral
/// or pending entries), rounded up to the next 10. Only a suggestion: the
/// person decides. Same rule as `suggested` in get_budgets.
class SuggestedLimit {
  static double? monthly(
      {required String categoryId,
      String subcategory = '',
      required DateTime now,
      required List<AppTransaction> transactions,
      required Map<String, TransactionMetadata> metadata,
      required double Function(AppTransaction) toMain}) {
    final months = [
      for (var i = 1; i <= 3; i++) DateTime(now.year, now.month - i)
    ];
    final totals = List<double>.filled(3, 0);
    for (final t in transactions) {
      if (t.type != 'expense' || t.categoryId != categoryId) continue;
      final m = metadata[t.id];
      if (m != null &&
          (m.isPending ||
              m.expenseClass == 'extraordinary' ||
              (subcategory.isNotEmpty && m.subcategory != subcategory))) {
        continue;
      }
      if (subcategory.isNotEmpty && m == null) continue;
      if (FinanceRules.isNeutral(t, m)) continue;
      final i = months
          .indexWhere((d) => d.year == t.date.year && d.month == t.date.month);
      if (i >= 0) totals[i] += toMain(t);
    }
    totals.sort();
    final median = totals[1];
    final cents = (median * 100).round();
    if (cents <= 0) return null;
    return ((cents + 999) ~/ 1000) * 10.0;
  }
}
