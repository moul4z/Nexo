import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../database/db_helper.dart';
import '../models/models.dart';
import '../models/transaction_metadata.dart';
import '../sync/ledger_capture.dart';
import '../sync/sync_controller.dart';
import 'account_reconciliation.dart';
import 'diagnostics.dart';
import 'import_rules_service.dart';
import 'notification_inbox.dart';
import 'platform_capabilities.dart';
import 'pluggy_inbox.dart';
import 'reconciliation.dart';

/// What the inbox shows after the app did the boring part.
class InboxState {
  const InboxState(this.matches, this.resolved, {this.deferred = const []});

  /// Movements that need the person (maybe, own transfer, new).
  final List<Match> matches;

  /// Resolved automatically before, newest first: id → reason.
  final List<AutoResolved> resolved;

  /// Decided, but registered only by the device that writes (the phone):
  /// a yield, a transfer between the person's accounts, a rule.
  final List<Match> deferred;
}

class AutoResolved {
  const AutoResolved(
      this.id, this.reason, this.description, this.amountCents, this.at,
      {this.transactionId, this.created = false, this.pairId, this.iof});
  final String id, reason, description;
  final int amountCents;
  final DateTime at;
  final String? transactionId;

  /// The app registered an entry or a transfer for it (not just a link).
  final bool created;

  /// The other bank's side of a transfer the app registered.
  final String? pairId;

  /// The IOF (cents) the app added to [transactionId].
  final int? iof;

  /// Ignores go back to the inbox; what the app registered by itself is
  /// deleted (or the IOF taken out) and the movement goes back too. A link
  /// to an entry the person made is final on every device.
  bool get undoable => transactionId == null || created || iof != null;

  Map<String, Object?> toJson() => {
        'reason': reason,
        'description': description,
        'amount_cents': amountCents,
        'at': at.millisecondsSinceEpoch,
        if (transactionId != null) 'transaction_id': transactionId,
        if (created) 'created': true,
        if (pairId != null) 'pair_id': pairId,
        if (iof != null) 'iof': iof,
      };
  static AutoResolved fromJson(String id, Map<String, dynamic> j) =>
      AutoResolved(
          id,
          j['reason'] as String,
          j['description'] as String,
          j['amount_cents'] as int,
          DateTime.fromMillisecondsSinceEpoch(j['at'] as int),
          transactionId: j['transaction_id'] as String?,
          created: j['created'] == true,
          pairId: j['pair_id'] as String?,
          iof: j['iof'] as int?);
}

/// What moves money in the inbox, done by the app with its own rules.
abstract interface class InboxWriter {
  /// Only one device registers by itself, so two never create the same
  /// entry: the phone, or a device that does not sync.
  bool get canCreate;

  /// A new entry for [m] (id `notification:<suggestion>`), linked to it.
  Future<String> addEntry(PendingMovement m,
      {required String type,
      required String accountId,
      required String categoryId,
      required String description,
      String subcategory = '',
      String? note});

  /// A transfer for [out] (and the other bank's side, when seen).
  Future<void> addTransfer(PendingMovement out, PendingMovement? incoming,
      {required String fromId, required String toId});

  /// A card bill paid from the bank: the bank's side, the card's side, or
  /// both. A transfer tied to the invoice, never spending.
  Future<void> addInvoicePayment(PendingMovement? bank, PendingMovement? card,
      {required String fromId, required String cardId});

  /// Adds the IOF charged the next day to the purchase already registered.
  Future<void> addIof(PendingMovement iof, String transactionId);

  /// Takes back out an IOF the app added (undo).
  Future<void> removeIof(String transactionId, int cents);

  /// The category for yields ("Rendimentos"), created when missing.
  Future<String> yieldCategory();

  /// Deletes what the app registered by itself (undo).
  Future<void> deleteEntry(String transactionId);

  /// [m] is someone paying back their part: the "a receber"
  /// [receivableId] is received into [m]'s account, on the bank's day, and
  /// tied to [m]. Returns the receipt's entry id.
  Future<String> receive(PendingMovement m, String receivableId);
}

/// The phone writes; a device that does not sync writes for itself.
bool defaultCanCreate() =>
    PlatformCapabilities.android || !(SyncController.instance?.bound ?? false);

