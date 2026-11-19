// A subscription paid abroad: the forecast counts the IOF the bank charges
// on each occurrence; the rate is the person's, never fixed in the code.
// Fictitious names, amounts and rates.
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexo/database/database_platform.dart';
import 'package:nexo/database/db_helper.dart';
import 'package:nexo/models/models.dart';
import 'package:nexo/providers/app_provider.dart';
import 'package:nexo/services/cash_forecast.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

RecurringPayment stream({double? iof, String type = 'expense'}) =>
    RecurringPayment(
        id: 'ai',
        name: 'Serviço Exemplo AI',
        accountId: 'bank',
        categoryId: type == 'income' ? 'salary' : 'food_exp',
        amount: 39.90,
        paymentType: type,
        freqVal: 1,
        freqUnit: 'months',
        startDate: DateTime(2026, 11, 25),
        nextDate: DateTime(2026, 11, 25),
        iofPercent: iof);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('the forecast amount: with the IOF on an expense only, in cents', () {
    expect(stream().forecastAmount, 39.90);
    expect(stream(iof: 3.5).forecastAmount, 41.30);
    expect(stream(iof: 0).forecastAmount, 39.90);
    expect(stream(iof: 3.5, type: 'income').forecastAmount, 39.90);
    final round = RecurringPayment.fromMap(stream(iof: 3.5).toMap());
    expect(round.iofPercent, 3.5);
    expect(RecurringPayment.fromMap(stream().toMap()).iofPercent, isNull);
  });

  test('the cash forecast takes the IOF out of the account', () {
    final forecast = CashForecast.calculate(
        now: DateTime(2026, 11, 20),
        until: DateTime(2026, 11, 30),
        accounts: [
          Account(
              id: 'bank',
              name: 'Banco fictício',
              type: 'bank',
              balance: 1000,
              currency: 'BRL',
              colorValue: 0)
        ],
        transactions: const [],
        recurring: [stream(iof: 3.5)],
        metadata: const {},
        invoicePayments: const [],
        convert: (v, _) => v);
    final event = forecast.events.singleWhere((e) => e.kind == 'recurring');
    expect(event.amount, -41.30);
  });

  group('kept in the database', () {
    late Directory root;
    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
              const MethodChannel('home_widget'), (call) async => true);
      root = await Directory.systemTemp.createTemp('nexo-recurring-iof-');
      await DBHelper.close();
      await DatabasePlatform.initialize(testDirectory: p.join(root.path, 'db'));
    });
    tearDown(() async {
      debugDefaultTargetPlatformOverride = null;
      await DBHelper.close();
      try {
        await root.delete(recursive: true);
      } catch (_) {}
    });

    test('saved, read back, and not erased when something else changes',
        () async {
      final app = AppProvider()..settings.budgetAlertsEnabled = false;
      app.categories = await DBHelper.getCategories();
      await app.addAccount(Account(
          id: 'bank',
          name: 'Banco fictício',
          type: 'bank',
          balance: 1000,
          currency: 'BRL',
          colorValue: 0));
      await app.addRecurring(stream(iof: 3.5));
      final saved = (await DBHelper.getRecurring()).single;
      expect(saved.iofPercent, 3.5);
      saved.notes = 'cobrada em dólar';
      await app.updateRecurring(saved);
      expect((await DBHelper.getRecurring()).single.iofPercent, 3.5);
    });
  });
}
