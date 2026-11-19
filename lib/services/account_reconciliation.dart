import '../models/models.dart';
import '../models/transaction_metadata.dart';
import 'reconciliation.dart';

/// One Nexo account against what its banks sent in a period: what the bank
/// has and the Nexo does not, what the Nexo has and no bank movement
/// confirms, and how much of the difference between the two balances that
/// explains. Read-only: nothing is linked, ignored or registered here.
///
/// The same reading as `reconcileAccount` in
/// supabase/functions/nexo-mcp/inbox.ts, which the assistant uses.
class AccountReconciliation {
  const AccountReconciliation({
    required this.onlyBank,
    required this.maybe,
    required this.onlyNexo,
    required this.ignoredCount,
    required this.ignoredCents,
  });

  /// Bank movements still without an entry (signed: positive comes in).
  final List<({Match match, int cents})> onlyBank;

  /// Bank movements that may be an entry already in the Nexo: the person
  /// decides, so they explain nothing yet.
  final List<Match> maybe;

  /// Paid entries of the period that no bank movement answers for.
  final List<({AppTransaction entry, int cents, String kind})> onlyNexo;

  /// Movements the person discarded: the bank moved the money, the Nexo
  /// did not.
  final int ignoredCount, ignoredCents;

  int get onlyBankCents => onlyBank.fold(0, (s, e) => s + e.cents);
  int get onlyNexoCents => onlyNexo.fold(0, (s, e) => s + e.cents);

  /// How much of (bank − Nexo) the period explains.
  int get explainedCents => onlyBankCents + ignoredCents - onlyNexoCents;

  bool get isEmpty =>
      onlyBank.isEmpty &&
      maybe.isEmpty &&
      onlyNexo.isEmpty &&
      ignoredCount == 0;
}

/// [rows]: every bank movement known to this device around the period, of
/// any status, as stored in `notification_suggestions`. [alreadyAnswered]:
/// entries linked to a movement that is outside [rows].
AccountReconciliation reconcileAccount({
  required String accountId,
  required List<Map<String, dynamic>> rows,
  required List<AppTransaction> transactions,
  required Map<String, TransactionMetadata> metadata,
  required List<Account> accounts,
  required DateTime from,
  required DateTime to,
  List<String> ownerNames = const [],
  List<ReconcileRule> rules = const [],
  List<RecurringDue> recurring = const [],
  Set<String> dismissedPairs = const {},
  Set<String> alreadyAnswered = const {},
  DateTime? now,
}) {
  final first = DateTime(from.year, from.month, from.day);
  final after = DateTime(to.year, to.month, to.day + 1);
  bool inPeriod(DateTime d) => !d.isBefore(first) && d.isBefore(after);
  final known = {for (final a in accounts) a.id};
  final credit = {
    for (final a in accounts)
      if (a.type == 'credit') a.id
  };
  final exists = {for (final t in transactions) t.id};

  // What the bank stopped returning is not in the bank any more: not
  // "only in the bank", and an entry made for it is "only in the Nexo".
  bool gone(Map<String, dynamic> r) => r['vanished'] == 1;
  final pendingRows = [
    for (final r in rows)
      if (r['status'] == 'pending' &&
          !gone(r) &&
          (r['amount_cents'] as int? ?? 0) > 0)
        r
  ];
  final confirmed = [
    for (final r in rows)
      if (r['status'] == 'confirmed' &&
          r['transaction_id'] is String &&
          exists.contains(r['transaction_id']))
        r
  ];
  // A link to an account that no longer exists is no link.
  PendingMovement movement(Map<String, dynamic> r) {
    final id = r['nexo_account_id'];
    return PendingMovement.fromRow(id is String && !known.contains(id)
        ? {...r, 'nexo_account_id': null}
        : r);
  }

  // Pairs cross accounts: everything pending is classified, then this
  // account's side is read.
  final matches = reconcile(
      pending: [for (final r in pendingRows) movement(r)],
      transactions: transactions,
      metadata: metadata,
      linkedIds: {for (final r in confirmed) r['transaction_id'] as String},
      ownerNames: ownerNames,
      creditAccounts: credit,
      dismissedPairs: dismissedPairs,
      settled: [
        for (final r in confirmed)
          if ((r['amount_cents'] as int? ?? 0) > 0)
            (movement(r), r['transaction_id'] as String)
      ],
      rules: rules,
      recurring: recurring,
      now: now);

  // Entries a bank movement already answers for.
  final answered = <String>{
    ...alreadyAnswered,
    for (final r in rows)
      if (r['transaction_id'] is String && !gone(r))
        r['transaction_id'] as String,
    for (final m in matches)
      if (m.resolution == Resolution.linked && m.transaction != null)
        m.transaction!.id,
  };

  int signed(PendingMovement m) => m.outgoing ? -m.amountCents : m.amountCents;
  // Not money that is missing: it cancels out, or it is already there.
  const neutral = {
    Resolution.linked,
    Resolution.internal,
    Resolution.reversal,
    Resolution.reserve,
  };
  final onlyBank = <({Match match, int cents})>[];
  final maybe = <Match>[];
  for (final m in matches) {
    final mv = m.movement;
    if (mv.nexoAccountId != accountId || !inPeriod(mv.occurredAt)) continue;
    if (neutral.contains(m.resolution)) continue;
    if (m.resolution == Resolution.maybe) {
      maybe.add(m);
    } else {
      onlyBank.add((match: m, cents: signed(mv)));
    }
  }

  var ignoredCount = 0, ignoredCents = 0;
  for (final r in rows) {
    if (r['status'] != 'ignored' || (r['amount_cents'] as int? ?? 0) <= 0) {
      continue;
    }
    final mv = movement(r);
    if (mv.nexoAccountId != accountId || !inPeriod(mv.occurredAt)) continue;
    ignoredCount++;
    ignoredCents += signed(mv);
  }

  final onlyNexo = <({AppTransaction entry, int cents, String kind})>[];
  for (final t in transactions) {
    if (t.accountId != accountId ||
        !inPeriod(t.date) ||
        answered.contains(t.id)) {
      continue;
    }
    final m = metadata[t.id];
    // Has not left the account yet.
    if (m?.isPending == true || m?.affectsBalance == false) continue;
    final cents = (t.amount * 100).round() * (t.type == 'income' ? 1 : -1);
    final source = m?.source ?? 'manual';
    onlyNexo.add((
      entry: t,
      cents: cents,
      kind: source == 'opening_balance'
          ? 'Ajuste de saldo'
          : source.startsWith('transfer:')
              ? 'Transferência'
              : source.startsWith('investment')
                  ? 'Investimento'
                  : t.type == 'income'
                      ? 'Receita'
                      : 'Despesa',
    ));
  }
  onlyNexo.sort((a, b) => a.entry.date.compareTo(b.entry.date));

  return AccountReconciliation(
      onlyBank: onlyBank,
      maybe: maybe,
      onlyNexo: onlyNexo,
      ignoredCount: ignoredCount,
      ignoredCents: ignoredCents);
}
