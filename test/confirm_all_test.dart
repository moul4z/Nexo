// "Confirmar todas" in Para revisar: only what has a suggested category and
// a linked account, through the same path as one by one; a second tap or
// another device never duplicates. Fictitious names and amounts.
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late AppProvider app;
  final now = DateTime.now();
  final yesterday = DateTime(now.year, now.month, now.day - 1, 10);

  setUpAll(() async {
    await initializeDateFormatting('pt_BR');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('home_widget'), (call) async => true);
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    root = await Directory.systemTemp.createTemp('nexo-confirm-all-');
    await DBHelper.close();
    await DatabasePlatform.initialize(testDirectory: p.join(root.path, 'db'));
    app = AppProvider()..settings.budgetAlertsEnabled = false;
    app.categories = await DBHelper.getCategories();
    await app.addAccount(Account(
        id: 'bank',
        name: 'Banco fictício',
        type: 'bank',
        balance: 1000,
        currency: 'BRL',
        colorValue: 0));
    // What the person entered before: the bakery is food.
    await app.addTransaction(AppTransaction(
        id: 'old',
        type: 'expense',
        amount: 7.5,
        description: 'Padaria Exemplo',
        accountId: 'bank',
        categoryId: 'food_exp',
        date: now.subtract(const Duration(days: 20))));
  });

  tearDown(() async {
    debugDefaultTargetPlatformOverride = null;
    await DBHelper.close();
    try {
      await root.delete(recursive: true);
    } catch (_) {}
  });

  Future<void> suggestion(
          String id, int cents, String text, DateTime at) async =>
      (await DBHelper.database).insert('notification_suggestions', {
        'id': 'pluggy:$id',
        'app_id': 'pluggy',
        'amount_cents': cents,
        'description': text,
        'kind': 'expense',
        'medium': 'bank',
        'occurred_at': at.millisecondsSinceEpoch,
        'status': 'pending',
        'direction': 'out',
        'bank_account_id': 'acc-1',
        'nexo_account_id': 'bank',
        'bank': 'Banco fictício',
      });

  testWidgets('confirms only what has a category, once, on the day asked',
      (tester) async {
    tester.view.physicalSize = const Size(420, 2000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.runAsync(() async {
      await suggestion('p1', 1290, 'PADARIA EXEMPLO', yesterday);
      await suggestion('p2', 990, 'PADARIA EXEMPLO',
          yesterday.add(const Duration(hours: 5)));
      await suggestion('x', 15990, 'LOJA DESCONHECIDA SA', yesterday);
      await suggestion('older', 2290, 'PADARIA EXEMPLO',
          yesterday.subtract(const Duration(days: 3)));
    });
    await tester.pumpWidget(ChangeNotifierProvider.value(
        value: app,
        child: MaterialApp(
            locale: const Locale('pt'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: NotificationInboxScreen(
                day: DateTime(
                    yesterday.year, yesterday.month, yesterday.day)))));
    Future<void> settle(bool Function() done) async {
      for (var i = 0; i < 200; i++) {
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 30)));
        await tester.pump();
        if (i >= 5 && done()) break;
      }
    }

    bool shows(Pattern text) => find.textContaining(text).evaluate().isNotEmpty;
    await settle(() => shows('com categoria sugerida'));
    expect(tester.takeException(), isNull);
    // Only yesterday: the older bakery is out of the count.
    expect(find.text('Confirmar 2 com categoria sugerida'), findsOneWidget);
    await tester.tap(find.text('Confirmar 2 com categoria sugerida'));
    await settle(() => shows('Confirmar 2 lançamentos?'));
    await tester.tap(find.widgetWithText(FilledButton, 'Confirmar'));
    await settle(() => app.transactions.length == 3);
    final made = app.transactions.where((t) => t.id != 'old').toList()
      ..sort((a, b) => a.id.compareTo(b.id));
    expect([
      for (final t in made) (t.id, t.amount, t.categoryId)
    ], [
      ('notification:pluggy:p1', 12.90, 'food_exp'),
      ('notification:pluggy:p2', 9.90, 'food_exp'),
    ]);
    final rows = await tester.runAsync(() async => (await DBHelper.database)
        .query('notification_suggestions',
            columns: ['id', 'status'], orderBy: 'id'));
    expect({
      for (final r in rows!) r['id']: r['status']
    }, {
      'pluggy:older': 'pending',
      'pluggy:p1': 'confirmed',
      'pluggy:p2': 'confirmed',
      'pluggy:x': 'pending',
    });
    // The whole list again, then nothing left to confirm in bulk.
    await tester.tap(find.textContaining('ver tudo'));
    await settle(
        () => shows('LOJA DESCONHECIDA') && !shows('com categoria sugerida'));
    expect(find.textContaining('com categoria sugerida'), findsNothing,
        reason: 'one left with a category is not a bulk');
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpWidget(const SizedBox());
    debugDefaultTargetPlatformOverride = null;
  });
}
