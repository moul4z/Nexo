import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:sqflite/sqflite.dart';

import '../database/db_helper.dart';
import 'balance_check.dart';
import '../sync/supabase_auth.dart';
import '../sync/sync_config.dart';
import 'diagnostics.dart';

class PluggyItem {
  const PluggyItem(this.itemId, this.label, this.state, this.message,
      {this.bankUpdatedAt});
  final String itemId, label;

  /// When the newest bank movement of this connection reached Pluggy (Meu
  /// Pluggy refreshes once a day; a day without movements does not move
  /// it); null when the server does not know.
  final DateTime? bankUpdatedAt;

  /// ok | updating | reconnect | expiring | error | unknown (never read yet)
  final String state;
  final String message;

  static PluggyItem fromJson(Map<String, dynamic> json) {
    final health = json['health'] as Map<String, dynamic>?;
    return PluggyItem(
        json['item_id'] as String,
        json['label'] as String,
        health?['state'] as String? ?? 'unknown',
        health?['message'] as String? ??
            'Ainda não lido. Toque em Atualizar agora.',
        bankUpdatedAt: json['bank_updated_at'] is String
            ? DateTime.tryParse(json['bank_updated_at'] as String)?.toLocal()
            : null);
  }
}

/// "Última movimentação recebida em 22/10 às 06:00".
String bankDataUntil(PluggyItem item) {
  final at = item.bankUpdatedAt;
  if (at == null) return 'Nenhuma movimentação recebida ainda';
  String two(int v) => v.toString().padLeft(2, '0');
  return 'Última movimentação recebida em ${two(at.day)}/${two(at.month)} às ${two(at.hour)}:${two(at.minute)}';
}

/// Banks whose data for today did not arrive yet (null when all did or the
/// server does not tell).
String? todayMissing(List<PluggyItem> items, DateTime now) {
  final today = DateTime(now.year, now.month, now.day);
  final late = items
      .where((i) => i.bankUpdatedAt != null && i.bankUpdatedAt!.isBefore(today))
      .map((i) => i.label)
      .toList();
  if (late.isEmpty) return null;
  return 'Nenhuma movimentação de hoje chegou ainda de ${late.join(', ')}: o Open Finance atualiza uma vez por dia. Gastos de hoje podem faltar aqui.';
}

/// A server answer the person can act on.
class PluggyUnavailable implements Exception {
  const PluggyUnavailable(this.message);
  final String message;
  @override
  String toString() => 'PluggyUnavailable';
}

abstract interface class PluggyRemote {
  /// Asks the server to read Pluggy now (it limits how often it really does).
  Future<List<PluggyItem>> refresh({bool force = false});
  Future<List<PluggyItem>> items();
  Future<void> addItem(String itemId, String label);
  Future<void> removeItem(String itemId);
  Future<List<Map<String, dynamic>>> suggestions(int sinceMs);
  Future<void> decide(List<Map<String, Object?>> decisions);

  /// Latest balance and card limits of each bank account, with the link to
  /// a Nexo account.
  Future<List<BankAccountSnapshot>> accounts();
  Future<void> link(String accountId, String? nexoAccountId);
}

class SupabasePluggyRemote implements PluggyRemote {
  SupabasePluggyRemote(this.config, this.auth,
      {http.Client Function()? clientFactory})
      : _clientFactory = clientFactory ?? http.Client.new;
  final SyncConfig config;
  final SupabaseAuth auth;
  final http.Client Function() _clientFactory;

  Future<Object?> _post(String path, Object body) async {
    final token = await auth.accessToken();
    if (token == null) {
      throw const PluggyUnavailable(
          'Entre na sua conta em Sincronizar dispositivos.');
    }
    final client = _clientFactory();
    try {
      final response = await client
          .post(config.projectUrl.resolve(path),
              headers: {
                'apikey': config.publishableKey,
                'Authorization': 'Bearer $token',
                'Content-Type': 'application/json',
              },
              body: jsonEncode(body))
          .timeout(const Duration(seconds: 60));
      final status = response.statusCode;
      if (status == 200 || status == 204) {
        return response.body.isEmpty ? null : jsonDecode(response.body);
      }
      String? code;
      try {
        final decoded = jsonDecode(response.body);
        if (decoded is Map)
          code = (decoded['error'] ?? decoded['message']) as String?;
      } catch (_) {}
      throw PluggyUnavailable(switch ((status, code)) {
        (404, _) when path.startsWith('/functions') =>
          'A busca no Pluggy ainda não foi publicada no servidor.',
        (404, _) =>
          'O servidor ainda não tem esta função. Publique a atualização do servidor.',
        (503, 'not_configured') =>
          'As credenciais do Pluggy ainda não foram cadastradas no servidor.',
        (403, 'not_owner') => 'Esta conta não é a dona das conexões Pluggy.',
        (401 || 403, _) => 'Entre novamente na sua conta para buscar no banco.',
        (_, 'too_many_items') => 'O Meu Pluggy permite até 5 conexões.',
        (_, 'invalid_item') =>
          'Identificador inválido. Copie o id do item no painel do Pluggy.',
        _ =>
          'O servidor não respondeu como esperado (HTTP $status). Tente mais tarde.',
      });
    } on TimeoutException {
      throw const PluggyUnavailable(
          'Sem resposta do servidor. Tente mais tarde.');
    } on http.ClientException {
      throw const PluggyUnavailable('Sem conexão com o servidor.');
    } finally {
      client.close();
    }
  }

