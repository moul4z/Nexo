// Internal check (F2): the stored balance against the entries. Normal
// writes never look like a defect; a balance moved without an entry does,
// once, with the exact amount. Temporary database, fictitious values.
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:nexo/database/database_platform.dart';
import 'package:nexo/database/db_helper.dart';
import 'package:nexo/models/models.dart';
import 'package:nexo/models/transaction_metadata.dart';
import 'package:nexo/providers/app_provider.dart';
import 'package:nexo/services/ledger_audit.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late AppProvider app;

  setUpAll(() async {
    await initializeDateFormatting('pt_BR');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('home_widget'), (call) async => true);
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    root = await Directory.systemTemp.createTemp('nexo-ledger-audit-');
    await DBHelper.close();
    await DatabasePlatform.initialize(testDirectory: p.join(root.path, 'db'));
    app = AppProvider()..settings.budgetAlertsEnabled = false;
    app.categories = await DBHelper.getCategories();
    for (final (id, type, balance) in [
      ('bank', 'bank', 1000.0),
      ('other', 'bank', 50.0),
      ('card', 'credit', 0.0),
    ]) {
      await app.addAccount(Account(
          id: id,
          name: 'Conta $id',
          type: type,
          balance: balance,
          currency: 'BRL',
          colorValue: 0,
          statementDay: type == 'credit' ? 19 : null,
          dueDay: type == 'credit' ? 26 : null,
          creditLimit: type == 'credit' ? 1000 : null));
    }
  });

  tearDown(() async {
    debugDefaultTargetPlatformOverride = null;
    await DBHelper.close();
    try {
      await root.delete(recursive: true);
    } catch (_) {}
  });

  AppTransaction entry(String id, String account, double amount,
          {String type = 'expense'}) =>
      AppTransaction(
          id: id,
          type: type,
          amount: amount,
          description: 'Mercado exemplo $id',
          accountId: account,
          categoryId: type == 'income' ? 'salary' : 'food_exp',
          date: DateTime(2026, 11, 10));

  test('entries, a pending one paid later, a transfer and a card: no defect',
      () async {
    expect(await LedgerAudit.run(), isEmpty,
        reason: 'the first check only remembers');
    await app.addTransaction(entry('a', 'bank', 32.90));
    await app.addTransaction(entry('s', 'bank', 1860, type: 'income'));
    await app.addTransaction(entry('c', 'card', 120.45));
    final pending = entry('p', 'bank', 80);
    await app.addTransaction(pending,
        metadata:
            const TransactionMetadata(transactionId: 'p', status: 'pending'));
    await app.addTransfer(fromId: 'bank', toId: 'other', fromAmount: 200);
    expect(await LedgerAudit.run(), isEmpty);
    // The pending one is paid: the balance and the entries move together.
    await app.updateTransaction(pending, pending,
        metadata:
            const TransactionMetadata(transactionId: 'p', status: 'paid'));
    await app.deleteTransaction('a');
    expect(await LedgerAudit.run(), isEmpty);
  });

  test('a balance moved without an entry is reported once, with the amount',
      () async {
    await LedgerAudit.run();
    final db = await DBHelper.database;
    await db.rawUpdate(
        'UPDATE accounts SET balance = balance + 10.5 WHERE id = ?', ['bank']);
    final drifts = await LedgerAudit.run();
    expect([for (final d in drifts) (d.accountId, d.name, d.cents)],
        [('bank', 'Conta bank', 1050)]);
    expect(await LedgerAudit.run(), isEmpty, reason: 'reported once');
    expect(
        (await DBHelper.getAccounts())
            .firstWhere((a) => a.id == 'bank')
            .balance,
        1010.5,
        reason: 'nothing is corrected by itself');
  });

  test('a balance typed by the person, or a whole ledger replaced, starts over',
      () async {
    await LedgerAudit.run();
    final bank = app.accountById('bank')!;
    await app.updateAccount(bank.copyWith(balance: 1500), original: bank);
    expect(await LedgerAudit.run(), isEmpty);
    // Every account at once: a restore or another device's dataset.
    final db = await DBHelper.database;
    await db.rawUpdate('UPDATE accounts SET balance = balance + 1');
    expect(await LedgerAudit.run(), isEmpty);
  });

  test('accounts whose balance also moves without an entry are left out',
      () async {
    final db = await DBHelper.database;
    await db.insert('savings_contributions', {
      'id': 'g1',
      'goal_id': 'goal',
      'amount': 10,
      'account_id': 'other',
      'type': 'contribution',
      'date': '2026-11-10',
    });
    final implied = await LedgerAudit.implied(db);
    expect(implied.keys, unorderedEquals(['bank', 'card']));
    expect(implied['bank'], 100000);
  });
}
