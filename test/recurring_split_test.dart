// A subscription split with people (6.4 b): each payment keeps this
// person's part as spending and turns the others' parts into "a receber",
// in the same write. Fictitious names and amounts.
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexo/database/database_platform.dart';
import 'package:nexo/database/db_helper.dart';
import 'package:nexo/models/models.dart';
import 'package:nexo/providers/app_provider.dart';
import 'package:nexo/services/finance_rules.dart';
import 'package:nexo/sync/assistant_parity_commands.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late AppProvider app;
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  const people = ['Pessoa A', 'Pessoa B', 'Pessoa C', 'Pessoa D', 'Pessoa E'];

  setUpAll(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('home_widget'), (call) async => true);
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    // The reminders of a recurring are a phone feature.
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    root = await Directory.systemTemp.createTemp('nexo-rec-split-');
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
  });

  tearDown(() async {
    debugDefaultTargetPlatformOverride = null;
    await DBHelper.close();
    try {
      await root.delete(recursive: true);
    } catch (_) {}
  });

  RecurringPayment streaming({String type = 'subscription'}) =>
      RecurringPayment(
          id: 'streaming',
          name: 'Streaming fictício',
          accountId: 'bank',
          categoryId: 'entertainment',
          amount: 55.90,
          freqVal: 1,
          freqUnit: 'months',
          startDate: today,
          nextDate: today,
          endDate: type == 'installment'
              ? DateTime(today.year, today.month + 5, today.day)
              : null,
          recurringType: type,
          splitWith: people);

  test('split in 6: 9,31 from each of 5 people, 9,35 stays as spending',
      () async {
    final r = streaming();
    expect(r.splitParts(), (931, 935));
    await app.addRecurring(r);
    expect(app.recurring.single.splitWith, people, reason: 'saved and read');
    await app.markRecurringPaid(app.recurring.single);

    expect(app.accountById('bank')!.balance, closeTo(944.10, 1e-9),
        reason: 'the whole bill left the account');
    final occurrence = app.transactions
        .firstWhere((t) => t.id.startsWith('recurring:streaming:'));
    expect(occurrence.amount, closeTo(9.35, 1e-9));
    final shared =
        app.transactions.firstWhere((t) => t.id == '${occurrence.id}:shared');
    expect(shared.amount, closeTo(46.55, 1e-9));
    expect(FinanceRules.isNeutral(shared, app.transactionMetadata[shared.id]),
        isTrue,
        reason: 'the others\' parts are not this person\'s spending');
    expect(app.lended.map((l) => l.amount).toList(),
        List.filled(5, closeTo(9.31, 1e-9)));
    expect(app.lendedPeople.map((p) => p.name).toSet(), people.toSet());

    // Next month: the same people, no second copy of anyone.
    await app.markRecurringPaid(app.recurring.single);
    expect(app.lended, hasLength(10));
    expect(app.lendedPeople, hasLength(5));
    expect(app.accountById('bank')!.balance, closeTo(888.20, 1e-9));
  });

  test('an installment is never split', () async {
    await app.addRecurring(streaming(type: 'installment'));
    await app.markRecurringPaid(app.recurring.single);
    expect(app.lended, isEmpty);
    expect(app.transactions.single.amount, closeTo(55.90, 1e-9));
  });

  test('the assistant sets and removes the split', () async {
    await app.addRecurring(streaming()..splitWith = []);
    final commands = AssistantParityCommands(app);
    await commands.handle('c1', 'recurring.edit', {
      'id': 'streaming',
      'split_with': [' Pessoa A ', 'Pessoa B', 'Pessoa A']
    });
    expect(app.recurring.single.splitWith, ['Pessoa A', 'Pessoa B']);
    await commands.handle(
        'c2', 'recurring.edit', {'id': 'streaming', 'split_with': <String>[]});
    expect(app.recurring.single.splitWith, isEmpty);
  });
}
