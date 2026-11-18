import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:nexo/database/database_platform.dart';
import 'package:nexo/database/db_helper.dart';
import 'package:nexo/l10n/app_localizations.dart';
import 'package:nexo/models/models.dart';
import 'package:nexo/models/transaction_metadata.dart';
import 'package:nexo/providers/app_provider.dart';
import 'package:nexo/screens/account_reconcile_screen.dart';
import 'package:nexo/services/account_reconciliation.dart';
import 'package:nexo/services/balance_check.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The same case as `reconcile_account` in tool/test_nexo_mcp.mjs: the app
/// and the assistant read one account against the bank the same way.
void main() {
  DateTime day(int d) => DateTime(2026, 10, d, 12);

  Account account(String id, [String type = 'bank']) => Account(
      id: id, name: id, type: type, balance: 0, currency: 'BRL', colorValue: 0);

  AppTransaction entry(String id, double amount, int d, String description,
          {String type = 'expense', String account = 'main'}) =>
      AppTransaction(
          id: id,
          type: type,
          amount: amount,
          description: description,
          accountId: account,
          categoryId: 'mercado',
          date: day(d));

  Map<String, dynamic> row(String id, int d, int cents, String description,
          {String status = 'pending',
          String? transactionId,
          String kind = 'expense',
          String direction = 'out',
          String nexoAccount = 'main'}) =>
      {
        'id': 'pluggy:$id',
        'app_id': 'pluggy',
        'amount_cents': cents,
        'description': description,
        'kind': kind,
        'medium': 'bank',
        'occurred_at': day(d).millisecondsSinceEpoch,
        'status': status,
        'transaction_id': transactionId,
        'direction': direction,
        'bank_account_id': 'acc-1',
        'nexo_account_id': nexoAccount,
        'bank': 'Banco A',
      };

  final transactions = [
    entry('e1', 50, 21, 'Mercado Bom'),
    entry('e2', 30, 22, 'Padaria Exemplo'),
    entry('e3', 20, 23, 'Feira em dinheiro'),
    entry('e4', 99, 24, 'Conta que vence depois'),
    entry('old', 10, 1, 'Antes do período'),
  ];
  final metadata = {
    'e4': TransactionMetadata(
        transactionId: 'e4', status: 'pending', dueDate: DateTime(2026, 11, 5)),
  };
  final rows = [
    row('m1', 21, 5000, 'MERCADO BOM',
        status: 'confirmed', transactionId: 'e1'),
    row('m2', 22, 3000, 'Padaria Exemplo'),
    row('m3', 24, 1500, 'Farmácia Exemplo'),
    row('m4', 25, 12, 'Rendimentos', kind: 'income', direction: 'in'),
    row('m5', 26, 700, 'Tarifa', status: 'ignored'),
    row('m6', 10, 99900, 'Fora do período'),
    row('m7', 24, 800, 'De outra conta', nexoAccount: 'nu'),
  ];

  AccountReconciliation read(
          {List<Map<String, dynamic>>? movements,
          Set<String> answered = const {}}) =>
      reconcileAccount(
          accountId: 'main',
          rows: movements ?? rows,
          transactions: transactions,
          metadata: metadata,
          accounts: [account('main'), account('nu', 'credit')],
          from: DateTime(2026, 10, 20),
          to: DateTime(2026, 10, 29),
          alreadyAnswered: answered,
          now: day(29));

  test('what only the bank has, what only the Nexo has, and what it explains',
      () {
    final r = read();
    expect([for (final e in r.onlyBank) (e.match.movement.id, e.cents)],
        [('pluggy:m3', -1500), ('pluggy:m4', 12)]);
    expect(r.onlyBankCents, -1488);
    expect([for (final e in r.onlyNexo) (e.entry.id, e.cents, e.kind)],
        [('e3', -2000, 'Despesa')],
        reason: 'e1 was confirmed, e2 is the same as a pending movement, e4 '
            'has not left the account, old is before the period');
    expect([r.ignoredCount, r.ignoredCents], [1, -700]);
    // Bank = Nexo + only the bank (−15,00 + 0,12 − 7,00) − only the Nexo
    // (−20,00): the difference of −1,88 is all there.
    expect(r.explainedCents, -188);
    expect(reconcileReading(-188, r.explainedCents), contains('exatamente'));
    expect(reconcileReading(-10000, r.explainedCents), contains('não fecha'));
    expect(reconcileReading(0, 0), contains('igual'));
  });

  test('an entry answered by a movement outside the rows is not "only Nexo"',
      () {
    expect(read(answered: {'e3'}).onlyNexo, isEmpty);
  });

  test('a movement of another account, or of an account removed, is not mine',
      () {
    final r = read(movements: [
      row('a', 24, 800, 'De outra conta', nexoAccount: 'nu'),
      row('b', 24, 900, 'Conta apagada', nexoAccount: 'gone'),
    ]);
    expect(r.onlyBank, isEmpty);
    expect(r.ignoredCount, 0);
  });

  test('nothing pending and every entry answered: nothing to explain', () {
    final r = reconcileAccount(
        accountId: 'main',
        rows: [
          row('m1', 21, 5000, 'MERCADO BOM',
              status: 'confirmed', transactionId: 'e1'),
        ],
        transactions: [transactions.first],
        metadata: const {},
        accounts: [account('main')],
        from: DateTime(2026, 10, 20),
        to: DateTime(2026, 10, 29),
        now: day(29));
    expect(r.isEmpty, isTrue);
    expect(r.explainedCents, 0);
  });

  group('screen', () {
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
      root = await Directory.systemTemp.createTemp('nexo-reconcile-');
      await DBHelper.close();
      await DatabasePlatform.initialize(testDirectory: p.join(root.path, 'db'));
      app = AppProvider()..settings.budgetAlertsEnabled = false;
      app.categories = await DBHelper.getCategories();
      await app.addAccount(Account(
          id: 'main',
          name: 'Conta principal',
          type: 'bank',
          balance: 1000,
          currency: 'BRL',
          colorValue: 0));
    });

    tearDown(() async {
      debugDefaultTargetPlatformOverride = null;
      await DBHelper.close();
      try {
        await root.delete(recursive: true);
      } catch (_) {}
    });

    testWidgets('lists what explains the difference and says when it closes',
        (tester) async {
      tester.view.physicalSize = const Size(360, 1400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final category = app.categories.firstWhere((c) => c.type == 'expense').id;
      await tester.runAsync(() async {
        await app.addTransaction(AppTransaction(
            id: 'cash',
            type: 'expense',
            amount: 20,
            description: 'Feira em dinheiro',
            accountId: 'main',
            categoryId: category,
            date: day(23)));
        final db = await DBHelper.database;
        for (final r in [
          row('m3', 24, 1500, 'Farmácia Exemplo'),
          row('m5', 26, 700, 'Tarifa', status: 'ignored'),
        ]) {
          await db.insert('notification_suggestions', r);
        }
      });
      Future<void> settle(String until) async {
        for (var i = 0; i < 200; i++) {
          await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 30)));
          await tester.pump();
          if (i >= 3 && find.textContaining(until).evaluate().isNotEmpty) break;
        }
      }

      // Bank 978 against Nexo 980: −15 and −7 from the bank, −20 only here.
      await tester.pumpWidget(ChangeNotifierProvider.value(
          value: app,
          child: MaterialApp(
              locale: const Locale('pt'),
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home: AccountReconcileScreen(
                  account: app.accountById('main')!,
                  check: const BalanceCheck(
                      bankCents: 97800,
                      nexoAtBankCents: 98000,
                      laterEntries: []),
                  until: day(29)))));
      await settle('Só no Nexo');
      expect(tester.takeException(), isNull);
      expect(find.text('Farmácia Exemplo'), findsOneWidget);
      expect(find.text('Feira em dinheiro'), findsOneWidget);
      expect(find.text('Ignorados por você'), findsOneWidget);
      expect(find.textContaining('exatamente'), findsOneWidget);
      expect(find.textContaining('não fecha'), findsNothing);
      debugDefaultTargetPlatformOverride = null;
    });
  });
}
