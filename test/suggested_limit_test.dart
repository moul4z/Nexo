// The limit suggested in the budget form: the same numbers as the
// connector's test (tool/test_nexo_mcp.mjs). Fictitious values.
import 'package:flutter_test/flutter_test.dart';
import 'package:nexo/models/models.dart';
import 'package:nexo/models/transaction_metadata.dart';
import 'package:nexo/services/suggested_limit.dart';

void main() {
  AppTransaction row(String id, double amount, DateTime date,
          {String category = 'mercado'}) =>
      AppTransaction(
          id: id,
          type: 'expense',
          amount: amount,
          description: id,
          accountId: 'main',
          categoryId: category,
          date: date);

  test('median of the 3 closed months, rounded up to 10; real spending only',
      () {
    final transactions = [
      row('ago', 1200, DateTime(2026, 8, 10)),
      row('set', 380, DateTime(2026, 9, 12)),
      row('out', 400.5, DateTime(2026, 10, 3)),
      row('out-tv', 3000, DateTime(2026, 10, 5)),
      row('out-pend', 99, DateTime(2026, 10, 6)),
      row('nov', 999, DateTime(2026, 11, 2)),
    ];
    final metadata = {
      'out-tv': const TransactionMetadata(
          transactionId: 'out-tv', expenseClass: 'extraordinary'),
      'out-pend': const TransactionMetadata(
          transactionId: 'out-pend', status: 'pending'),
    };
    double? suggest(String category) => SuggestedLimit.monthly(
        categoryId: category,
        now: DateTime(2026, 11, 20),
        transactions: transactions,
        metadata: metadata,
        toMain: (t) => t.amount);
    expect(suggest('mercado'), 410);
    expect(suggest('bar'), isNull);
  });
}
