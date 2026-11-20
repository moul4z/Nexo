// Screen fixes from the audit's UX list: search by amount (UX-06), a form
// with something typed asks before closing (UX-11), hidden values on every
// screen (UX-05), a save that runs once (UX-04). Fictitious data.
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:nexo/database/db_helper.dart';
import 'package:nexo/l10n/app_localizations.dart';
import 'package:nexo/models/models.dart';
import 'package:nexo/providers/app_provider.dart';
import 'package:nexo/screens/add_transaction_screen.dart';
import 'package:nexo/screens/assets_screen.dart';
import 'package:nexo/services/transaction_filter.dart';
import 'package:nexo/theme/app_theme.dart';
import 'package:nexo/utils/snackbar.dart';
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

  testWidgets('"Ocultar saldo" hides the amounts in Bens too (UX-05)',
      (tester) async {
    final app = AppProvider()
      ..assets = [
        AssetItem(
            id: 'c', name: 'Carro fictício', value: 1234.5, currency: 'BRL'),
        AssetItem(
            id: 'd', name: 'Reserva fictícia', value: 10, currency: 'USD'),
      ];
    app.settings.hideBalance = true;
    await tester.pumpWidget(ChangeNotifierProvider.value(
        value: app,
        child: MaterialApp(
            locale: const Locale('pt'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: const AssetsScreen())));
    await tester.pump();
    expect(find.text('Carro fictício'), findsOneWidget);
    expect(find.textContaining('1.234'), findsNothing);
    expect(find.textContaining('US\$'), findsNothing);
    expect(find.textContaining('≈'), findsNothing,
        reason: 'the converted value would give the amount away');
    expect(find.text(hiddenAmount), findsNWidgets(3));

    app.settings.hideBalance = false;
    app.notifyListeners();
    await tester.pump();
    expect(find.textContaining('1.234,50'), findsWidgets);
  });

  testWidgets('a save runs once and a refused one says why (UX-04)',
      (tester) async {
    late State state;
    await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: StatefulBuilder(builder: (context, _) {
      state = context.findAncestorStateOfType<State>()!;
      return const SizedBox();
    }))));
    var busy = false;
    var runs = 0;
    final gate = Completer<void>();
    final first = saveOnce(state, () => busy, (v) => busy = v, () async {
      runs++;
      await gate.future;
    });
    final second = saveOnce(state, () => busy, (v) => busy = v, () async {
      runs++;
    });
    expect(await second, isFalse, reason: 'a second tap does nothing');
    gate.complete();
    expect(await first, isTrue);
    expect(runs, 1);
    expect(busy, isFalse);

    final refused = saveOnce(state, () => busy, (v) => busy = v,
        () async => throw StateError('Essa conta foi apagada.'));
    expect(await refused, isFalse);
    await tester.pump();
    expect(find.text('Essa conta foi apagada.'), findsOneWidget);
    expect(busy, isFalse);
  });
}
