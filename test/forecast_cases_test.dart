// The same cases as the connector (tool/test_nexo_mcp.mjs): the app's cash
// forecast and get_cash_projection give the same movements, day by day.
// What is late counts today. Fictitious names and amounts.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexo/models/models.dart';
import 'package:nexo/models/transaction_metadata.dart';
import 'package:nexo/services/cash_forecast.dart';
import 'package:nexo/services/cash_simulation.dart';
import 'package:nexo/services/daily_spending.dart';

void main() {
  final cases =
      (jsonDecode(File('test/fixtures/forecast_cases.json').readAsStringSync())
          as Map<String, dynamic>)['cases'] as List<dynamic>;
  DateTime date(String s) => DateTime.parse(s);
  String iso(DateTime d) => d.toIso8601String().substring(0, 10);

  for (final raw in cases) {
    final c = raw as Map<String, dynamic>;
    test('forecast fixture: ${c['name']}', () {
      final today = date(c['today'] as String);
      final accounts = [
        for (final a in c['accounts'] as List)
          Account(
              id: a['id'] as String,
              name: a['id'] as String,
              type: a['type'] as String,
              balance: (a['balance'] as num).toDouble(),
              currency: 'BRL',
              colorValue: 0,
              statementDay: a['statementDay'] as int?,
              dueDay: a['dueDay'] as int?,
              linkedAccountId: a['linkedAccountId'] as String?,
              excludeFromTotal: a['excludeFromTotal'] == true,
              interestMonthlyPercent:
                  (a['interestMonthlyPercent'] as num?)?.toDouble())
      ];
      final txs = (c['transactions'] as List?) ?? const [];
      final transactions = [
        for (final t in txs)
          AppTransaction(
              id: t['id'] as String,
              type: t['type'] as String,
              amount: (t['amount'] as num).toDouble(),
              description: t['id'] as String,
              accountId: t['accountId'] as String,
              categoryId: '',
              date: date('${t['date']}T12:00:00'))
      ];
      final metadata = {
        for (final t in txs)
          if (t['status'] != null ||
              t['expenseClass'] != null ||
              t['excludeFromSpending'] == true ||
              t['source'] != null)
            t['id'] as String: TransactionMetadata(
                transactionId: t['id'] as String,
                status: (t['status'] as String?) ?? 'paid',
                dueDate:
                    t['dueDate'] == null ? null : date(t['dueDate'] as String),
                expenseClass: (t['expenseClass'] as String?) ?? 'normal',
                excludeFromSpending: t['excludeFromSpending'] == true,
                source: (t['source'] as String?) ?? 'manual')
      };
      final recurring = [
        for (final r in (c['recurring'] as List?) ?? const [])
          RecurringPayment(
              id: r['id'] as String,
              name: r['name'] as String,
              accountId: r['accountId'] as String,
              categoryId: '',
              amount: (r['amount'] as num).toDouble(),
              paymentType: r['type'] as String,
              freqVal: (r['freqVal'] as int?) ?? 1,
              freqUnit: (r['freqUnit'] as String?) ?? 'months',
              startDate: date(r['startDate'] as String),
              nextDate: date(r['nextDate'] as String),
              endDate:
                  r['endDate'] == null ? null : date(r['endDate'] as String),
              recurringType: (r['kind'] as String?) ?? 'subscription')
      ];
      final now = today.add(const Duration(hours: 9));
      final until = date(c['until'] as String);
      double same(double v, String _) => v;
      final asked = c['daily'];
      final daily = asked == null
          ? null
          : asked == 'average'
              ? DailySpending.average(
                  now: now,
                  accounts: accounts,
                  transactions: transactions,
                  metadata: metadata,
                  currency: 'BRL',
                  convert: same)
              : DailySpending((asked as num).toDouble(), 'BRL');
      CashForecast forecast(DailySpending? daily) => CashForecast.calculate(
          now: now,
          until: until,
          accounts: accounts,
          transactions: transactions,
          recurring: recurring,
          metadata: metadata,
          invoicePayments: [
            for (final p in (c['invoicePayments'] as List?) ?? const [])
              Map<String, dynamic>.from(p as Map)
          ],
          convert: same,
          daily: daily);
      final out = forecast(daily);
      int cents(double v) => (v * 100).round();
      final got = [
        for (final e in out.events)
          if (e.amount != 0 && e.kind != 'estimate')
            [iso(e.date.isBefore(today) ? today : e.date), cents(e.amount)]
      ]..sort(_byDayThenAmount);
      final expect_ = c['expect'] as Map<String, dynamic>;
      final want = [
        for (final e in expect_['events'] as List) [e[0] as String, e[1] as int]
      ]..sort(_byDayThenAmount);
      expect(got, want);
      expect(cents(out.current), expect_['start']);
      expect(cents(out.projected), expect_['end']);
      if (expect_['safePerDay'] != null)
        expect(cents(CashForecast.safePerDay(forecast(null), now, until, same)),
            expect_['safePerDay']);
      final simulate = c['simulate'] as List?;
      if (simulate == null) return;
      final classes = {
        for (final i in (c['investments'] as List?) ?? const [])
          i['id'] as String: i['assetClass'] as String
      };
      final sim = CashSimulation.run(
          base: out,
          events: [
            for (final e in simulate)
              SimEvent(e['kind'] as String, (e['amount'] as num).toDouble(),
                  date: e['date'] == null ? null : date(e['date'] as String),
                  label: (e['label'] as String?) ?? '',
                  assetClass: classes[e['investmentId']],
                  cardId: e['cardId'] as String?)
          ],
          now: now,
          until: until,
          accounts: accounts,
          convert: same);
      final wantSim = expect_['simulation'] as Map<String, dynamic>;
      expect(cents(sim.after.end), wantSim['end']);
      expect([iso(sim.after.lowestDate), cents(sim.after.lowest)],
          wantSim['lowest']);
      expect(cents(sim.missing), wantSim['missing']);
      expect(cents(sim.before.end), expect_['end']);
      expect(
          [
            for (final i in sim.added) [iso(i.date), cents(i.amount)]
          ]..sort(_byDayThenAmount),
          wantSim['added']);
    });
  }
}

int _byDayThenAmount(List<Object> a, List<Object> b) {
  final d = (a[0] as String).compareTo(b[0] as String);
  return d != 0 ? d : (a[1] as int) - (b[1] as int);
}
