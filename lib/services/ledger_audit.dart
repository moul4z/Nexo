import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart' hide Transaction;

import '../database/db_helper.dart';
import 'diagnostics.dart';

/// An account whose stored balance moved differently from its entries.
class AccountDrift {
  const AccountDrift(this.accountId, this.name, this.cents);
  final String accountId, name;

  /// Stored balance minus what the entries explain, since the last check.
  final int cents;
}

/// Internal check of the ledger (F2): for each account whose balance moves
/// only through entries in its own currency, "stored balance minus the
/// entries that count" is a constant. A correct write moves both sides by
/// the same amount; a defect that moves one side only changes it. Each
/// device remembers the last value and compares. Read-only: nothing is ever
/// corrected by itself (rule 6); a difference goes to Ajuda › Diagnóstico.
///
/// Left out, because their balance also moves without an entry: gold,
/// accounts with goal contributions, loans or money lent, and accounts with
/// an entry in another currency (converted at the rate of the day).
abstract final class LedgerAudit {
  static const _baseKey = 'nexo_ledger_audit_base_v1';
  static const _atKey = 'nexo_ledger_audit_at_v1';
  static const every = Duration(hours: 20);

  /// Stored balance minus the entries that count, in cents, per account.
  static Future<Map<String, int>> implied(DatabaseExecutor db) async {
    Future<Set<String>> ids(String sql) async => {
          for (final r in await db.rawQuery(sql))
            if (r['id'] is String) r['id'] as String
        };
    final skip = {
      ...await ids("SELECT id FROM accounts WHERE type = 'gold'"),
      ...await ids(
          'SELECT DISTINCT account_id AS id FROM savings_contributions'),
      ...await ids('SELECT DISTINCT account_id AS id FROM lended_money'),
      ...await ids('SELECT DISTINCT account_id AS id FROM loans'),
      ...await ids('SELECT DISTINCT transfer_account_id AS id FROM loans'),
      ...await ids('SELECT DISTINCT account_id AS id FROM loan_payments'),
      ...await ids('SELECT DISTINCT t.account_id AS id FROM transactions t '
          'JOIN accounts a ON a.id = t.account_id '
          "WHERE COALESCE(t.currency, '') != '' AND t.currency != a.currency"),
    };
    final sums = {
      for (final r in await db.rawQuery(
          "SELECT t.account_id AS id, SUM(CASE WHEN t.type = 'income' THEN t.amount ELSE -t.amount END) AS total "
          'FROM transactions t LEFT JOIN transaction_metadata m ON m.transaction_id = t.id '
          "WHERE COALESCE(m.status, 'paid') != 'pending' AND COALESCE(m.affects_balance, 1) = 1 "
          'GROUP BY t.account_id'))
        r['id'] as String: (r['total'] as num?)?.toDouble() ?? 0
    };
    return {
      for (final a in await db.query('accounts', columns: ['id', 'balance']))
        if (!skip.contains(a['id']))
          a['id'] as String:
              (((a['balance'] as num).toDouble() - (sums[a['id']] ?? 0)) * 100)
                  .round()
    };
  }

  /// Compares with this device's last check and remembers the new values.
  /// A difference is reported once; the next check starts from it.
  static Future<List<AccountDrift>> run(
      {DatabaseExecutor? db, SharedPreferences? prefs}) async {
    final database = db ?? await DBHelper.database;
    final store = prefs ?? await SharedPreferences.getInstance();
    final now = await implied(database);
    Map<String, int> base;
    try {
      base = (jsonDecode(store.getString(_baseKey) ?? '{}') as Map)
          .map((k, v) => MapEntry(k as String, (v as num).toInt()));
    } catch (_) {
      base = {};
    }
    final names = {
      for (final r in await database.query('accounts', columns: ['id', 'name']))
        r['id'] as String: r['name'] as String? ?? ''
    };
    final compared = now.keys.where(base.containsKey).length;
    final drifts = [
      for (final e in now.entries)
        if (base[e.key] != null && (e.value - base[e.key]!).abs() > 1)
          AccountDrift(e.key, names[e.key] ?? '', e.value - base[e.key]!)
    ];
    await store.setString(_baseKey, jsonEncode(now));
    // Every account at once: the whole ledger was replaced (a restore, or
    // entering another device's dataset), not a defect of one write.
    if (compared >= 2 && drifts.length == compared) return const [];
    return drifts;
  }

  /// At most every [every], silent: a difference goes to Diagnóstico.
  static Future<void> runIfDue({DateTime? now}) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final clock = now ?? DateTime.now();
      final last = DateTime.tryParse(prefs.getString(_atKey) ?? '');
      if (last != null && clock.difference(last) < every) return;
      final drifts = await run(prefs: prefs);
      await prefs.setString(_atKey, clock.toIso8601String());
      for (final d in drifts) {
        Diagnostics.note(
            'conferência interna',
            StateError(
                'O saldo guardado de "${d.name}" mudou ${(d.cents / 100).toStringAsFixed(2)} '
                'além dos lançamentos desde a última conferência. Nada foi corrigido sozinho; '
                'confira a conta com o banco.'));
      }
    } catch (e) {
      Diagnostics.note('conferência interna', e);
    }
  }

  /// The balance was set by the person (account edited) or the whole
  /// ledger was replaced (restore): the next check starts over.
  static Future<void> forget([String? accountId]) async {
    final prefs = await SharedPreferences.getInstance();
    if (accountId == null) {
      await prefs.remove(_baseKey);
      return;
    }
    try {
      final base = (jsonDecode(prefs.getString(_baseKey) ?? '{}') as Map)
        ..remove(accountId);
      await prefs.setString(_baseKey, jsonEncode(base));
    } catch (_) {
      await prefs.remove(_baseKey);
    }
  }
}
