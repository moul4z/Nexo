import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexo/models/models.dart';
import 'package:nexo/models/transaction_metadata.dart';
import 'package:nexo/services/reconciliation.dart';

/// The cases the app and the connector must settle the same way
/// (`node tool/test_nexo_mcp.mjs` runs the same file against
/// `supabase/functions/nexo-mcp/reconcile.ts`). Fictitious names and amounts.
void main() {
  final fixture =
      jsonDecode(File('test/fixtures/reconcile_cases.json').readAsStringSync())
          as Map<String, dynamic>;
  // Brasília time, whatever the machine's zone.
  DateTime at(String local) => DateTime.parse('$local-03:00');

  PendingMovement movement(Map<String, dynamic> m) => PendingMovement(
      id: m['id'] as String,
      amountCents: m['cents'] as int,
      description: m['description'] as String,
      kind: m['kind'] as String? ??
          (m['direction'] == 'in' ? 'income' : 'expense'),
      medium: m['medium'] as String? ?? 'bank',
      occurredAt: at(m['at'] as String),
      direction: m['direction'] as String?,
      accountId: m['accountId'] as String?,
      nexoAccountId: m['nexoAccountId'] as String?,
      operationRef: m['operationRef'] as String?,
      paymentRef: m['paymentRef'] as String?,
      sameOwner: m['sameOwner'] as bool?,
      counterparty: m['counterparty'] as String?,
      vanished: m['vanished'] as bool? ?? false);

  for (final c in (fixture['cases'] as List).cast<Map<String, dynamic>>()) {
    test(c['name'] as String, () {
      final entries =
          (c['entries'] as List? ?? const []).cast<Map<String, dynamic>>();
      final result = reconcile(
          pending: [
            for (final m
                in (c['movements'] as List).cast<Map<String, dynamic>>())
              movement(m)
          ],
          transactions: [
            for (final e in entries)
              AppTransaction(
                  id: e['id'] as String,
                  type: e['type'] as String,
                  amount: (e['cents'] as int) / 100,
                  description: e['description'] as String,
                  accountId: e['accountId'] as String,
                  categoryId: e['categoryId'] as String? ?? '',
                  date: DateTime.parse(e['day'] as String))
          ],
          metadata: {
            for (final e in entries)
              e['id'] as String: TransactionMetadata(
                  transactionId: e['id'] as String,
                  source: e['source'] as String? ?? 'manual')
          },
          ownerNames: (fixture['owner'] as List).cast<String>(),
          // Like the app: an entry of a confirmed movement is taken.
          linkedIds: {
            for (final s in (c['settled'] as List? ?? const []))
              (s as Map)['transactionId'] as String
          },
          creditAccounts:
              (fixture['creditAccounts'] as List).cast<String>().toSet(),
          settled: [
            for (final s in (c['settled'] as List? ?? const [])
                .cast<Map<String, dynamic>>())
              (
                movement((s['movement'] as Map).cast<String, dynamic>()),
                s['transactionId'] as String
              )
          ],
          rules: [
            for (final r in (c['rules'] as List? ?? const [])
                .cast<Map<String, dynamic>>())
              ReconcileRule(
                  id: r['id'] as String,
                  pattern: r['pattern'] as String,
                  type: r['type'] as String,
                  categoryId: r['categoryId'] as String? ?? '',
                  auto: r['auto'] == true,
                  targetAccountId: r['targetAccountId'] as String?)
          ],
          recurring: [
            for (final r in (c['recurring'] as List? ?? const [])
                .cast<Map<String, dynamic>>())
              RecurringDue(
                  id: r['id'] as String,
                  name: r['name'] as String,
                  accountId: r['accountId'] as String,
                  type: r['type'] as String,
                  amountCents: r['cents'] as int,
                  date: DateTime.parse(r['day'] as String))
          ],
          receivables: [
            for (final r in (c['receivables'] as List? ?? const [])
                .cast<Map<String, dynamic>>())
              OpenReceivable(
                  id: r['id'] as String,
                  personId: r['personId'] as String,
                  names: (r['names'] as List).cast<String>(),
                  amountCents: r['cents'] as int,
                  date: DateTime.parse(r['day'] as String))
          ],
          now: at(fixture['now'] as String));
      final got = {
        for (final m in result)
          m.movement.id: <String, Object>{
            'resolution': m.resolution == Resolution.yieldIncome
                ? 'yield'
                : m.resolution.name,
            'automatic': m.automatic,
            if (m.transaction != null) 'transactionId': m.transaction!.id,
            if (m.pair != null) 'pairId': m.pair!.id,
            if (m.fromAccountId != null) 'fromAccountId': m.fromAccountId!,
            if (m.toAccountId != null) 'toAccountId': m.toAccountId!,
            if (m.waiting) 'waiting': true,
            if (m.wrongAccount) 'wrongAccount': true,
            if (m.categoryId != null) 'categoryId': m.categoryId!,
            if (m.ruleId != null) 'ruleId': m.ruleId!,
            if (m.withIof != null) 'withIof': m.withIof!.id,
            if (m.recurringId != null) 'recurringId': m.recurringId!,
            if (m.receivableId != null) 'receivableId': m.receivableId!,
          }
      };
      expect(got, c['expect']);
    });
  }
}
