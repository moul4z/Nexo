import 'dart:async';
import 'dart:io';

import 'package:intl/intl.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart' hide Transaction;

import '../database/database_platform.dart';
import '../database/db_helper.dart';
import 'diagnostics.dart';

/// A copy of the database made by itself about once a day, beside it in
/// `backups/`, kept only after it is checked: it opens, passes SQLite's
/// integrity check, has this app's schema and the same number of entries,
/// accounts and investment operations. Seven daily copies and four weekly
/// ones are kept. Never writes to the database itself.
abstract final class AutoBackup {
  static const prefix = 'auto-';
  static const every = Duration(hours: 20);
  static const daily = 7, weekly = 4;
  static const _counted = ['transactions', 'accounts', 'investment_operations'];
  static final _name =
      RegExp(r'^auto-(\d{4})(\d{2})(\d{2})-(\d{2})(\d{2})\.db$');
  static Future<File?>? _running;

  static Future<Directory> directory() async => Directory(
      p.join(p.dirname(await DatabasePlatform.path), DBHelper.upgradeCopies));

  /// When a kept copy was made, from its name.
  static DateTime? dateOf(File f) {
    final m = _name.firstMatch(p.basename(f.path));
    if (m == null) return null;
    final n = [for (var i = 1; i <= 5; i++) int.parse(m.group(i)!)];
    return DateTime(n[0], n[1], n[2], n[3], n[4]);
  }

  /// The kept copies, newest first.
  static Future<List<File>> copies({Directory? dir}) async {
    final d = dir ?? await directory();
    if (!await d.exists()) return [];
    return [
      await for (final f in d.list())
        if (f is File && dateOf(f) != null) f
    ]..sort((a, b) => dateOf(b)!.compareTo(dateOf(a)!));
  }

  /// On opening or returning to the app: one copy when the last is older
  /// than [every]. Silent; a failure goes to Ajuda › Diagnóstico.
  static Future<File?> runIfDue({DateTime? now}) =>
      _running ??= run(now: now).whenComplete(() => _running = null);

  static Future<File?> run({DateTime? now, bool force = false}) async {
    final clock = now ?? DateTime.now();
    try {
      final dir = await directory();
      final kept = await copies(dir: dir);
      if (!force &&
          kept.isNotEmpty &&
          clock.difference(dateOf(kept.first)!) < every) {
        return null;
      }
      await dir.create(recursive: true);
      // What an interrupted copy left behind.
      await for (final f in dir.list()) {
        if (f is File &&
            p.basename(f.path).startsWith(prefix) &&
            f.path.endsWith('.tmp')) {
          await f.delete();
        }
      }
      final name = '$prefix${DateFormat('yyyyMMdd-HHmm').format(clock)}.db';
      final tmp = File(p.join(dir.path, '$name.tmp'));
      final db = await DBHelper.database;
      // A write between the counts and the copy is fine: the copy is a
      // snapshot of one of the two moments.
      final before = await counts(db);
      await db.execute('VACUUM INTO ?', [tmp.path]);
      final after = await counts(db);
      final problem = await check(tmp.path, expected: [before, after]);
      if (problem != null) {
        await tmp.delete();
        throw StateError(problem);
      }
      final target = File(p.join(dir.path, name));
      if (await target.exists()) await target.delete();
      final done = await tmp.rename(target.path);
      await rotate(dir);
      return done;
    } catch (e) {
      Diagnostics.note('cópia automática', e);
      return null;
    }
  }

  static Future<Map<String, int>> counts(DatabaseExecutor db) async => {
        for (final t in _counted)
          t: Sqflite.firstIntValue(
                  await db.rawQuery('SELECT COUNT(*) FROM $t')) ??
              0
      };

  /// Why the copy at [path] is not good, or null when it is.
  static Future<String?> check(String path,
      {List<Map<String, int>> expected = const []}) async {
    Database? copy;
    try {
      copy = await openDatabase(path, readOnly: true, singleInstance: false);
      final integrity =
          (await copy.rawQuery('PRAGMA integrity_check')).first.values.first;
      if (integrity != 'ok') {
        return 'A cópia não passou na verificação de integridade.';
      }
      final version =
          Sqflite.firstIntValue(await copy.rawQuery('PRAGMA user_version'));
      if (version != DBHelper.schemaVersion) {
        return 'A cópia tem outra versão do banco ($version).';
      }
      if (expected.isNotEmpty) {
        final got = await counts(copy);
        bool same(Map<String, int> e) => _counted.every((t) => e[t] == got[t]);
        if (!expected.any(same)) {
          return 'A cópia tem um número diferente de lançamentos, contas ou operações.';
        }
      }
      return null;
    } catch (_) {
      return 'A cópia não pôde ser aberta.';
    } finally {
      await copy?.close();
    }
  }

  /// Keeps the [daily] newest copies and, before them, the newest of each
  /// of [weekly] weeks.
  static Future<void> rotate(Directory dir) async {
    final all = await copies(dir: dir);
    final keep = {for (final f in all.take(daily)) f.path};
    final weeks = <DateTime>{};
    for (final f in all.skip(daily)) {
      if (weeks.length >= weekly) break;
      final d = dateOf(f)!;
      final monday = DateTime(d.year, d.month, d.day - (d.weekday - 1));
      if (weeks.add(monday)) keep.add(f.path);
    }
    for (final f in all) {
      if (!keep.contains(f.path)) await f.delete();
    }
  }
}