  Future<Object?> _rpc(String name, Map<String, Object?> args) =>
      _post('/rest/v1/rpc/$name', args);

  List<PluggyItem> _items(Object? list) => [
        for (final i in (list as List? ?? const []))
          PluggyItem.fromJson((i as Map).cast<String, dynamic>())
      ];

  @override
  Future<List<PluggyItem>> refresh({bool force = false}) async {
    final result = await _post('/functions/v1/pluggy-sync', {'force': force});
    return _items((result as Map?)?['items']);
  }

  @override
  Future<List<PluggyItem>> items() async =>
      _items(await _rpc('nexo_pluggy_items', const {}));

  @override
  Future<void> addItem(String itemId, String label) =>
      _rpc('nexo_pluggy_add_item', {'p_item_id': itemId, 'p_label': label});

  @override
  Future<void> removeItem(String itemId) =>
      _rpc('nexo_pluggy_remove_item', {'p_item_id': itemId});

  @override
  Future<List<Map<String, dynamic>>> suggestions(int sinceMs) async => [
        for (final r
            in (await _rpc('nexo_pluggy_suggestions', {'p_since_ms': sinceMs})
                    as List? ??
                const []))
          (r as Map).cast<String, dynamic>()
      ];

  @override
  Future<void> decide(List<Map<String, Object?>> decisions) =>
      _rpc('nexo_pluggy_decide', {'p_decisions': decisions});

  @override
  Future<List<BankAccountSnapshot>> accounts() async => [
        for (final r
            in (await _rpc('nexo_pluggy_accounts', const {}) as List? ??
                const []))
          BankAccountSnapshot.fromJson((r as Map).cast<String, dynamic>())
      ];

  @override
  Future<void> link(String accountId, String? nexoAccountId) => _rpc(
      'nexo_pluggy_link_account',
      {'p_account_id': accountId, 'p_nexo_account_id': nexoAccountId});
}

/// Open Finance movements as reviewable suggestions in the same inbox as the
/// bank notifications. The server keeps the decision of every suggestion so
/// all devices agree; confirming creates the transaction with a fixed id
/// (`notification:pluggy:<id>`), so two devices can never register it twice.
class PluggyInbox {
  PluggyInbox(this.remote, {DateTime Function()? now})
      : _now = now ?? DateTime.now;
  final PluggyRemote remote;
  final DateTime Function() _now;
  static PluggyInbox? instance;

  static const appId = 'pluggy';
  static const window = Duration(days: 35);
  static const _refreshEvery = Duration(minutes: 30);
  DateTime? _lastRefresh;
  Future<String?>? _running;

  static bool isPluggy(String suggestionId) =>
      suggestionId.startsWith('pluggy:');

  /// Sends local decisions, asks the server to read Pluggy when due, and
  /// brings suggestions and other devices' decisions. Returns a message for
  /// the person when something could not be done; local data stays valid.
  Future<String?> sync({bool force = false}) =>
      _running ??= _sync(force).whenComplete(() => _running = null);

  static const backgroundEvery = Duration(minutes: 15);
  DateTime? _lastBackground;

  /// On opening or returning to the app: brings what the banks sent without
  /// waiting for "Para revisar". At most every [backgroundEvery], silent
  /// (the inbox shows problems), and only suggestions: nothing becomes an
  /// entry here.
  Future<bool> refreshInBackground() async {
    final last = _lastBackground;
    if (last != null && _now().difference(last) < backgroundEvery) {
      return false;
    }
    _lastBackground = _now();
    try {
      await sync();
    } catch (e) {
      Diagnostics.note('open finance', e);
      // Offline or server down: the next opening tries again.
    }
    return true;
  }

  Future<String?> _sync(bool force) async {
    final db = await DBHelper.database;
    final since = _now().subtract(window).millisecondsSinceEpoch;
    String? problem;
    try {
      await _push(db, since);
      final last = _lastRefresh;
      if (force || last == null || _now().difference(last) >= _refreshEvery) {
        try {
          await remote.refresh(force: force);
          _lastRefresh = _now();
        } on PluggyUnavailable catch (e) {
          // Suggestions already on the server still arrive below.
          problem = e.message;
        }
      }
      await _apply(db, await remote.suggestions(since));
    } on PluggyUnavailable catch (e) {
      return e.message;
    }
    return problem;
  }

