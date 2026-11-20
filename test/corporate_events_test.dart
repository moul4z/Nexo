// Desdobramento, grupamento and bonificação (C2): the quantity changes on the
// data com, cost follows the rule of each event and no money moves. Also the
// schema 31 rebuild of investment_operations. Fictitious names and amounts.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexo/database/database_platform.dart';
import 'package:nexo/database/db_helper.dart';
import 'package:nexo/investments/investment_models.dart';
import 'package:nexo/investments/investment_repository.dart';
import 'package:nexo/models/models.dart';
import 'package:nexo/sync/ledger_capture.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const unit = investmentScale;
  final day = DateTime(2026, 3, 2);
  Investment asset({String currency = 'BRL'}) => Investment(
      id: 'asset',
      name: 'Ação fictícia',
      assetClass: 'Ações',
      ticker: 'XPTO3',
      priceMicros: 10 * unit,
      priceAt: day,
      currency: currency);
  InvestmentOperation op(String id, String kind, int micros, int cents,
          {int days = 0, String? account}) =>
      InvestmentOperation(
          id: id,
          investmentId: 'asset',
          kind: kind,
          quantity: micros,
          cents: cents,
          date: day.add(Duration(days: days)),
          createdAt: day.add(Duration(days: days)),
          cashAccountId: account);
  final hundred = op('buy', 'buy', 100 * unit, 100000);

  group('the position', () {
    test('desdobramento 1:2: 200 units, same cost, half the average', () {
      final p = InvestmentPosition(asset(), [hundred]);
      final split = p.event(
          id: 'e',
          kind: 'split',
          day: day.add(const Duration(days: 5)),
          from: 1,
          to: 2);
      expect(split.quantity, 100 * unit);
      expect(split.cents, 0);
      final after = InvestmentPosition(asset(), [hundred, split]);
      expect(after.quantity, 200 * unit);
      expect(after.cost, 100000);
      expect(after.averageCost, 500, reason: 'R\$ 5 per unit');
      expect(after.purchases, 100000, reason: 'an event is not a purchase');
    });

    test('grupamento 10:1 of 105: 10.5, and the fraction sold apart', () {
      final p =
          InvestmentPosition(asset(), [op('buy', 'buy', 105 * unit, 105000)]);
      final group = p.event(
          id: 'g',
          kind: 'reverse_split',
          day: day.add(const Duration(days: 5)),
          from: 10,
          to: 1);
      expect(group.quantity, 945 * unit ~/ 10);
      final grouped = InvestmentPosition(asset(), [...p.operations, group]);
      expect(grouped.quantity, 10500000);
      expect(grouped.cost, 105000);
      final fraction = op('frac', 'sell', 500000, 4000, days: 9);
      final sold =
          InvestmentPosition(asset(), [...grouped.operations, fraction]);
      expect(sold.quantity, 10 * unit);
      expect(sold.cost, 100000, reason: 'the fraction takes its share of cost');
      expect(sold.realized, 4000 - 5000);
    });

    test('bonificação of 10% at R\$ 3: 110 units, cost R\$ 1.030', () {
      final p = InvestmentPosition(asset(), [hundred]);
      final bonus = p.event(
          id: 'b',
          kind: 'bonus',
          day: day.add(const Duration(days: 5)),
          from: bonusRatio(10).$1,
          to: bonusRatio(10).$2,
          unitCostCents: 300);
      expect(bonus.quantity, 10 * unit);
      expect(bonus.cents, 3000);
      final after = InvestmentPosition(asset(), [hundred, bonus]);
      expect(after.quantity, 110 * unit);
      expect(after.cost, 103000);
      expect(after.purchases, 100000, reason: 'not a contribution');
    });

    test('counts what was held at the end of the data com', () {
      final later = op('later', 'buy', 50 * unit, 50000, days: 10);
      final p = InvestmentPosition(asset(), [hundred, later]);
      final split = p.event(
          id: 'e',
          kind: 'split',
          day: day.add(const Duration(days: 5)),
          from: 1,
          to: 3);
      expect(split.quantity, 200 * unit, reason: 'only the 100 of before');
      expect(InvestmentPosition(asset(), [...p.operations, split]).quantity,
          350 * unit);
      // A trade on the data com itself comes before the event.
      final sameDay = op('same', 'buy', 10 * unit, 10000, days: 5);
      final q = InvestmentPosition(asset(), [hundred, sameDay]);
      expect(
          q
              .event(
                  id: 'e2',
                  kind: 'split',
                  day: day.add(const Duration(days: 5)),
                  from: 1,
                  to: 2)
              .quantity,
          110 * unit);
    });

    test('refuses what would not make sense', () {
      final p = InvestmentPosition(asset(), [hundred]);
      final later = day.add(const Duration(days: 1));
      expect(() => p.event(id: 'x', kind: 'split', day: later, from: 2, to: 1),
          throwsFormatException);
      expect(
          () => p.event(
              id: 'x', kind: 'reverse_split', day: later, from: 1, to: 10),
          throwsFormatException);
      expect(
          () => p.event(
              id: 'x',
              kind: 'split',
              day: day.subtract(const Duration(days: 1)),
              from: 1,
              to: 2),
          throwsFormatException,
          reason: 'nothing was held yet');
      expect(
          () => InvestmentPosition(asset(currency: 'USD'), [])
              .event(id: 'x', kind: 'bonus', day: later, from: 100, to: 110),
          throwsFormatException);
      // An event never carries money or an account.
      expect(() => op('x', 'split', unit, 100, days: 1).validate(),
          throwsFormatException);
      expect(
          () =>
              op('x', 'bonus', unit, 100, days: 1, account: 'bank').validate(),
          throwsFormatException);
      expect(
          () => InvestmentPosition(asset(),
              [hundred, op('x', 'reverse_split', 100 * unit, 0, days: 1)]),
          throwsFormatException,
          reason: 'a grupamento never takes everything');
    });
  });

  group('the database', () {
    late Directory dir;
    setUp(() async {
      await DBHelper.close();
      dir = await Directory.systemTemp.createTemp('nexo-events-');
      await DatabasePlatform.initialize(testDirectory: dir.path);
    });
    tearDown(() async {
      await DBHelper.close();
      try {
        await dir.delete(recursive: true);
      } catch (_) {}
    });

    test('an event moves no account and can be removed', () async {
      await DBHelper.insertAccount(Account(
          id: 'bank',
          name: 'Banco fictício',
          type: 'bank',
          currency: 'BRL',
          balance: 2000,
          colorValue: 0));
      final repo = InvestmentRepository();
      await repo.create(
          asset(), op('buy', 'buy', 100 * unit, 100000, account: 'bank'));
      final before = await DBHelper.getTransactions();
      final p = (await repo.load()).single;
      await repo.record(p.event(
          id: 'b',
          kind: 'bonus',
          day: day.add(const Duration(days: 3)),
          from: 100,
          to: 110,
          unitCostCents: 300));
      final after = (await repo.load()).single;
      expect(after.quantity, 110 * unit);
      expect(after.cost, 103000);
      expect((await DBHelper.getAccounts()).single.balance, 1000);
      expect((await DBHelper.getTransactions()).length, before.length);
      await repo.removeOperation('b');
      expect((await repo.load()).single.quantity, 100 * unit);
      expect((await DBHelper.getAccounts()).single.balance, 1000);
    });

    test(
        'schema 31 rebuilds the operations of an older file, rows and sync intact',
        () async {
      final db = await DBHelper.database;
      await LedgerCapture.install(db);
      // The table as schema 30 had it, with a few rows and its triggers.
      await db.execute('DROP TABLE investment_operations');
      await db.execute('''CREATE TABLE investment_operations (
        id TEXT PRIMARY KEY, investment_id TEXT NOT NULL,
        kind TEXT NOT NULL CHECK(kind IN ('buy','sell','opening','income')),
        quantity INTEGER NOT NULL CHECK(quantity >= 0),
        cents INTEGER NOT NULL CHECK(cents >= 0),
        date TEXT NOT NULL, created_at TEXT NOT NULL, cash_account_id TEXT,
        brl_cents INTEGER, tax_cents INTEGER NOT NULL DEFAULT 0)''');
      await db.execute(
          'CREATE INDEX investment_ops_asset ON investment_operations(investment_id)');
      await db.insert('investments', asset().toMap());
      for (final o in [
        hundred,
        op('sell', 'sell', 30 * unit, 36000, days: 2, account: 'x'),
        op('div', 'income', 0, 1250, days: 4),
      ]) {
        await db.insert('investment_operations', o.toMap());
      }
      await LedgerCapture.ensureTriggers(db);
      Future<List<Map<String, Object?>>> rows() =>
          db.query('investment_operations', orderBy: 'id');
      final original = await rows();
      final log = (await db.query('sync_capture_log')).length;
      await expectLater(
          db.insert('investment_operations',
              op('s', 'split', unit, 0, days: 6).toMap()),
          throwsA(isA<DatabaseException>()),
          reason: 'the old table refuses the new kinds');
      await db.execute('PRAGMA user_version = 30');
      await DBHelper.close();

      final upgraded = await DBHelper.database;
      final table = await upgraded.rawQuery(
          "SELECT sql FROM sqlite_master WHERE name = 'investment_operations'");
      expect(table.single['sql'] as String,
          contains(InvestmentRepository.eventsCheck));
      expect(await upgraded.query('investment_operations', orderBy: 'id'),
          original);
      final objects = await upgraded.rawQuery(
          "SELECT type, name FROM sqlite_master WHERE tbl_name = 'investment_operations'");
      expect(objects.map((o) => o['name']).toSet(), {
        'investment_operations',
        'investment_ops_asset',
        'sqlite_autoindex_investment_operations_1',
        'sync_capture_investment_operations_ins',
        'sync_capture_investment_operations_upd',
        'sync_capture_investment_operations_del',
      });
      expect((await upgraded.query('sync_capture_log')).length, log,
          reason: 'the copy is not a change to sync');
      await upgraded.insert(
          'investment_operations', op('s', 'split', unit, 0, days: 6).toMap());
      expect(
          (await upgraded.query('sync_capture_log',
                  where: 'table_name = ?',
                  whereArgs: ['investment_operations']))
              .length,
          greaterThan(0),
          reason: 'the triggers came back');
    });
  });
}
