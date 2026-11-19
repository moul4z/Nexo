// The daily copy of the database and "Testar um backup": both only read
// the person's data. Temporary databases and fictitious values only.
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexo/database/database_platform.dart';
import 'package:nexo/database/db_helper.dart';
import 'package:nexo/models/models.dart';
import 'package:nexo/services/auto_backup.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;

  setUpAll(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('home_widget'), (call) async => true);
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    root = await Directory.systemTemp.createTemp('nexo-auto-backup-');
    await DBHelper.close();
    await DatabasePlatform.initialize(testDirectory: p.join(root.path, 'db'));
    await DBHelper.insertAccount(Account(
        id: 'bank',
        name: 'Banco fictício',
        type: 'bank',
        balance: 120,
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

  test('one checked copy a day, beside the database; never a second one early',
      () async {
    final t = DateTime(2026, 11, 20, 8, 30);
    final copy = await AutoBackup.run(now: t);
    expect(copy, isNotNull);
    expect(p.basename(copy!.path), 'auto-20261120-0830.db');
    expect(p.dirname(copy.path), (await AutoBackup.directory()).path);
    expect(
        await AutoBackup.check(copy.path,
            expected: [await AutoBackup.counts(await DBHelper.database)]),
        isNull);
    expect(await AutoBackup.run(now: t.add(const Duration(hours: 5))), isNull);
    expect(
        await AutoBackup.run(now: t.add(const Duration(hours: 21))), isNotNull);
    expect(await AutoBackup.copies(), hasLength(2));
  });

  test('seven daily copies and, before them, the newest of four weeks',
      () async {
    // 02/11/2026 is a Monday.
    for (var day = 0; day <= 14; day++) {
      await AutoBackup.run(now: DateTime(2026, 11, 2 + day, 9), force: true);
    }
    final kept = [
      for (final f in await AutoBackup.copies()) AutoBackup.dateOf(f)!.day
    ];
    expect(kept, [16, 15, 14, 13, 12, 11, 10, 9, 8],
        reason:
            '7 daily; then the 9th (week of 09/11) and the 8th (week of 02/11)');
  });

  test(
      'a broken copy is never kept, and what an interrupted one left is removed',
      () async {
    final dir = await AutoBackup.directory();
    await dir.create(recursive: true);
    final leftover = File(p.join(dir.path, 'auto-20261119-0900.db.tmp'))
      ..writeAsStringSync('interrompida');
    final broken = File(p.join(root.path, 'quebrada.db'))
      ..writeAsBytesSync(List.filled(4096, 7));
    expect(await AutoBackup.check(broken.path), isNotNull);
    await AutoBackup.run(now: DateTime(2026, 11, 20, 9));
    expect(leftover.existsSync(), isFalse);
    expect(await AutoBackup.copies(), hasLength(1));
    // A copy with other counts than the database is refused.
    final copy = (await AutoBackup.copies()).single;
    expect(
        await AutoBackup.check(copy.path, expected: [
          {'transactions': 9, 'accounts': 1, 'investment_operations': 0}
        ]),
        isNotNull);
  });

  test(
      '"Testar um backup": restored into a database apart, nothing changes here',
      () async {
    final data = await DBHelper.exportAll();
    final counts = await DBHelper.rehearseImport(data);
    expect(counts['accounts'], 1);
    expect(counts['categories'], (data['categories'] as List).length);
    expect((await DBHelper.getAccounts()).single.balance, 120);
    // A file missing a table it must have is refused, legibly.
    final broken = Map<String, dynamic>.from(data)..remove('accounts');
    await expectLater(
        DBHelper.rehearseImport(broken), throwsA(isA<FormatException>()));
    expect(await DBHelper.getAccounts(), hasLength(1));
    expect(data.containsKey('accounts'), isTrue,
        reason: 'the file read is not changed by the test');
  });
}