  /// Sends what was decided (or undone) here since the server last heard
  /// from this device. What the server already knows is not repeated, so a
  /// decision undone on another device is not put back by this one.
  Future<void> _push(Database db, int since) async {
    final rows = await db.query('notification_suggestions',
        where: 'app_id = ? AND occurred_at >= ? AND ('
            "(status IN ('confirmed', 'ignored') AND COALESCE(sent_status, '') != status) OR "
            "(status = 'pending' AND sent_status IN ('confirmed', 'ignored')))",
        whereArgs: [appId, since]);
    for (var i = 0; i < rows.length; i += 500) {
      final page = rows.skip(i).take(500).toList();
      await remote.decide([
        for (final r in page)
          {
            'id': r['id'],
            'review': r['status'],
            if (r['status'] == 'confirmed' && r['transaction_id'] != null)
              'transaction_id': r['transaction_id'],
            // The entry the app had made for it was undone.
            if (r['status'] == 'pending' && r['sent_status'] == 'confirmed')
              'reopen': true,
          }
      ]);
      await db.transaction((txn) async {
        for (final r in page) {
          await txn.update(
              'notification_suggestions', {'sent_status': r['status']},
              where: 'id = ? AND status = ?',
              whereArgs: [r['id'], r['status']]);
        }
      });
    }
  }

  Future<void> _apply(Database db, List<Map<String, dynamic>> rows) =>
      db.transaction((txn) async {
        for (final r in rows) {
          final id = r['id'], review = r['review'];
          if (id is! String || !isPluggy(id)) continue;
          // The bank stopped returning it (or returns it again). Any row:
          // a decided one only matters to the reconciliation.
          await txn.update('notification_suggestions',
              {'vanished': r['vanished'] == true ? 1 : 0},
              where: 'id = ? AND vanished != ?',
              whereArgs: [id, r['vanished'] == true ? 1 : 0]);
          if (review == 'pending') {
            final required = {
              'amount_cents': r['amount_cents'],
              'description': r['description'],
              'kind': r['kind'],
              'medium': r['medium'],
              'occurred_at': r['occurred_at'],
            };
            if (required.values.any((v) => v == null)) continue;
            // What the reconciliation needs from the bank (1.18 server;
            // an older server leaves them empty and the rules still work).
            String? text(String key) =>
                r[key] is String && (r[key] as String).isNotEmpty
                    ? r[key] as String
                    : null;
            final values = {
              ...required,
              'direction': switch (r['direction']) {
                'in' || 'out' => r['direction'],
                _ => null,
              },
              'bank_account_id': text('account_id'),
              'nexo_account_id': text('nexo_account_id'),
              'bank': text('bank'),
              'operation_ref': text('operation_ref'),
              'payment_ref': text('payment_ref'),
              'same_owner': switch (r['same_owner']) {
                true => 1,
                false => 0,
                _ => null,
              },
              'counterparty': text('counterparty'),
              'manual': r['manual'] == true ? 1 : 0,
              'vanished': r['vanished'] == true ? 1 : 0,
            };
            final inserted = await txn.insert('notification_suggestions',
                {'id': id, 'app_id': appId, ...values},
                conflictAlgorithm: ConflictAlgorithm.ignore);
            // The bank corrected a suggestion nobody decided yet.
            if (inserted == 0) {
              await txn.update('notification_suggestions', values,
                  where: "id = ? AND status = 'pending'", whereArgs: [id]);
              // Put back on another device, after the server had this
              // device's decision: an ignore undone, or the entry the app
              // had made for it undone (once that entry is gone here too).
              await txn.rawUpdate(
                  "UPDATE notification_suggestions SET status = 'pending', "
                  "transaction_id = NULL, sent_status = 'pending', manual = 1 "
                  'WHERE id = ? AND sent_status = status AND ('
                  "status = 'ignored' OR (status = 'confirmed' AND NOT EXISTS "
                  '(SELECT 1 FROM transactions t WHERE t.id = notification_suggestions.transaction_id)))',
                  [id]);
            }
          } else if (review == 'confirmed' || review == 'ignored') {
            // Resolved on another device: leave this inbox.
            await txn.update('notification_suggestions',
                {'status': review, 'sent_status': review},
                where:
                    "id = ? AND status = 'pending' AND COALESCE(sent_status, 'pending') = 'pending'",
                whereArgs: [id]);
          }
        }
      });

  /// An ignore was undone on this device, or the entry the app had made
  /// for a movement was undone: tell the server right away (offline, the
  /// next sync does). A server older than 1.18 keeps a confirmed one decided.
  Future<void> pushNow() async {
    try {
      await _push(await DBHelper.database,
          _now().subtract(window).millisecondsSinceEpoch);
    } on PluggyUnavailable catch (e) {
      Diagnostics.note('open finance', e);
    }
  }
}