/// Applies [reconcile] to the pending suggestions: links what is certainly an
/// existing entry, sets aside reversals, reserve moves and moves between the
/// person's own accounts, and, on the device that writes, registers yields,
/// transfers between the person's accounts, the IOF of a purchase and what a
/// "lançar sozinho" rule says. Remembers why, so the person can see and undo
/// it. Never creates money silently.
class InboxReconciler {
  static const _resolvedKey = 'nexo_inbox_resolved_v1';
  static const _manualKey = 'nexo_inbox_manual_v1';
  static const _dismissedKey = 'nexo_inbox_dismissed_pairs_v1';
  static const ownerKey = 'nexo_owner_names_v1';
  static const autoKey = 'nexo_inbox_auto_v1';

  /// income (default): yields become income "Rendimentos"; ignore: they
  /// leave the inbox without an entry (the balance drifts by the yields).
  static const yieldsKey = 'nexo_inbox_yields_v1';

  static Future<SharedPreferences> get _prefs =>
      SharedPreferences.getInstance();

  static Future<List<String>> ownerNames() async =>
      (await _prefs).getStringList(ownerKey) ?? const [];
  static Future<void> setOwnerNames(List<String> names) async =>
      (await _prefs).setStringList(ownerKey, [
        for (final n in names)
          if (n.trim().isNotEmpty) n.trim()
      ]);

  /// What the person typed, or the profile's full name. A single first name
  /// would match any namesake, so it does not count.
  static Future<List<String>> _owners(String profileName) async {
    final typed = await ownerNames();
    if (typed.isNotEmpty) return typed;
    final name = profileName.trim();
    return name.contains(' ') ? [name] : const [];
  }

  static DateTime? _lastBackground;

  /// The same work as opening "Para revisar", after a sync: what the app
  /// settles by itself stops reaching the person and the assistant. Then the
  /// decisions go to the server. A failure waits for the next round.
  /// Returns what the pass decided (null when it did not run).
  static Future<InboxState?> background(
      {required Future<List<Map<String, dynamic>>> Function() pending,
      required List<AppTransaction> transactions,
      required Map<String, TransactionMetadata> metadata,
      required List<Account> accounts,
      required String profileName,
      List<RecurringPayment> recurring = const [],
      List<OpenReceivable> receivables = const [],
      InboxWriter? writer,
      Future<void> Function()? push,
      Duration every = const Duration(minutes: 10)}) async {
    final now = DateTime.now();
    final last = _lastBackground;
    if (last != null && now.difference(last) < every) return null;
    _lastBackground = now;
    try {
      final rows = await pending();
      if (rows.isEmpty) return null;
      final state = await run(
          pendingRows: rows,
          transactions: transactions,
          metadata: metadata,
          accounts: accounts,
          profileName: profileName,
          recurring: recurring,
          receivables: receivables,
          writer: writer);
      await push?.call();
      return state;
    } catch (_) {
      // The screen does the same when opened.
      return null;
    }
  }

  static Future<bool> automatic() async =>
      (await _prefs).getBool(autoKey) ?? true;
  static Future<void> setAutomatic(bool on) async =>
      (await _prefs).setBool(autoKey, on);

  static Future<bool> yieldsAsIncome() async =>
      ((await _prefs).getString(yieldsKey) ?? 'income') == 'income';
  static Future<void> setYieldsAsIncome(bool on) async =>
      (await _prefs).setString(yieldsKey, on ? 'income' : 'ignore');

  static Future<Map<String, AutoResolved>> _resolved() async {
    final prefs = await _prefs;
    // Another engine (the headless pass) may have written meanwhile.
    await prefs.reload();
    final raw = prefs.getString(_resolvedKey);
    if (raw == null) return {};
    try {
      return {
        for (final e in (jsonDecode(raw) as Map).entries)
          e.key as String: AutoResolved.fromJson(
              e.key as String, (e.value as Map).cast<String, dynamic>())
      };
    } catch (_) {
      return {};
    }
  }

  static Future<void> _saveResolved(Map<String, AutoResolved> all) async {
    final sorted = all.values.toList()..sort((a, b) => b.at.compareTo(a.at));
    await (await _prefs).setString(
        _resolvedKey,
        jsonEncode({
          for (final r in sorted.take(500)) r.id: r.toJson(),
        }));
  }

  static Future<Set<String>> _set(String key) async =>
      ((await _prefs).getStringList(key) ?? const []).toSet();
  static Future<void> _add(String key, Iterable<String> values) async {
    final all = await _set(key)
      ..addAll(values);
    await (await _prefs).setStringList(key, all.take(2000).toList());
  }

  static String reasonLabel(String reason) => switch (reason) {
        'linked' => 'Já estava lançado',
        'reversal' => 'Pagamento estornado',
        'reserve' => 'Movimento de reserva',
        'ownName' => 'Transferência sua',
        'internal' => 'Entre contas suas',
        'ownTransfer' => 'Transferência registrada',
        'yieldIncome' => 'Rendimento lançado',
        'yieldIgnored' => 'Rendimento ignorado',
        'smallYield' => 'Rendimento pequeno',
        'iof' => 'IOF somado à compra',
        'rule' => 'Lançado pela regra',
        _ => 'Resolvido',
      };

