import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:nexo/database/database_platform.dart';
import 'package:nexo/database/db_helper.dart';
import 'package:nexo/models/models.dart';
import 'package:nexo/screens/investments_screen.dart';
import 'package:nexo/services/desktop_profile.dart';
import 'package:nexo/widgets/shared_widgets.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Regressions found by the November 2026 audit (AUDITORIA_NEXO.md).
/// Fictitious data only.
void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await initializeDateFormatting('pt_BR');
  });

  test('a development build of the Windows app never opens the real data', () {
    // PLAT-04: a debug build with a newer schema would upgrade the person's
    // database and the installed version could no longer open it.
    bool dev(
            {required bool release,
            bool test = false,
            List<String> a = const []}) =>
        DesktopProfile.developmentProfile(
            release: release, test: test, arguments: a);
    expect(dev(release: false), isTrue);
    expect(dev(release: true), isFalse, reason: 'the installed app');
    expect(dev(release: false, test: true), isFalse,
        reason: 'already a profile');
    expect(dev(release: false, a: ['--real-data']), isFalse,
        reason: 'asked for');
  });

  group('the database file', () {
    late Directory dir;
    setUp(() async {
      await DBHelper.close();
      dir = await Directory.systemTemp.createTemp('nexo-audit-db-');
      await DatabasePlatform.initialize(testDirectory: dir.path);
    });
    tearDown(() async {
      await DBHelper.close();
      try {
        await dir.delete(recursive: true);
      } catch (_) {}
    });

    Future<int> versionOf(String path) async {
      final db = await databaseFactory.openDatabase(path,
          options: OpenDatabaseOptions(singleInstance: false));
      try {
        return (await db.rawQuery('PRAGMA user_version')).single.values.first
            as int;
      } finally {
        await db.close();
      }
    }

    test('is copied before a schema upgrade touches it (PLAT-06)', () async {
      final db = await DBHelper.database;
      final current = await versionOf(db.path);
      await DBHelper.insertAccount(Account(
          id: 'main',
          name: 'Conta fictícia',
          type: 'bank',
          currency: 'BRL',
          balance: 10,
          colorValue: 0));
      final copies = Directory(p.join(dir.path, DBHelper.upgradeCopies));
      expect(await copies.exists(), isFalse, reason: 'a new file needs none');
      await db.execute('PRAGMA user_version = ${current - 1}');
      await DBHelper.close();

      await DBHelper.database; // the upgrade
      final files = [await for (final f in copies.list()) f as File];
      expect(files, hasLength(1));
      expect(p.basename(files.single.path),
          startsWith('antes-do-schema-$current-de-${current - 1}-'));
      expect(await versionOf(files.single.path), current - 1,
          reason: 'the copy is the file as it was');
      expect((await DBHelper.getAccounts()).single.name, 'Conta fictícia');

      // Opening again upgrades nothing and copies nothing.
      await DBHelper.close();
      await DBHelper.database;
      expect(await copies.list().length, 1);
    });

    test('written by a newer Nexo is refused and left as it is', () async {
      final db = await DBHelper.database;
      final path = db.path;
      final current = await versionOf(path);
      await db.execute('PRAGMA user_version = ${current + 1}');
      await DBHelper.close();
      await expectLater(
          DBHelper.database, throwsA(isA<NewerDatabaseException>()));
      await DBHelper.close();
      expect(await versionOf(path), current + 1);
    });
  });

  testWidgets('the account picker shows a "Banco" account (UX-01)',
      (tester) async {
    // "Banco" is the default type of an account. The picker left it out,
    // so the main account was missing from transfers, loans and debts.
    String? picked;
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: AccountCardPicker(accounts: [
      Account(
          id: 'main',
          name: 'Conta fictícia',
          type: 'bank',
          currency: 'BRL',
          balance: 10,
          colorValue: 0xFF336699),
      Account(
          id: 'cash',
          name: 'Carteira fictícia',
          type: 'cash',
          currency: 'BRL',
          balance: 5,
          colorValue: 0xFF996633),
    ], selectedId: null, onSelected: (id) => picked = id))));
    expect(find.text('Conta fictícia'), findsOneWidget);
    expect(find.text('Carteira fictícia'), findsOneWidget);
    await tester.tap(find.text('Conta fictícia'));
    expect(picked, 'main');
  });

  test('a quote round tells every asset that failed, not only the first', () {
    // One asset without a quote used to stop the round (INV-04).
    expect(quoteProblems(const []), isNull);
    expect(quoteProblems(const ['AAAA3: sem cotação.']), 'AAAA3: sem cotação.');
    expect(
        quoteProblems(const ['AAAA3: sem cotação.', 'BBBB4: x', 'CCCC11: y']),
        'AAAA3: sem cotação. E mais 2 sem cotação.');
  });
}
