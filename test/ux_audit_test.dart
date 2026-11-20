// Screen fixes from the audit's UX list: search by amount (UX-06), a form
// with something typed asks before closing (UX-11). Fictitious data.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:nexo/database/db_helper.dart';
import 'package:nexo/l10n/app_localizations.dart';
import 'package:nexo/models/models.dart';
import 'package:nexo/providers/app_provider.dart';
import 'package:nexo/screens/add_transaction_screen.dart';
import 'package:nexo/services/transaction_filter.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a search that is an amount finds that amount (UX-06)', () {
    expect(TransactionFilter.searchedCents('55,90'), 5590);
    expect(TransactionFilter.searchedCents('R\$ 55,9'), 5590);
    expect(TransactionFilter.searchedCents('1.200,00'), 120000);
    expect(TransactionFilter.searchedCents('1.200'), 120000);
    expect(TransactionFilter.searchedCents('12.5'), 1250);
    expect(TransactionFilter.searchedCents('300'), 30000);
    expect(TransactionFilter.searchedCents('mercado'), isNull);
    expect(TransactionFilter.searchedCents('20/11/2026'), isNull);
    final f = TransactionFilter()
      ..categoryId = 'food_exp'
      ..minimum = 10;
    expect(f.count, 2, reason: 'the button shows two active filters (UX-07)');
  });

  testWidgets('closing a form with something typed asks first (UX-11)',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.runAsync(() async {
      await initializeDateFormatting('pt_BR');
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
      await databaseFactory.setDatabasesPath(
          (await Directory.systemTemp.createTemp('nexo-ux-')).path);
      await DBHelper.database;
    });
    final app = AppProvider()
      ..accounts = [
        Account(
            id: 'a',
            name: 'Banco fictício',
            type: 'bank',
            balance: 100,
            currency: 'BRL',
            colorValue: 0)
      ]
      ..categories = [
        AppCategory(id: 'food', name: 'Comida', type: 'expense', colorValue: 0)
      ];
    await tester.pumpWidget(ChangeNotifierProvider.value(
        value: app,
        child: MaterialApp(
            locale: const Locale('pt'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Builder(
                builder: (context) => TextButton(
                    onPressed: () => Navigator.push(
                        context,
                        MaterialPageRoute(
                            builder: (_) => const AddTransactionScreen())),
                    child: const Text('abrir'))))));
    await tester.tap(find.text('abrir'));
    await tester.pumpAndSettle();

    // Nothing typed: back closes at once.
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(AddTransactionScreen), findsNothing);

    await tester.tap(find.text('abrir'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, '42,50');
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('Descartar o que foi digitado?'), findsOneWidget);
    await tester.tap(find.text('Continuar editando'));
    await tester.pumpAndSettle();
    expect(find.byType(AddTransactionScreen), findsOneWidget);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    await tester.tap(find.text('Descartar'));
    await tester.pumpAndSettle();
    expect(find.byType(AddTransactionScreen), findsNothing);
  });
}
