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
import 'package:nexo/providers/app_provider.dart';
import 'package:nexo/screens/notification_inbox_screen.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A bank movement that is the open occurrence of a recurring pays the
/// recurring (once), instead of a loose entry that leaves it open and makes
/// the forecast count it twice. Fictitious names and amounts.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late AppProvider app;
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final morning = today.add(const Duration(hours: 9));

  setUpAll(() async {
    await initializeDateFormatting('pt_BR');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('home_widget'), (call) async => true);
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    root = await Directory.systemTemp.createTemp('nexo-recurring-bank-');
    await DBHelper.close();
    await DatabasePlatform.initialize(testDirectory: p.join(root.path, 'db'));
    app = AppProvider()..settings.budgetAlertsEnabled = false;
    app.categories = await DBHelper.getCategories();
    await app.addAccount(Account(
        id: 'card',
        name: 'Cartão fictício',
        type: 'credit',
        balance: 0,
        currency: 'BRL',
        colorValue: 0,
        statementDay: 19,
        dueDay: 26,
        creditLimit: 650));
    await app.addRecurring(RecurringPayment(
        id: 'stream',
        name: 'Streaming Exemplo',
        accountId: 'card',
        categoryId: 'food_exp',
        amount: 39.90,
        freqVal: 1,
        freqUnit: 'months',
        startDate: today,
        nextDate: today));
  });

  tearDown(() async {
    debugDefaultTargetPlatformOverride = null;
    await DBHelper.close();
    try {
      await root.delete(recursive: true);
    } catch (_) {}
  });

  Future<void> suggestion(String id, int cents) async =>
      (await DBHelper.database).insert('notification_suggestions', {
        'id': 'pluggy:$id',
        'app_id': 'pluggy',
        'amount_cents': cents,
        'description': 'STREAMING EXEMPLO',
        'kind': 'expense',
        'medium': 'credit',
        'occurred_at': morning.millisecondsSinceEpoch,
        'status': 'pending',
        'direction': 'out',
        'bank_account_id': 'acc-card',
        'nexo_account_id': 'card',
        'bank': 'Banco fictício',
      });

  RecurringPayment stream() =>
      app.recurring.singleWhere((r) => r.id == 'stream');

  test(
      'paid from the bank: the bank amount and day, the occurrence advances, once',
      () async {
    await suggestion('m', 4250);
    final open = stream();
    final id = await app.payRecurringFromBank(open,
        suggestionId: 'pluggy:m', amount: 42.50, paidOn: morning);
    expect(id, 'recurring:stream:${today.toIso8601String()}');
    final entry = app.transactions.singleWhere((t) => t.id == id);
    expect(entry.amount, 42.50);
    expect(entry.date, morning);
    expect(entry.accountId, 'card');
    expect(app.transactionMetadata[id]!.source, 'recurring');
    final row = (await (await DBHelper.database).query(
            'notification_suggestions',
            where: 'id = ?',
            whereArgs: ['pluggy:m']))
        .single;
    expect([row['status'], row['transaction_id']], ['confirmed', id]);
    // The forecast reads the next date: this occurrence is no longer open.
    expect(stream().nextDate, open.calcNextDate());
    expect(stream().amount, 39.90,
        reason: 'the registered value changes only when asked');
    // A second tap, or another screen still showing the old occurrence.
    await expectLater(
        app.payRecurringFromBank(open,
            suggestionId: 'pluggy:m', amount: 42.50, paidOn: morning),
        throwsStateError);
    expect(app.transactions, hasLength(1));
  });

  test('"Já foi paga": an entry typed by hand is the occurrence; nothing new',
      () async {
    await app.addTransaction(AppTransaction(
        id: 'typed',
        type: 'expense',
        amount: 39.90,
        description: 'Streaming exemplo',
        accountId: 'card',
        categoryId: 'food_exp',
        date: today.add(const Duration(days: 1))));
    final open = stream();
    expect(app.recurringPaidCandidates(open).map((t) => t.id), ['typed']);
    await app.linkRecurringToEntry(open, 'typed');
    expect(app.transactions.map((t) => t.id), ['typed']);
    expect(stream().nextDate, open.calcNextDate());
    expect(app.recurringPaidCandidates(stream()), isEmpty,
        reason: 'next month is far from that entry');
    final history = await app.getHistoryFor('stream');
    expect(history.single.action, 'paid');
  });

  test('an entry of another account, kind or name is not offered', () async {
    for (final (id, account, type, name) in [
      ('other-name', 'card', 'expense', 'Padaria'),
      ('income', 'card', 'income', 'Streaming exemplo'),
    ]) {
      await app.addTransaction(AppTransaction(
          id: id,
          type: type,
          amount: 39.90,
          description: name,
          accountId: account,
          categoryId: type == 'income' ? 'salary' : 'food_exp',
          date: today));
    }
    expect(app.recurringPaidCandidates(stream()), isEmpty);
  });

  testWidgets('Para revisar: "Pagar a recorrente", then the new price on a tap',
      (tester) async {
    tester.view.physicalSize = const Size(400, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.runAsync(() => suggestion('m', 4250));
    await tester.pumpWidget(ChangeNotifierProvider.value(
        value: app,
        child: MaterialApp(
            locale: const Locale('pt'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: const NotificationInboxScreen())));
    Future<void> settle(bool Function() done) async {
      for (var i = 0; i < 200; i++) {
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 30)));
        await tester.pump();
        if (i >= 5 && done()) break;
      }
    }

    bool shows(String text) => find.text(text).evaluate().isNotEmpty;
    await settle(() => shows('Pagar a recorrente'));
    expect(tester.takeException(), isNull);
    expect(find.text('Recorrentes'), findsOneWidget);
    expect(find.textContaining('É Streaming Exemplo'), findsOneWidget);
    expect(find.text('Novas'), findsNothing,
        reason: 'the bill is not a loose new movement');

    await tester.tap(find.text('Pagar a recorrente'));
    await settle(() => shows('Usar o novo valor'));
    expect(find.text('Streaming Exemplo mudou de valor'), findsOneWidget);
    await tester.tap(find.text('Usar o novo valor'));
    await settle(() => stream().amount == 42.50);
    expect(stream().amount, 42.50);
    expect(app.transactions, hasLength(1));
    expect(find.text('Pagar a recorrente'), findsNothing);
    // The confirmation closes itself after a few seconds.
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpWidget(const SizedBox());
    debugDefaultTargetPlatformOverride = null;
  });
}