  static List<ReconcileRule> _rules(List<ImportRule> rules) => [
        for (final r in rules)
          ReconcileRule(
              id: r.id,
              pattern: r.pattern,
              type: r.type,
              categoryId: r.categoryId,
              auto: r.auto,
              targetAccountId: r.targetAccountId)
      ];

  /// "Conferir com o banco", item by item: one account against the bank
  /// movements of a period, with the same reading as the inbox. Reads only.
  static Future<AccountReconciliation> account({
    required String accountId,
    required DateTime from,
    required DateTime to,
    required List<AppTransaction> transactions,
    required Map<String, TransactionMetadata> metadata,
    required List<Account> accounts,
    String profileName = '',
    List<RecurringPayment> recurring = const [],
    DateTime? now,
  }) async {
    final db = await DBHelper.database;
    // A few days around: the other side of a pair, or the entry of a
    // movement, rarely falls on the same day.
    const around = Duration(days: 5);
    final rows = await db.query('notification_suggestions',
        where: 'occurred_at >= ? AND occurred_at < ?',
        whereArgs: [
          DateTime(from.year, from.month, from.day)
              .subtract(around)
              .millisecondsSinceEpoch,
          DateTime(to.year, to.month, to.day + 1)
              .add(around)
              .millisecondsSinceEpoch
        ]);
    final answered = await db.query('notification_suggestions',
        columns: ['transaction_id'],
        where: 'transaction_id IS NOT NULL AND vanished = 0');
    return reconcileAccount(
        accountId: accountId,
        rows: rows,
        transactions: transactions,
        metadata: metadata,
        accounts: accounts,
        from: from,
        to: to,
        ownerNames: await _owners(profileName),
        rules: _rules(await ImportRulesService.load()),
        recurring: recurringDue(recurring),
        dismissedPairs: await _set(_dismissedKey),
        alreadyAnswered: {
          for (final r in answered) r['transaction_id'] as String
        },
        now: now);
  }

