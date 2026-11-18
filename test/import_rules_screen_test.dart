import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexo/database/database_platform.dart';
import 'package:nexo/database/db_helper.dart';
import 'package:nexo/models/models.dart';
import 'package:nexo/providers/app_provider.dart';
import 'package:nexo/screens/import_rules_screen.dart';
import 'package:nexo/services/import_rules_service.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late AppProvider app;

  setUpAll(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('home_widget'), (call) async => true);
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    root = await Directory.systemTemp.createTemp('nexo-rules-');
    await DBHelper.close();
    await DatabasePlatform.initialize(testDirectory: p.join(root.path, 'db'));
    app = AppProvider()..settings.budgetAlertsEnabled = false;
    app.categories = await DBHelper.getCategories();
    for (final (id, name, type) in [
      ('bank', 'Conta principal', 'bank'),
      ('broker', 'Corretora Exemplo', 'bank'),
      ('card', 'Cartão Exemplo', 'credit'),
    ]) {
      await app.addAccount(Account(
          id: id,
          name: name,
          type: type,
          balance: 0,
          currency: 'BRL',
          colorValue: 0));
    }
  });

  tearDown(() async {
    debugDefaultTargetPlatformOverride = null;
    await DBHelper.close();
    try {
      await root.delete(recursive: true);
    } catch (_) {}
  });

  testWidgets(
      'a transfer rule that registers by itself: made, shown and kept when edited',
      (tester) async {
    tester.view.physicalSize = const Size(412, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    // SQLite FFI work runs outside the fake clock.
    Future<void> settle([String? until]) async {
      for (var i = 0; i < (until == null ? 8 : 200); i++) {
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 30)));
        await tester.pump();
        if (until != null &&
            i >= 3 &&
            find.textContaining(until).evaluate().isNotEmpty) {
          break;
        }
      }
    }

    Future<List<ImportRule>> saved() async =>
        (await tester.runAsync(ImportRulesService.load))!;

    await tester.pumpWidget(ChangeNotifierProvider.value(
        value: app, child: const MaterialApp(home: ImportRulesScreen())));
    await settle('Crie sua primeira regra');

    await tester.tap(find.byTooltip('Nova regra'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'Descrição contém'),
        'Corretora Exemplo');
    await tester.tap(find.text('Despesa'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Transferência entre contas suas').last);
    await tester.pumpAndSettle();
    expect(find.text('Categoria'), findsNothing,
        reason: 'a transfer has no category');

    // Without the other account it says what is missing and saves nothing.
    await tester.tap(find.text('Salvar'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Escolha a outra conta'), findsOneWidget);
    expect(await saved(), isEmpty);

    await tester.tap(find.text('A outra conta'));
    await tester.pumpAndSettle();
    expect(find.text('Cartão Exemplo'), findsNothing,
        reason: 'paying a card is not a transfer rule');
    await tester.tap(find.text('Corretora Exemplo').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Lançar sozinho'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Salvar'));
    await settle('lança sozinho');
    await tester.pumpAndSettle();

    var rule = (await saved()).single;
    expect([rule.type, rule.auto, rule.targetAccountId, rule.categoryId],
        ['transfer', true, 'broker', '']);
    expect(find.text('Transferência com Corretora Exemplo • lança sozinho'),
        findsOneWidget);

    // Opening and saving again changes nothing.
    await tester.tap(find.widgetWithText(ListTile, 'Corretora Exemplo'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Salvar'));
    await settle('lança sozinho');
    await tester.pumpAndSettle();
    rule = (await saved()).single;
    expect([rule.type, rule.auto, rule.targetAccountId],
        ['transfer', true, 'broker']);
    expect(tester.takeException(), isNull);
    debugDefaultTargetPlatformOverride = null;
  });
}
