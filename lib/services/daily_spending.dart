import '../models/models.dart';
import '../models/transaction_metadata.dart';
import 'finance_rules.dart';

/// Day-to-day spending for the cash forecast: the daily average of the last
/// four weeks, apart for what leaves the account on the day and what goes to
/// each card's invoice. Only real spending: no neutral entries, recurring
/// charges, installments, one-off ("pontual") expenses or pending ones.
/// The same rule as get_cash_projection with daily_spending "average".
class DailySpending {
  /// Per day, from the accounts that count in the cash.
  final double cash;

  /// Per day, by card id.
  final Map<String, double> cards;

  /// The currency of [cash] (the main one: it was converted).
  final String currency;

  const DailySpending(this.cash, this.currency, [this.cards = const {}]);

  static const days = 28;

  bool get isEmpty => cash <= 0 && cards.values.every((v) => v <= 0);

  static DailySpending average(
      {required DateTime now,
      required List<Account> accounts,
      required List<AppTransaction> transactions,
      required Map<String, TransactionMetadata> metadata,
      required String currency,
      required double Function(double, String) convert}) {
    final today = DateTime(now.year, now.month, now.day);
    final from = DateTime(today.year, today.month, today.day - days);
    final byId = {for (final a in accounts) a.id: a};
    var cash = 0.0;
    final cards = <String, double>{};
    for (final tx in transactions) {
      if (tx.type != 'expense') continue;
      final d = DateTime(tx.date.year, tx.date.month, tx.date.day);
      if (d.isBefore(from) || !d.isBefore(today)) continue;
      final a = byId[tx.accountId];
      if (a == null || a.excludeFromTotal || a.isGold) continue;
      final m = metadata[tx.id];
      if (m != null &&
          (m.isPending ||
              m.expenseClass == 'extraordinary' ||
              m.source == 'recurring' ||
              m.source == 'installment' ||
              m.installmentTotal != null)) continue;
      if (tx.id.startsWith('recurring:') || FinanceRules.isNeutral(tx, m))
        continue;
      final spent = tx.currency.isEmpty ? a.currency : tx.currency;
      if (a.type == 'credit') {
        final rate = convert(1, a.currency);
        cards[a.id] = (cards[a.id] ?? 0) +
            (spent == a.currency || rate == 0
                ? tx.amount
                : convert(tx.amount, spent) / rate);
      } else {
        cash += convert(tx.amount, spent);
      }
    }
    double perDay(double v) => (v / days * 100).round() / 100;
    return DailySpending(perDay(cash), currency, {
      for (final e in cards.entries)
        if (perDay(e.value) > 0) e.key: perDay(e.value)
    });
  }
}