  /// Reconciles the pending suggestions and applies the automatic outcomes.
  static Future<InboxState> run({
    required List<Map<String, dynamic>> pendingRows,
    required List<AppTransaction> transactions,
    required Map<String, TransactionMetadata> metadata,
    List<Account> accounts = const [],
    String profileName = '',
    List<RecurringPayment> recurring = const [],
    List<OpenReceivable> receivables = const [],
    InboxWriter? writer,
    DateTime? now,
  }) async {
    final db = await DBHelper.database;
    final confirmed = await db.query('notification_suggestions',
        where: "status = 'confirmed' AND transaction_id IS NOT NULL");
    final linked = {for (final r in confirmed) r['transaction_id'] as String};
    // Undone here, or on another device (the server tells).
    final manual = {
      ...await _set(_manualKey),
      for (final r in pendingRows)
        if (r['manual'] == 1) r['id'] as String
    };
    final rules = await ImportRulesService.load();
    final learned = categoryFromHistory(transactions, metadata);
    final credit = {
      for (final a in accounts)
        if (a.type == 'credit') a.id
    };
    final known = {for (final a in accounts) a.id};
    final matches = reconcile(
        pending: [
          for (final r in pendingRows)
            _withKnownAccount(PendingMovement.fromRow(r), known)
        ],
        transactions: transactions,
        metadata: metadata,
        linkedIds: linked,
        ownerNames: await _owners(profileName),
        creditAccounts: credit,
        dismissedPairs: await _set(_dismissedKey),
        settled: [
          for (final r in confirmed)
            // Expired rows keep no amount.
            if ((r['amount_cents'] as int? ?? 0) > 0)
              (PendingMovement.fromRow(r), r['transaction_id'] as String)
        ],
        rules: _rules(rules),
        recurring: recurringDue(recurring),
        receivables: receivables,
        now: now,
        learnedCategory: (m) {
          final type = m.outgoing ? 'expense' : 'income';
          final rule = rules
              .where((r) =>
                  r.type == type &&
                  r.pattern.trim().isNotEmpty &&
                  m.description
                      .toLowerCase()
                      .contains(r.pattern.trim().toLowerCase()))
              .firstOrNull;
          return rule?.categoryId ?? learned(m);
        });
    final resolved = await _resolved();
    final keep = <Match>[], deferred = <Match>[];
    final auto = await automatic();
    final yieldsIncome = await yieldsAsIncome();
    final canCreate = writer?.canCreate ?? false;
    final done = <String>{};
    for (final m in matches) {
      final mv = m.movement;
      if (done.contains(mv.id)) continue;
      // Undone by the person: never decided by the app again.
      if (!auto || !m.automatic || manual.contains(mv.id)) {
        keep.add(m.automatic ? _asQuestion(m) : m);
        continue;
      }
      final creates = switch (m.resolution) {
        Resolution.yieldIncome => yieldsIncome,
        Resolution.ownTransfer ||
        Resolution.rule ||
        Resolution.iof ||
        Resolution.receivable =>
          true,
        _ => false,
      };
      if (creates && (!canCreate || writer == null)) {
        deferred.add(m);
        continue;
      }
      try {
        String? createdId, pairId;
        int? iof;
        var reason = m.resolution.name;
        switch (m.resolution) {
          case Resolution.linked:
            await DBHelper.confirmSuggestion(db, mv.id, m.transaction!.id);
            await learnPixName(mv.id, m.transaction!.id);
          case Resolution.yieldIncome when yieldsIncome:
            final account = mv.nexoAccountId;
            if (account == null) {
              // Without the bank linked to a Nexo account: the person picks.
              keep.add(Match(mv, Resolution.newEntry,
                  categoryId: await writer!.yieldCategory()));
              continue;
            }
            createdId = await writer!.addEntry(mv,
                type: 'income',
                accountId: account,
                categoryId: await writer.yieldCategory(),
                description:
                    mv.bank == null ? 'Rendimentos' : 'Rendimentos ${mv.bank}');
          case Resolution.yieldIncome:
            reason = 'yieldIgnored';
            await NotificationInbox.ignore(mv.id);
          case Resolution.ownTransfer:
            final pair = m.pair;
            // Registered once, from the side that left the account.
            if (!mv.outgoing && pair != null) continue;
            await writer!.addTransfer(mv, pair,
                fromId: m.fromAccountId!, toId: m.toAccountId!);
            createdId = 'notification:${mv.id}';
            pairId = pair?.id;
            if (pair != null) done.add(pair.id);
          case Resolution.iof:
            await writer!.addIof(mv, m.transaction!.id);
            iof = mv.amountCents;
          case Resolution.rule:
            if (m.toAccountId != null && m.fromAccountId != null) {
              await writer!.addTransfer(mv, null,
                  fromId: m.fromAccountId!, toId: m.toAccountId!);
              createdId = 'notification:${mv.id}';
            } else {
              createdId = await writer!.addEntry(mv,
                  type: mv.outgoing ? 'expense' : 'income',
                  accountId: mv.nexoAccountId!,
                  categoryId: m.categoryId!,
                  description: mv.description,
                  note: 'Lançado pela regra de importação');
            }
          case Resolution.receivable:
            createdId = await writer!.receive(mv, m.receivableId!);
          default:
            // reversal, reserve, internal: nothing to register.
            await NotificationInbox.ignore(mv.id);
        }
        done.add(mv.id);
        resolved[mv.id] = AutoResolved(
            mv.id, reason, mv.description, mv.amountCents, DateTime.now(),
            transactionId: createdId ?? m.transaction?.id,
            created: createdId != null,
            pairId: pairId,
            iof: iof);
      } on StateError {
        // Resolved meanwhile (another device or screen): nothing to do.
        continue;
      } on ArgumentError {
        // The account or category is gone: leave it for the person.
        keep.add(_asQuestion(m));
      } catch (e) {
        // Anything else stops this movement only: what was already done in
        // this round stays listed, with its undo.
        Diagnostics.note('inbox', e);
        keep.add(_asQuestion(m));
      }
    }
    await _saveResolved(resolved);
    return InboxState(
        keep, resolved.values.toList()..sort((a, b) => b.at.compareTo(a.at)),
        deferred: deferred);
  }

  /// What the app would have done by itself, as a question to the person.
  static Match _asQuestion(Match m) => switch (m.resolution) {
        Resolution.linked => Match(m.movement, Resolution.maybe,
            transaction: m.transaction, score: m.score, pair: m.pair),
        Resolution.ownTransfer || Resolution.iof || Resolution.rule => Match(
            m.movement, m.resolution,
            transaction: m.transaction,
            pair: m.pair,
            categoryId: m.categoryId,
            fromAccountId: m.fromAccountId,
            toAccountId: m.toAccountId,
            ruleId: m.ruleId),
        // The person confirms the receipt; without a known account it is a
        // new entry like any other.
        Resolution.receivable when m.movement.nexoAccountId != null => Match(
            m.movement, Resolution.receivable,
            receivableId: m.receivableId),
        _ => Match(m.movement, Resolution.newEntry, categoryId: m.categoryId),
      };

