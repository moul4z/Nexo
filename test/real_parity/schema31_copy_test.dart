// Schema 31 on a COPY of the person's database: every investment operation
// and every other ledger row comes out as it went in, the sync triggers come
// back and nothing is journaled. Only counts are printed, never values.
//
//   mkdir -p build/real_parity/copy
//   cp "%LOCALAPPDATA%/Nexo/nexo.db" build/real_parity/copy/nexo.db
//   flutter test test/real_parity/schema31_copy_test.dart
//   rm -rf build/real_parity
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexo/database/database_platform.dart';
import 'package:nexo/database/db_helper.dart';
import 'package:nexo/investments/investment_repository.dart';
import 'package:nexo/sync/ledger_capture.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final copy = File('build/real_parity/copy/nexo.db');
  test('schema 31 on a copy of the real database', skip: !copy.existsSync(),
      () async {
    sqfliteFfiInit();
    Future<Map<String, List<Map<String, Object?>>>> snapshot(
        Database db) async {
      final out = <String, List<Map<String, Object?>>>{};
      for (final e in ledgerTables.entries) {
        final rows = await db.query(e.key, orderBy: e.value);
        // Columns a newer schema adds are not part of the comparison.
        out[e.key] = [for (final r in rows) Map.of(r)];
      }
      return out;
    }

    Future<Set<String>> triggers(Database db) async => {
          for (final r in await db.rawQuery(
              "SELECT name FROM sqlite_master WHERE type = 'trigger'"))
            r['name'] as String
        };
    Future<int> count(Database db, String table) async =>
        (await db.rawQuery('SELECT COUNT(*) AS n FROM $table')).single['n']
            as int;

    final raw = await databaseFactoryFfi.openDatabase(copy.absolute.path,
        options: OpenDatabaseOptions(singleInstance: false));
    final oldVersion = await raw.getVersion();
    final before = await snapshot(raw);
    final triggersBefore = await triggers(raw);
    final synced = await LedgerCapture.isInstalled(raw);
    final logBefore = synced ? await count(raw, 'sync_capture_log') : 0;
    await raw.close();

    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    await DatabasePlatform.initialize(testDirectory: copy.parent.absolute.path);
    final db = await DBHelper.database;
    try {
      expect(await db.getVersion(), 31);
      final table = await db.rawQuery(
          "SELECT sql FROM sqlite_master WHERE name = 'investment_operations'");
      expect(table.single['sql'] as String,
          contains(InvestmentRepository.eventsCheck));
      final after = await snapshot(db);
      var rows = 0;
      for (final t in before.keys) {
        expect(after[t]!.length, before[t]!.length, reason: '$t: row count');
        for (var i = 0; i < before[t]!.length; i++) {
          final old = before[t]![i], now = after[t]![i];
          for (final column in old.keys) {
            expect(now[column], old[column], reason: '$t: a value changed');
          }
        }
        rows += before[t]!.length;
      }
      expect(await triggers(db), containsAll(triggersBefore));
      if (synced) {
        expect(await count(db, 'sync_capture_log'), logBefore,
            reason: 'the upgrade journals nothing');
      }
      expect((await db.rawQuery('PRAGMA integrity_check')).single.values.first,
          'ok');
      final positions = await InvestmentRepository().load();
      // ignore: avoid_print
      print('schema $oldVersion → 31: $rows linhas conferidas, '
          '${before['investment_operations']!.length} operações de '
          'investimento, ${positions.length} ativos, '
          '${triggersBefore.length} gatilhos, sync ${synced ? 'ligado' : 'desligado'}');
    } finally {
      await DBHelper.close();
      debugDefaultTargetPlatformOverride = null;
    }
  });
}
