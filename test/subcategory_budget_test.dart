// Budget of a subcategory: counts only its entries, is part of the
// category's own budget and is never added twice to the totals. Delivery or
// Mercado from the merchant's text. Fictitious names and amounts.
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexo/database/database_platform.dart';
import 'package:nexo/database/db_helper.dart';
import 'package:nexo/models/models.dart';
import 'package:nexo/models/transaction_metadata.dart';
import 'package:nexo/providers/app_provider.dart';
import 'package:nexo/services/subcategories.dart';
import 'package:nexo/sync/assistant_parity_commands.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late AppProvider app;
  final now = DateTime.now();

  setUpAll(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('home_widget'), (call) async => true);
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    root = await Directory.systemTemp.createTemp('nexo-sub-budget-');
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
    Future<void> spend(String id, double amount, String sub) =>
        app.addTransaction(
            AppTransaction(
                id: id,
                type: 'expense',
                amount: amount,
                description: id,
                accountId: 'bank',
                categoryId: 'food_exp',
                date: DateTime(now.year, now.month, 1, 12)),
            metadata: TransactionMetadata(transactionId: id, subcategory: sub));
    await spend('ifood', 60, 'Delivery');
    await spend('ifood2', 40, 'Delivery');
    await spend('feira', 150, 'Mercado');
  });

  tearDown(() async {
    await DBHelper.close();
    try {
      await root.delete(recursive: true);
    } catch (_) {}
  });

  test('the subcategory budget counts only its entries, inside the category',
      () async {
    final start = DateTime(now.year, now.month);
    await app.addBudget(Budget(
        id: 'food',
        categoryId: 'food_exp',
        amount: 800,
        period: 'monthly',
        createdAt: start));
    await app.addBudget(Budget(
        id: 'delivery',
        categoryId: 'food_exp',
        amount: 120,
        period: 'monthly',
        createdAt: start,
        subcategory: 'Delivery'));
    final food = app.budgets.firstWhere((b) => b.id == 'food');
    final delivery = app.budgets.firstWhere((b) => b.id == 'delivery');
    expect(delivery.subcategory, 'Delivery', reason: 'saved and read back');
    expect(app.budgetSpent(food), 250);
    expect(app.budgetSpent(delivery), 100);
    expect(app.budgetForCategory('food_exp')!.id, 'food');
    expect(app.budgetName(delivery), endsWith(' › Delivery'));
    expect(app.budgetRuleOf(delivery), isNull);
  });

  test('the assistant creates one per category and subcategory', () async {
    final commands = AssistantParityCommands(app);
    Future<void> save(Map<String, dynamic> a, String id) =>
        commands.handle(id, 'budget.save', a);
    await save({'category_id': 'food_exp', 'amount_cents': 80000}, 'c1');
    await save({
      'category_id': 'food_exp',
      'amount_cents': 12000,
      'subcategory': 'Delivery'
    }, 'c2');
    await save({
      'category_id': 'food_exp',
      'amount_cents': 15000,
      'subcategory': 'Delivery'
    }, 'c3');
    final mine = app.budgets.where((b) => b.categoryId == 'food_exp').toList();
    expect(mine.map((b) => (b.subcategory, b.amount)).toSet(),
        {('', 800.0), ('Delivery', 150.0)});
  });

  test('Delivery or Mercado from the text, and only when it is clear', () {
    expect(foodSubcategory('IFOOD *RESTAURANTE EXEMPLO'), 'Delivery');
    expect(foodSubcategory('Rappi Brasil'), 'Delivery');
    expect(foodSubcategory('SUPERMERCADO EXEMPLO LTDA'), 'Mercado');
    expect(foodSubcategory('Atacadão Exemplo'), 'Mercado');
    expect(foodSubcategory('MERCADO PAGO*LOJA'), isNull);
    expect(foodSubcategory('Mercado Livre'), isNull);
    expect(foodSubcategory('Padaria Exemplo'), isNull);
  });
  test('"Classificar antigos" offers only food without a subcategory', () {
    AppTransaction t(String id, String text, {String cat = 'food_exp'}) =>
        AppTransaction(
            id: id,
            type: 'expense',
            amount: 10,
            description: text,
            accountId: 'bank',
            categoryId: cat,
            date: now);
    final todo = unclassifiedFood([
      t('a', 'IFOOD *EXEMPLO'),
      t('b', 'Supermercado Exemplo'),
      t('c', 'IFOOD *JA TEM'),
      t('d', 'Padaria Exemplo'),
      t('e', 'Supermercado Exemplo', cat: 'shopping'),
    ], {
      'c': const TransactionMetadata(transactionId: 'c', subcategory: 'Lanche')
    });
    expect([for (final (x, sub) in todo) (x.id, sub)],
        [('a', 'Delivery'), ('b', 'Mercado')]);
  });
}
