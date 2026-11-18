// Writes a database with fictitious data only, for the test app on a phone
// (`com.ma.expensy.teste`) and for screenshots. Nobody's real data.
//
//   $env:NEXO_DEMO_OUT='C:\temp\demo'; flutter test tool/demo_db_test.dart
//
// The file lands at <NEXO_DEMO_OUT>/nexo.db with the schema of this version.
// Amounts imitate the shape of a student's month (small income, Pix, food
// delivery, a card that closes on the 19th) with invented values.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexo/database/database_platform.dart';
import 'package:nexo/database/db_helper.dart';
import 'package:nexo/models/models.dart';
import 'package:nexo/models/transaction_metadata.dart';

import 'demo_data.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('fictitious database for the test app', () async {
    final out = Platform.environment['NEXO_DEMO_OUT'];
    if (out == null || out.isEmpty) {
      markTestSkipped('NEXO_DEMO_OUT not set');
      return;
    }
    // This test deletes the database of the folder it is given: never the
    // folder where the Nexo keeps a person's data.
    final local = Platform.environment['LOCALAPPDATA'];
    final target = Directory(out).absolute.path.toLowerCase();
    if (local != null &&
        local.isNotEmpty &&
        target.startsWith(
            '${Directory(local).absolute.path.toLowerCase()}${Platform.pathSeparator}nexo')) {
      fail('NEXO_DEMO_OUT aponta para a pasta de dados do Nexo. Use outra.');
    }
    final dir = Directory(out)..createSync(recursive: true);
    for (final f in dir.listSync().whereType<File>()) {
      if (f.path.contains('nexo.db')) f.deleteSync();
    }
    await DatabasePlatform.initialize(testDirectory: dir.path);
    final db = await DBHelper.database;
    await seedDemoInvestments();
    final now = DateTime.now();
    DateTime ago(int days, [int hour = 12]) =>
        DateTime(now.year, now.month, now.day - days, hour);

    await db.delete('accounts');
    await db.delete('categories');
    final accounts = [
      Account(
          id: 'main',
          name: 'Conta principal',
          type: 'bank',
          balance: 0,
          currency: 'BRL',
          colorValue: 0xff00695c),
      Account(
          id: 'card',
          name: 'Cartão roxo',
          type: 'credit',
          balance: 0,
          currency: 'BRL',
          colorValue: 0xff6a1b9a,
          statementDay: 19,
          dueDay: 26,
          creditLimit: 900,
          linkedAccountId: 'main'),
      Account(
          id: 'reserve',
          name: 'Reserva',
          type: 'savings',
          balance: 0,
          currency: 'BRL',
          colorValue: 0xff1565c0),
    ];
    final categories = [
      AppCategory(
          id: 'food',
          name: 'Alimentação',
          type: 'expense',
          colorValue: 0xff2e7d32),
      AppCategory(
          id: 'transport',
          name: 'Transporte',
          type: 'expense',
          colorValue: 0xffef6c00),
      AppCategory(
          id: 'bets', name: 'Apostas', type: 'expense', colorValue: 0xffad1457),
      AppCategory(
          id: 'subs',
          name: 'Assinaturas',
          type: 'expense',
          colorValue: 0xff00838f),
      AppCategory(
          id: 'study',
          name: 'Estudos',
          type: 'expense',
          colorValue: 0xff5e35b1),
      AppCategory(
          id: 'salary', name: 'Bolsa', type: 'income', colorValue: 0xff2e7d32),
      AppCategory(
          id: 'wins',
          name: 'Ganhos de apostas',
          type: 'income',
          colorValue: 0xff43a047),
      AppCategory(
          id: 'yield',
          name: 'Rendimentos',
          type: 'income',
          colorValue: 0xff00897b),
    ];
    for (final a in accounts) {
      await db.insert('accounts', a.toMap());
    }
    for (final c in categories) {
      await db.insert('categories', c.toMap());
    }

    final balance = <String, double>{};
    var n = 0;
    Future<void> tx(String desc, double amount, String category, int daysAgo,
        {String account = 'main', String type = 'expense', String? sub}) async {
      final t = AppTransaction(
          id: 'demo-${n++}',
          type: type,
          amount: amount,
          description: desc,
          accountId: account,
          categoryId: category,
          currency: 'BRL',
          date: ago(daysAgo));
      await db.insert('transactions', t.toMap());
      await db.insert(
          'transaction_metadata',
          TransactionMetadata(
                  transactionId: t.id,
                  source: desc == 'Bolsa' ? 'recurring' : 'manual',
                  subcategory: sub ?? '')
              .toMap());
      balance[account] =
          (balance[account] ?? 0) + (type == 'income' ? amount : -amount);
    }

    // Opening balances as neutral adjustments.
    for (final (id, value) in [('main', 640.0), ('reserve', 900.0)]) {
      final t = AppTransaction(
          id: 'demo-open-$id',
          type: 'income',
          amount: value,
          description: 'Saldo inicial',
          accountId: id,
          categoryId: 'salary',
          currency: 'BRL',
          date: ago(45));
      await db.insert('transactions', t.toMap());
      await db.insert(
          'transaction_metadata',
          TransactionMetadata(
                  transactionId: t.id,
                  source: 'opening_balance',
                  excludeFromSpending: true)
              .toMap());
      balance[id] = (balance[id] ?? 0) + value;
    }
    await tx('Bolsa', 1200, 'salary', 11, type: 'income');
    await tx('Bolsa', 1200, 'salary', 41, type: 'income');
    for (final (d, v) in [
      (1, 31.9),
      (2, 24.5),
      (4, 38.0),
      (6, 27.4),
      (9, 33.1)
    ]) {
      await tx('iFood', v, 'food', d, sub: 'Delivery');
    }
    for (final (d, v) in [(3, 64.2), (10, 88.7), (17, 71.3)]) {
      await tx('Mercado do bairro', v, 'food', d, sub: 'Mercado');
    }
    await tx('Ônibus', 4.4, 'transport', 2);
    await tx('Ônibus', 4.4, 'transport', 5);
    await tx('Aposta esportiva', 20, 'bets', 3);
    await tx('Aposta esportiva', 10, 'bets', 6);
    await tx('Ganho de aposta', 35, 'wins', 5, type: 'income');
    await tx('Assinatura de IA', 104.0, 'subs', 4, account: 'card');
    await tx('Streaming de música', 21.9, 'subs', 14, account: 'card');
    await tx('Livro da faculdade', 59.9, 'study', 8, account: 'card');
    await tx('Lanche', 18.5, 'food', 1, account: 'card');
    await tx('Rendimentos', 0.31, 'yield', 2, type: 'income');
    for (final e in balance.entries) {
      await db.update('accounts', {'balance': e.value},
          where: 'id = ?', whereArgs: [e.key]);
    }

    for (final r in [
      RecurringPayment(
          id: 'bolsa',
          name: 'Bolsa',
          accountId: 'main',
          categoryId: 'salary',
          amount: 1200,
          paymentType: 'income',
          freqVal: 1,
          freqUnit: 'months',
          startDate: DateTime(now.year, now.month - 3, 7),
          nextDate: DateTime(now.year, now.month + 1, 7)),
      RecurringPayment(
          id: 'ia',
          name: 'Assinatura de IA',
          accountId: 'card',
          categoryId: 'subs',
          amount: 104,
          freqVal: 1,
          freqUnit: 'months',
          startDate: DateTime(now.year, now.month - 2, 14),
          nextDate: DateTime(now.year, now.month + 1, 14)),
      RecurringPayment(
          id: 'musica',
          name: 'Streaming de música',
          accountId: 'card',
          categoryId: 'subs',
          amount: 21.9,
          freqVal: 1,
          freqUnit: 'months',
          startDate: DateTime(now.year, now.month - 4, 4),
          nextDate: DateTime(now.year, now.month + 1, 4)),
      RecurringPayment(
          id: 'net',
          name: 'Internet',
          accountId: 'main',
          categoryId: 'subs',
          amount: 59.9,
          freqVal: 1,
          freqUnit: 'months',
          startDate: DateTime(now.year, now.month - 4, 25),
          nextDate: DateTime(now.year, now.month, 25)),
    ]) {
      await db.insert('recurring_payments', r.toMap());
    }
    for (final b in [
      Budget(
          id: 'b-food',
          categoryId: 'food',
          amount: 70,
          period: 'weekly',
          createdAt: DateTime(now.year, now.month - 2, 1)),
      Budget(
          id: 'b-bets',
          categoryId: 'bets',
          amount: 30,
          period: 'monthly',
          createdAt: DateTime(now.year, now.month - 2, 1)),
    ]) {
      await db.insert('budgets', b.toMap());
    }
    await db.close();
    expect(File('${dir.path}${Platform.pathSeparator}nexo.db').existsSync(),
        isTrue);
  });
}
