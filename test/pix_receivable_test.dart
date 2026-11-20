// A Pix from someone who owes their part of a split bill (6.4 b): the app
// receives it by itself on the device that writes, it can be undone, and
// the name the bank showed is learned when a receipt typed by hand is tied
// to the Pix. Fictitious names and amounts.
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexo/database/database_platform.dart';
import 'package:nexo/database/db_helper.dart';
import 'package:nexo/models/models.dart';
import 'package:nexo/providers/app_provider.dart';
import 'package:nexo/services/balance_check.dart';
import 'package:nexo/services/finance_rules.dart';
import 'package:nexo/services/inbox_reconciler.dart';
import 'package:nexo/services/inbox_writer.dart';
import 'package:nexo/services/notification_inbox.dart';
import 'package:nexo/services/pluggy_inbox.dart';
import 'package:nexo/services/reconciliation.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

class _Remote implements PluggyRemote {
  final rows = <String, Map<String, dynamic>>{};
  @override
  Future<List<BankAccountSnapshot>> accounts() async => const [];
  @override
  Future<void> link(String accountId, String? nexoAccountId) async {}
  @override
  Future<List<PluggyItem>> refresh({bool force = false}) async => const [];
  @override
  Future<List<PluggyItem>> items() async => const [];
  @override
  Future<void> addItem(String itemId, String label) async {}
  @override
  Future<void> removeItem(String itemId) async {}
  @override
  Future<List<Map<String, dynamic>>> suggestions(int sinceMs) async =>
      [for (final r in rows.values) Map.of(r)];
  @override
  Future<void> decide(List<Map<String, Object?>> list) async {}

  void pix(String id, int cents, String from, DateTime at) =>
      rows['pluggy:$id'] = {
        'id': 'pluggy:$id',
        'amount_cents': cents,
        'kind': 'income',
        'medium': 'bank',
        'description': 'Pix recebido',
        'counterparty': from,
        'occurred_at': at.millisecondsSinceEpoch,
        'review': 'pending',
        'bank': 'Banco fictício',
        'account_id': 'acc-1',
        'nexo_account_id': 'mp',
        'direction': 'in',
      };
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late AppProvider app;
  late _Remote remote;
  final now = DateTime.now();
  final at = DateTime(now.year, now.month, now.day, 9);

  setUpAll(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('home_widget'), (call) async => true);
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    root = await Directory.systemTemp.createTemp('nexo-pix-part-');
    await DBHelper.close();
    await DatabasePlatform.initialize(testDirectory: p.join(root.path, 'db'));
    app = AppProvider()..settings.budgetAlertsEnabled = false;
    app.categories = await DBHelper.getCategories();
    await app.addAccount(Account(
        id: 'mp',
        name: 'Conta fictícia',
        type: 'bank',
        balance: 500,
        currency: 'BRL',
        colorValue: 0));
    remote = _Remote();
    PluggyInbox.instance = PluggyInbox(remote);
  });

  tearDown(() async {
    PluggyInbox.instance = null;
    debugDefaultTargetPlatformOverride = null;
    await DBHelper.close();
    try {
      await root.delete(recursive: true);
    } catch (_) {}
  });

  Future<void> bill(String id, String person) async {
    await app.addTransaction(AppTransaction(
        id: id,
        type: 'expense',
        amount: 55.90,
        description: 'Assinatura fictícia',
        accountId: 'mp',
        categoryId: 'entertainment',
        date: at.subtract(const Duration(days: 3))));
    await app.splitBill(id, [person]);
  }

  Future<InboxState> review() async {
    await PluggyInbox.instance!.sync(force: true);
    return InboxReconciler.run(
        pendingRows: await NotificationInbox.pending(),
        transactions: app.transactions,
        metadata: app.transactionMetadata,
        accounts: app.accounts,
        receivables: openReceivables(app.lended, app.lendedPeople),
        writer: AppInboxWriter(app, canCreate: true));
  }

  test('the Pix settles the part by itself, never as income, and undoes',
      () async {
    await bill('conta', 'Bruna Exemplo');
    final part = app.lended.single;
    expect(part.amount, closeTo(27.95, 1e-9));
    remote.pix('p1', 2795, 'BRUNA EXEMPLO SILVA', at);

    final state = await review();
    expect(state.resolved.single.reason, 'receivable');
    expect(app.lended.single.isSettled, isTrue);
    expect(app.accountById('mp')!.balance, closeTo(500 - 55.90 + 27.95, 1e-9));
    final receipt = app.transactions
        .firstWhere((t) => t.id == 'lended-received:${part.id}');
    expect(FinanceRules.isNeutral(receipt, app.transactionMetadata[receipt.id]),
        isTrue,
        reason: 'paying back is not income');
    expect([
      receipt.date.year,
      receipt.date.month,
      receipt.date.day
    ], [
      at.year,
      at.month,
      at.day
    ], reason: 'the bank\'s day');

    await InboxReconciler.undo(state.resolved.single,
        writer: AppInboxWriter(app, canCreate: true));
    expect(app.lended.single.isSettled, isFalse, reason: 'owed again');
    expect(app.accountById('mp')!.balance, closeTo(500 - 55.90, 1e-9));
  });

  test('a first name alone waits; the name of the Pix is learned on a match',
      () async {
    await bill('conta', 'Bruna');
    remote.pix('p1', 2795, 'BRUNA EXEMPLO SILVA', at);
    var state = await review();
    expect(state.resolved, isEmpty, reason: 'any Bruna would match');
    expect(app.lended.single.isSettled, isFalse);

    // Received by hand on Pessoas; the Pix then is that receipt.
    await app.receiveLended(app.lended.single, 'mp');
    state = await review();
    expect(state.resolved.single.reason, 'linked');
    final people = await DBHelper.getLendedPeople();
    expect(people.single.pixName, 'BRUNA EXEMPLO SILVA');

    // Next bill: her next Pix settles it by itself.
    await bill('conta2', 'Bruna');
    app.lendedPeople = await DBHelper.getLendedPeople();
    remote.pix('p2', 2795, 'BRUNA EXEMPLO SILVA', at);
    state = await review();
    expect(state.resolved.map((r) => r.reason), contains('receivable'));
    expect(app.lended.every((l) => l.isSettled), isTrue);
  });
}