  /// A link to a Nexo account that no longer exists counts as no link.
  static PendingMovement _withKnownAccount(
          PendingMovement m, Set<String> known) =>
      m.nexoAccountId == null || known.contains(m.nexoAccountId)
          ? m
          : PendingMovement(
              id: m.id,
              amountCents: m.amountCents,
              description: m.description,
              kind: m.kind,
              occurredAt: m.occurredAt,
              medium: m.medium,
              direction: m.direction,
              accountId: m.accountId,
              bank: m.bank,
              operationRef: m.operationRef,
              paymentRef: m.paymentRef,
              sameOwner: m.sameOwner,
              counterparty: m.counterparty);

  /// "It is the same": the movement is the existing entry.
  static Future<void> link(String suggestionId, String transactionId) async {
    await DBHelper.confirmSuggestion(
        await DBHelper.database, suggestionId, transactionId);
    await learnPixName(suggestionId, transactionId);
  }

  /// A receipt typed by hand ("Recebido de…") tied to the bank's Pix: the
  /// name the bank showed is kept on the person (when it has name and
  /// surname and nothing was learned yet), so their next Pix settles their
  /// part even if the Nexo only knows a first name.
  static Future<void> learnPixName(
      String suggestionId, String transactionId) async {
    const prefix = 'lended-received:';
    if (!transactionId.startsWith(prefix)) return;
    final db = await DBHelper.database;
    final rows = await db.query('notification_suggestions',
        columns: ['counterparty', 'description'],
        where: 'id = ?',
        whereArgs: [suggestionId]);
    if (rows.isEmpty) return;
    final counterparty = (rows.single['counterparty'] as String? ?? '').trim();
    final shown = counterparty.isNotEmpty
        ? counterparty
        : (rows.single['description'] as String? ?? '').trim();
    if (normalizeMerchant(shown).split(' ').length < 2) return;
    try {
      await ledgerTransaction(db, 'lended.pix_name', (txn) async {
        final lended = await txn.query('lended_money',
            columns: ['person_id'],
            where: 'id = ?',
            whereArgs: [transactionId.substring(prefix.length)]);
        if (lended.isEmpty) return;
        await txn.update('lended_people', {'pix_name': shown},
            where: "id = ? AND COALESCE(pix_name, '') = ''",
            whereArgs: [lended.single['person_id']]);
      });
    } catch (e) {
      // Only a convenience: the link itself is already saved.
      Diagnostics.note('inbox', e);
    }
  }

  /// "They are different": never pair them again.
  static Future<void> dismissPair(String suggestionId, String transactionId) =>
      _add(_dismissedKey, ['$suggestionId|$transactionId']);

  /// Back to the inbox; the app will not decide it by itself again. What
  /// the app registered by itself is deleted first (or the IOF it added is
  /// taken out of the purchase).
  static Future<void> undo(AutoResolved r, {InboxWriter? writer}) async {
    if (!r.undoable) return;
    final ids = [r.id, if (r.pairId != null) r.pairId!];
    if ((r.created || r.iof != null) && writer == null) return;
    await _add(_manualKey, ids);
    if (r.created && r.transactionId != null) {
      await writer!.deleteEntry(r.transactionId!);
      await reopen(ids);
    } else if (r.iof != null && r.transactionId != null) {
      await writer!.removeIof(r.transactionId!, r.iof!);
      await reopen(ids);
    } else {
      await NotificationInbox.undoIgnore(r.id);
      if (PluggyInbox.isPluggy(r.id)) await PluggyInbox.instance?.pushNow();
    }
    final all = await _resolved()
      ..remove(r.id);
    await _saveResolved(all);
  }

  /// A linked movement whose entry was deleted goes back to the inbox, here
  /// and on the server (other devices follow when the deletion reaches them).
  static Future<void> reopen(List<String> ids) async {
    final db = await DBHelper.database;
    for (final id in ids) {
      await db.update('notification_suggestions',
          {'status': 'pending', 'transaction_id': null},
          where: "id = ? AND status = 'confirmed'", whereArgs: [id]);
    }
    if (ids.any(PluggyInbox.isPluggy)) await PluggyInbox.instance?.pushNow();
  }

  /// Ignores many at once (own transfers already in the balances, or what
  /// the person marked as reviewed).
  static Future<void> ignoreAll(Iterable<String> ids) async {
    for (final id in ids) {
      await NotificationInbox.ignore(id);
    }
  }
}
