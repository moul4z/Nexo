// The Simular screen: an event added there changes the forecast shown and
// records nothing. Fictitious names and amounts.
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:nexo/database/database_platform.dart';
import 'package:nexo/database/db_helper.dart';
import 'package:nexo/models/models.dart';
import 'package:nexo/providers/app_provider.dart';
import 'package:nexo/screens/simulate_screen.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';
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
    root = await Directory.systemTemp.createTemp('nexo-simulate-');
    await DBHelper.close();
    await DatabasePlatform.initialize(testDirectory: p.join(root.path, 'db'));
    app = AppProvider()..settings.budgetAlertsEnabled = false;
    app.settings.currency = 'BRL';
    await app.addAccount(Account(
        id: 'bank',
        name: 'Banco fictício',
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

  testWidgets('a purchase bigger than the cash shows what would be missing',
      (tester) async {
    tester.view.physicalSize = const Size(420, 2000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(ChangeNotifierProvider.value(
        value: app, child: const MaterialApp(home: SimulateScreen())));
    Future<void> settle(bool Function() done) async {
      for (var i = 0; i < 200; i++) {
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 30)));
        await tester.pump();
        if (i >= 3 && done()) break;
      }
    }

    bool shows(Pattern text) => find.textContaining(text).evaluate().isNotEmpty;
    await settle(() => shows('Sem os eventos'));
    expect(tester.takeException(), isNull);
    expect(find.textContaining('Faltariam'), findsNothing);
    await tester.tap(find.widgetWithText(FilledButton, 'Adicionar'));
    await settle(() => shows('Adicionar evento'));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.enterText(find.widgetWithText(TextField, 'Valor'), '1500');
    await tester.enterText(
        find.widgetWithText(TextField, 'Descrição (opcional)'), 'Geladeira');
    await tester.tap(find.widgetWithText(FilledButton, 'Adicionar').last);
    await tester.pump(const Duration(milliseconds: 500));
    await settle(() => shows('Faltariam'));
    expect(find.textContaining('Faltariam'), findsOneWidget);
    expect(find.text('Geladeira'), findsWidgets);
    expect(app.transactions, isEmpty, reason: 'a simulation records nothing');
    expect(app.accountById('bank')!.balance, 1000);
    await tester.pumpWidget(const SizedBox());
    debugDefaultTargetPlatformOverride = null;
  });
}
