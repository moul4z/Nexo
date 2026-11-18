import '../models/models.dart';
import '../models/transaction_metadata.dart';
import 'finance_rules.dart';

/// A bank movement waiting for review (a row of `notification_suggestions`).
///
/// The same rules run in the connector (`supabase/functions/nexo-mcp/
/// reconcile.ts`); both pass the cases in `test/fixtures/reconcile_cases.json`.
class PendingMovement {
  const PendingMovement(
      {required this.id,
      required this.amountCents,
      required this.description,
      required this.kind,
      required this.occurredAt,
      this.medium = 'bank',
      this.direction,
      this.accountId,
      this.nexoAccountId,
      this.bank,
      this.operationRef,
      this.paymentRef,
      this.sameOwner,
      this.counterparty});
  final String id, description;

  /// bank | credit: where the bank says the money moved.
  final String medium;

  /// expense | income | refund | transfer
  final String kind;
  final int amountCents;
  final DateTime occurredAt;

  /// in | out, from the bank; null for rows stored before 1.18.
  final String? direction;

  /// The bank account at Pluggy and the Nexo account it is linked to.
  final String? accountId, nexoAccountId, bank;

  /// The bank's ids of the operation (a payment and its refund share one).
  final String? operationRef, paymentRef;

  /// Payer and receiver have the same tax number.
  final bool? sameOwner;

  /// Who paid or received, when the bank tells it.
  final String? counterparty;

  factory PendingMovement.fromRow(Map<String, dynamic> r) {
    // An empty text is no information, like in the connector.
    String? text(String key) {
      final v = r[key];
      return v is String && v.isNotEmpty ? v : null;
    }

    return PendingMovement(
      id: r['id'] as String,
      amountCents: r['amount_cents'] as int,
      description: r['description'] as String,
      kind: r['kind'] as String,
      medium: r['medium'] as String? ?? 'bank',
      occurredAt: DateTime.fromMillisecondsSinceEpoch(r['occurred_at'] as int),
      direction: switch (r['direction']) {
        'in' => 'in',
        'out' => 'out',
        _ => null,
      },
      accountId: text('bank_account_id'),
      nexoAccountId: text('nexo_account_id'),
      bank: text('bank'),
      operationRef: text('operation_ref'),
      paymentRef: text('payment_ref'),
      sameOwner: switch (r['same_owner']) {
        1 || true => true,
        0 || false => false,
        _ => null,
      },
      counterparty: text('counterparty'),
    );
  }

  /// Money leaving the account. A "transfer" without a direction (older
  /// rows) is read from where it happened and what it says.
  bool get outgoing => movementDirection(this) == 'out';

  String get words => '$description ${counterparty ?? ''}';
}

String movementDirection(PendingMovement m) {
  if (m.direction == 'in' || m.direction == 'out') return m.direction!;
  if (m.kind == 'expense') return 'out';
  if (m.kind == 'income' || m.kind == 'refund') return 'in';
  if (m.medium == 'credit') return 'in';
  return RegExp(r'rendimento|remunera|resgate|recebid', caseSensitive: false)
          .hasMatch(m.description)
      ? 'in'
      : 'out';
}

enum Resolution {
  /// Same movement as an entry already in the Nexo: link, create nothing.
  linked,

  /// Possibly an entry already in the Nexo: the person decides.
  maybe,

  /// Between two bank accounts linked to the same Nexo account: nothing
  /// to register.
  internal,

  /// Money between the person's own accounts (both sides seen). Automatic
  /// when both Nexo accounts are known: it becomes a transfer.
  ownTransfer,

  /// To or from the person's own name, with the other side not seen (a
  /// broker that is not connected, for instance): never spending or income;
  /// the person says where it went.
  ownName,

  /// A card bill paid from the bank, with no payment in the Nexo yet.
  invoicePayment,

  /// A payment and its refund: nothing happened.
  reversal,

  /// Automatic reserve moves (e.g. "Reserva por gasto"): not spending.
  reserve,

  /// Yield credited by the bank.
  yieldIncome,

  /// The IOF of an international purchase, charged the next day.
  iof,

  /// A rule the person marked "lançar sozinho".
  rule,

  /// Nothing similar in the Nexo: probably not registered yet.
  newEntry,
}

class Match {
  const Match(this.movement, this.resolution,
      {this.automatic = false,
      this.transaction,
      this.score = 0,
      this.pair,
      this.categoryId,
      this.wrongAccount = false,
      this.fromAccountId,
      this.toAccountId,
      this.waiting = false,
      this.ruleId,
      this.withIof});
  final PendingMovement movement;
  final Resolution resolution;

  /// Applied without asking. Linking and ignoring happen on any device; a
  /// new entry or transfer only on the device that writes.
  final bool automatic;
  final AppTransaction? transaction;

  /// 0..100 for [Resolution.linked] / [Resolution.maybe].
  final int score;

  /// The other side of an own transfer, card payment, reversal or IOF.
  final PendingMovement? pair;

  /// Category learned from rules or past entries, for new entries.
  final String? categoryId;

  /// The entry looks right but sits on the other kind of account: the bank
  /// saw a Pix where the Nexo has a card purchase, or the opposite.
  final bool wrongAccount;

  /// A transfer between two Nexo accounts.
  final String? fromAccountId, toAccountId;

  /// The other side may still arrive: banks report a day apart.
  final bool waiting;
  final String? ruleId;

  /// Linked together with the IOF charged the next day.
  final PendingMovement? withIof;
}

/// A card bill payment already in the Nexo: the two legs of the transfer.
class PaymentLegs {
  const PaymentLegs(
      {required this.debitId,
      required this.creditId,
      required this.cents,
      required this.day,
      required this.fromAccountId,
      required this.cardId});
  final String debitId, creditId, fromAccountId, cardId;
  final int cents;
  final DateTime day;
}

/// An import rule as the reconciliation reads it.
class ReconcileRule {
  const ReconcileRule(
      {required this.id,
      required this.pattern,
      required this.type,
      required this.categoryId,
      this.auto = false,
      this.targetAccountId});
  final String id, pattern, type, categoryId;
  final bool auto;
  final String? targetAccountId;
}

final _noise = RegExp(
    r'^(ifd\*|ifd |mp \*|mp\*|pg \*|pg\*|pag\*|pp\*|ec \*|dl\*|ebn\*)',
    caseSensitive: false);
final _movementWords = RegExp(
    r'\b(pix|ted|doc|transf\w*|enviad[oa]|recebid[oa]|pagamento|pagto|pgto|com|de|para|do|da|por|compra|no|na|em|cartao|debito|credito|qr|code|ltda|me|eireli|sa)\b');
const _accents = {
  'á': 'a', 'à': 'a', 'â': 'a', 'ã': 'a', 'é': 'e', 'ê': 'e', 'í': 'i', //
  'ó': 'o', 'ô': 'o', 'õ': 'o', 'ú': 'u', 'ü': 'u', 'ç': 'c',
};

/// Merchant / counterparty name without card prefixes (Ifd*, Mp *, Pg *),
/// numbers, CNPJ, punctuation, accents and movement words.
String normalizeMerchant(String text) {
  var s = text.trim().toLowerCase();
  s = s.replaceFirst(_noise, '');
  s = s.split('').map((c) => _accents[c] ?? c).join();
  s = s.replaceAll(RegExp(r'[0-9]'), ' ');
  s = s.replaceAll(RegExp(r'[^a-z ]'), ' ');
  s = s.replaceAll(_movementWords, ' ');
  return s.replaceAll(RegExp(r'\s+'), ' ').trim();
}

/// token_set_ratio-like similarity, 0..1.
double textSimilarity(String a, String b) {
  final ta = normalizeMerchant(a).split(' ').where((t) => t.length > 1).toSet();
  final tb = normalizeMerchant(b).split(' ').where((t) => t.length > 1).toSet();
  if (ta.isEmpty || tb.isEmpty) return 0;
  final common = ta.intersection(tb).length;
  if (common == 0) {
    // "ifoodcom" vs "ifood": one token contains the other.
    for (final x in ta) {
      for (final y in tb) {
        if (x.length >= 4 &&
            y.length >= 4 &&
            (x.contains(y) || y.contains(x))) {
          return .8;
        }
      }
    }
    return 0;
  }
  return common / (ta.length < tb.length ? ta.length : tb.length);
}

final _reserve = RegExp(r'reserva por gasto|dinheiro retirado|reserva autom',
    caseSensitive: false);
final _yield = RegExp(r'rendimento|remunera[cç][aã]o|juros sobre saldo',
    caseSensitive: false);
final _refundWords =
    RegExp(r'estorno|devolu|devolvid|cancelad|reembolso', caseSensitive: false);
final _received = RegExp(r'recebid|pix|ted|transfer', caseSensitive: false);
final _cardBill = RegExp(
    r'nu pagamentos|pagamento de fatura|pagamento da fatura|pagto fatura|pgto fatura|fatura do cart|pagamento cart[aã]o',
    caseSensitive: false);
final _iof = RegExp(r'\biof\b', caseSensitive: false);
// On the accent-free name: the whole refund word, whatever its ending.
final _refundStrip = RegExp(r'\b(estorn|devolu|devolvid|cancelad|reembols)\w*');
// Salary and benefits also say "remuneração": never a yield.
final _notYield = RegExp(
    r'sal[aá]rio|folha|pr[oó].?labore|f[eé]rias|benef[ií]cio|pagamento',
    caseSensitive: false);

/// Above this a yield is asked about instead of registered by itself.
const yieldAutoCents = 10000;

const _dayMs = 86400000;

/// Day of a bank movement in Brasília (UTC−3, no daylight saving since
/// 2019), the same on every device and in the connector.
int movementDay(DateTime at) =>
    (at.millisecondsSinceEpoch - 3 * 3600000) ~/ _dayMs;

/// Day of an entry, from its calendar date.
int entryDay(DateTime d) =>
    DateTime.utc(d.year, d.month, d.day).millisecondsSinceEpoch ~/ _dayMs;

int _cents(double v) => (v * 100).round();

/// Card bill payments in the Nexo, from the transfer legs.
List<PaymentLegs> paymentLegs(List<AppTransaction> transactions,
    Map<String, TransactionMetadata> metadata, Set<String> creditAccounts) {
  final bySource = <String, List<AppTransaction>>{};
  for (final t in transactions) {
    final source = metadata[t.id]?.source ?? '';
    if (source.startsWith('transfer:')) (bySource[source] ??= []).add(t);
  }
  return [
    for (final legs in bySource.values)
      if (legs.length == 2)
        for (final (debit, credit) in [(legs[0], legs[1]), (legs[1], legs[0])])
          if (debit.type == 'expense' &&
              credit.type == 'income' &&
              creditAccounts.contains(credit.accountId) &&
              !creditAccounts.contains(debit.accountId))
            PaymentLegs(
                debitId: debit.id,
                creditId: credit.id,
                cents: _cents(credit.amount),
                day: credit.date,
                fromAccountId: debit.accountId,
                cardId: credit.accountId)
  ];
}

class _Option {
  _Option(this.m, this.e, this.score, this.days, this.exact, this.wrong,
      this.ei, this.withIof);
  final PendingMovement m;
  final AppTransaction e;
  final int score, days, ei;
  final bool exact, wrong;
  final PendingMovement? withIof;
}

/// Decides what each pending movement is, before the person sees it.
///
/// [linkedIds]: entries already tied to a confirmed suggestion (never linked
/// twice). [ownerNames]: how the person's name shows in bank descriptions.
/// [learnedCategory]: category of past entries by normalized merchant.
/// [settled]: movements already linked to an entry (decided on an earlier
/// day) with the entry's id: the purchase an IOF belongs to is usually one.
List<Match> reconcile({
  required List<PendingMovement> pending,
  required List<AppTransaction> transactions,
  required Map<String, TransactionMetadata> metadata,
  Set<String> linkedIds = const {},
  List<String> ownerNames = const [],
  Set<String> dismissedPairs = const {},
  String? Function(PendingMovement)? learnedCategory,
  Set<String> creditAccounts = const {},
  List<PaymentLegs>? payments,
  List<(PendingMovement, String)> settled = const [],
  List<ReconcileRule> rules = const [],
  DateTime? now,
}) {
  final out = <String, Match>{};
  final used = <String>{...linkedIds};
  final clock = (now ?? DateTime.now()).millisecondsSinceEpoch;
  // A first name alone would match any namesake: name and surname only.
  final owners = [
    for (final n in ownerNames)
      if (normalizeMerchant(n).split(' ').length >= 2) normalizeMerchant(n)
  ];
  final position = {for (final (i, m) in pending.indexed) m.id: i};
  int pos(PendingMovement m) => position[m.id]!;
  bool isOut(PendingMovement m) => m.outgoing;
  int mday(PendingMovement m) => movementDay(m.occurredAt);
  List<PendingMovement> open() =>
      pending.where((m) => !out.containsKey(m.id)).toList();
  void set(PendingMovement m, Resolution r,
          {bool automatic = false,
          AppTransaction? transaction,
          PendingMovement? pair,
          int score = 0,
          String? categoryId,
          bool wrongAccount = false,
          String? from,
          String? to,
          bool waiting = false,
          String? ruleId,
          PendingMovement? withIof}) =>
      out[m.id] = Match(m, r,
          automatic: automatic,
          transaction: transaction,
          pair: pair,
          score: score,
          categoryId: categoryId,
          wrongAccount: wrongAccount,
          fromAccountId: from,
          toAccountId: to,
          waiting: waiting,
          ruleId: ruleId,
          withIof: withIof);
  bool mentionsOwner(PendingMovement m) {
    if (m.sameOwner == true) return true;
    final n = normalizeMerchant(m.words);
    // Whole words: "ana teste" is not inside "mariana testerman".
    return owners
        .any((o) => ' $n '.contains(' $o ') || textSimilarity(n, o) >= .99);
  }

  bool thirdParty(PendingMovement m) =>
      normalizeMerchant(m.words).isNotEmpty && !mentionsOwner(m);
  bool recent(PendingMovement m) =>
      clock - m.occurredAt.millisecondsSinceEpoch < 2 * _dayMs;
  final byId = {for (final t in transactions) t.id: t};

  // 1. Reserve moves and yields: never spending. A yield already typed by
  // hand is linked, never registered again; a large one is asked about.
  for (final m in pending) {
    if (_reserve.hasMatch(m.description)) {
      set(m, Resolution.reserve, automatic: true);
    } else if (!isOut(m) &&
        _yield.hasMatch(m.description) &&
        !_notYield.hasMatch(m.description)) {
      final twins = [
        for (final (i, e) in transactions.indexed)
          if (e.type == 'income' &&
              _cents(e.amount) == m.amountCents &&
              !used.contains(e.id) &&
              (entryDay(e.date) - mday(m)).abs() <= 3 &&
              !(metadata[e.id]?.source ?? '').startsWith('transfer:') &&
              (metadata[e.id]?.source ?? '') != 'opening_balance' &&
              (m.nexoAccountId == null || e.accountId == m.nexoAccountId))
            (i, e)
      ]..sort((a, b) {
          final c = (entryDay(a.$2.date) - mday(m)).abs() -
              (entryDay(b.$2.date) - mday(m)).abs();
          return c != 0 ? c : a.$1 - b.$1;
        });
      if (twins.isNotEmpty) {
        used.add(twins.first.$2.id);
        set(m, Resolution.linked,
            automatic: true, transaction: twins.first.$2, score: 100);
      } else {
        set(m, Resolution.yieldIncome,
            automatic: m.amountCents <= yieldAutoCents);
      }
    }
  }

  // 2. A payment and its refund: the bank's operation id, or refund words
  // from the same merchant within 30 days, or the same merchant giving the
  // money back the same day.
  for (final paid in open().where(isOut)) {
    if (out.containsKey(paid.id)) continue;
    final backs = open()
        .where((b) =>
            !isOut(b) &&
            !out.containsKey(b.id) &&
            b.amountCents == paid.amountCents &&
            (b.accountId ?? '') == (paid.accountId ?? '') &&
            mday(b) >= mday(paid) &&
            mday(b) - mday(paid) <= 30)
        .toList()
      ..sort((a, b) {
        final c = a.occurredAt.compareTo(b.occurredAt);
        return c != 0 ? c : pos(a) - pos(b);
      });
    final byRef = backs
        .where((b) =>
            (paid.operationRef != null &&
                b.operationRef == paid.operationRef) ||
            (paid.paymentRef != null && b.paymentRef == paid.paymentRef))
        .firstOrNull;
    final byWords = backs.where((b) {
      if (!(b.kind == 'refund' || _refundWords.hasMatch(b.description))) {
        return false;
      }
      final rest = normalizeMerchant(b.description)
          .replaceAll(_refundStrip, ' ')
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim();
      if (rest.isEmpty || rest == 'dinheiro' || rest == 'valor') {
        // "Reembolso" alone: only close in time and with nothing else alike.
        return mday(b) - mday(paid) <= 7 &&
            open()
                .where((p) =>
                    p.id != paid.id &&
                    isOut(p) &&
                    p.amountCents == paid.amountCents &&
                    (mday(p) - mday(b)).abs() <= 7)
                .isEmpty;
      }
      return textSimilarity(paid.description, b.description) >= .6;
    }).firstOrNull;
    final sameDay = backs
        .where((b) =>
            mday(b) == mday(paid) &&
            textSimilarity(paid.description, b.description) >= .6 &&
            !_received.hasMatch(b.description) &&
            !mentionsOwner(b))
        .firstOrNull;
    final back = byRef ?? byWords ?? sameDay;
    if (back != null) {
      set(paid, Resolution.reversal, automatic: true, pair: back);
      set(back, Resolution.reversal, automatic: true, pair: paid);
    }
  }

  // 3. The IOF of an international purchase, charged up to 3 days later:
  // remembered with the purchase, decided with it below.
  final iofOf = <String, PendingMovement>{};
  final iofTaken = {
    for (final (m, id) in settled)
      if (_iof.hasMatch(m.description)) id
  };
  double near(double ratio) => (ratio - .035).abs();
  for (final iof in open().where((m) =>
      m.medium == 'credit' && isOut(m) && _iof.hasMatch(m.description))) {
    final purchases = open()
        .where((p) =>
            p.id != iof.id &&
            p.medium == 'credit' &&
            isOut(p) &&
            !_iof.hasMatch(p.description) &&
            !iofOf.containsKey(p.id) &&
            (p.accountId ?? '') == (iof.accountId ?? '') &&
            mday(iof) - mday(p) >= 0 &&
            mday(iof) - mday(p) <= 3 &&
            iof.amountCents / p.amountCents >= .025 &&
            iof.amountCents / p.amountCents <= .07)
        .toList()
      ..sort((a, b) {
        final c = (iof.amountCents / a.amountCents - .035)
            .abs()
            .compareTo((iof.amountCents / b.amountCents - .035).abs());
        return c != 0 ? c : pos(a) - pos(b);
      });
    if (purchases.isNotEmpty) {
      iofOf[purchases.first.id] = iof;
      continue;
    }
    // The purchase was decided on an earlier day: the IOF goes into its
    // entry, unless the entry already has it.
    final done = [
      for (final (i, (m, id)) in settled.indexed)
        if (m.medium == 'credit' &&
            m.outgoing &&
            !_iof.hasMatch(m.description) &&
            !iofTaken.contains(id) &&
            (m.accountId ?? '') == (iof.accountId ?? '') &&
            mday(iof) - mday(m) >= 0 &&
            mday(iof) - mday(m) <= 3 &&
            iof.amountCents / m.amountCents >= .025 &&
            iof.amountCents / m.amountCents <= .07)
          (i, m, id)
    ]..sort((a, b) {
        final c = near(iof.amountCents / a.$2.amountCents)
            .compareTo(near(iof.amountCents / b.$2.amountCents));
        return c != 0 ? c : a.$1 - b.$1;
      });
    if (done.isEmpty) continue;
    final (_, purchase, entryId) = done.first;
    final entry = byId[entryId];
    if (entry == null || entry.type != 'expense') continue;
    iofTaken.add(entryId);
    final cents = _cents(entry.amount);
    if ((cents - (purchase.amountCents + iof.amountCents)).abs() <= 1) {
      set(iof, Resolution.linked,
          automatic: true, transaction: entry, pair: purchase, score: 100);
    } else {
      set(iof, Resolution.iof,
          automatic: cents == purchase.amountCents,
          transaction: entry,
          pair: purchase);
    }
  }
  final iofs = {for (final m in iofOf.values) m.id};

  // 4. A card bill paid from the bank: the bank side ("Pagamento com Pix NU
  // PAGAMENTOS") and the card side ("Pagamento recebido"), tied to the
  // payment already in the Nexo when there is one.
  final cardSides = open()
      .where((m) =>
          m.medium == 'credit' &&
          !isOut(m) &&
          m.kind != 'refund' &&
          !_refundWords.hasMatch(m.description) &&
          (m.kind == 'transfer' ||
              RegExp('pagamento', caseSensitive: false)
                  .hasMatch(m.description)))
      .toList();
  final bankSides = open()
      .where((m) =>
          m.medium != 'credit' && isOut(m) && _cardBill.hasMatch(m.words))
      .toList();
  final legs = payments ?? paymentLegs(transactions, metadata, creditAccounts);
  final pairs = <(PendingMovement?, PendingMovement?)>[];
  final takenCard = <String>{};
  for (final b in bankSides) {
    final options = cardSides
        .where((x) =>
            !takenCard.contains(x.id) &&
            x.amountCents == b.amountCents &&
            (mday(x) - mday(b)).abs() <= 3)
        .toList()
      ..sort((x, y) {
        final c = (mday(x) - mday(b)).abs() - (mday(y) - mday(b)).abs();
        return c != 0 ? c : pos(x) - pos(y);
      });
    final c = options.firstOrNull;
    if (c != null) takenCard.add(c.id);
    pairs.add((b, c));
  }
  for (final c in cardSides) {
    if (!takenCard.contains(c.id)) pairs.add((null, c));
  }
  for (final (bank, card) in pairs) {
    final any = (bank ?? card)!;
    final options = legs
        .where((p) =>
            !used.contains(p.debitId) &&
            !used.contains(p.creditId) &&
            p.cents == any.amountCents &&
            (entryDay(p.day) - mday(any)).abs() <= 3 &&
            (card?.nexoAccountId == null || p.cardId == card!.nexoAccountId) &&
            (bank?.nexoAccountId == null ||
                p.fromAccountId == bank!.nexoAccountId))
        .toList()
      ..sort((p, q) {
        final c = (entryDay(p.day) - mday(any)).abs() -
            (entryDay(q.day) - mday(any)).abs();
        return c != 0 ? c : legs.indexOf(p) - legs.indexOf(q);
      });
    final leg = options.firstOrNull;
    if (leg != null) {
      used
        ..add(leg.debitId)
        ..add(leg.creditId);
      if (bank != null) {
        set(bank, Resolution.linked,
            automatic: true,
            transaction: byId[leg.debitId],
            pair: card,
            score: 100);
      }
      if (card != null) {
        set(card, Resolution.linked,
            automatic: true,
            transaction: byId[leg.creditId],
            pair: bank,
            score: 100);
      }
    } else {
      final cardId = card?.nexoAccountId ??
          (creditAccounts.length == 1 ? creditAccounts.first : null);
      final wait = !(bank != null && card != null) && recent(any);
      if (bank != null) {
        set(bank, Resolution.invoicePayment,
            pair: card, from: bank.nexoAccountId, to: cardId, waiting: wait);
      }
      if (card != null) {
        set(card, Resolution.invoicePayment,
            pair: bank, from: bank?.nexoAccountId, to: cardId, waiting: wait);
      }
    }
  }

  // 4b. Transfers already in the Nexo (made by hand or by the assistant):
  // the bank's sides are their legs. Before pairing, so nothing is
  // registered twice.
  for (final m in open()) {
    if (iofs.contains(m.id)) continue;
    if (!(mentionsOwner(m) || (m.kind == 'transfer' && !thirdParty(m)))) {
      continue;
    }
    final found = [
      for (final (i, e) in transactions.indexed)
        if ((metadata[e.id]?.source ?? '').startsWith('transfer:') &&
            !used.contains(e.id) &&
            e.type == (isOut(m) ? 'expense' : 'income') &&
            _cents(e.amount) == m.amountCents &&
            (entryDay(e.date) - mday(m)).abs() <= 3 &&
            (m.nexoAccountId == null || e.accountId == m.nexoAccountId))
          (i, e)
    ]..sort((a, b) {
        final c = (entryDay(a.$2.date) - mday(m)).abs() -
            (entryDay(b.$2.date) - mday(m)).abs();
        return c != 0 ? c : a.$1 - b.$1;
      });
    if (found.isEmpty) continue;
    final leg = found.first.$2;
    used.add(leg.id);
    if (m.nexoAccountId != null) {
      set(m, Resolution.linked, automatic: true, transaction: leg, score: 100);
    } else {
      set(m, Resolution.maybe, transaction: leg, score: 90);
    }
  }

  // 5. Money between the person's own accounts: same amount, opposite
  // directions, the same day or the next, with evidence that both sides
  // are the person (same tax number, the person's name, or two accounts
  // linked to the same Nexo account with nobody else named).
  for (final o in open().where(isOut)) {
    if (out.containsKey(o.id) || iofs.contains(o.id)) continue;
    final candidates = open()
        .where((i) =>
            !isOut(i) &&
            !out.containsKey(i.id) &&
            i.kind != 'refund' &&
            i.amountCents == o.amountCents &&
            (mday(i) - mday(o)).abs() <= 1)
        .toList()
      ..sort((a, b) {
        final c = (a.occurredAt.millisecondsSinceEpoch -
                    o.occurredAt.millisecondsSinceEpoch)
                .abs() -
            (b.occurredAt.millisecondsSinceEpoch -
                    o.occurredAt.millisecondsSinceEpoch)
                .abs();
        return c != 0 ? c : pos(a) - pos(b);
      });
    for (final i in candidates) {
      final sameNexo =
          o.nexoAccountId != null && o.nexoAccountId == i.nexoAccountId;
      // Two bank accounts, or at least one unknown (older rows, phone
      // notifications): the same known account is not a move between two.
      final apart = o.accountId == null ||
          i.accountId == null ||
          o.accountId != i.accountId;
      final owner = o.sameOwner == true ||
          i.sameOwner == true ||
          (mentionsOwner(o) && mentionsOwner(i));
      final sameName = normalizeMerchant(o.words).isNotEmpty &&
          textSimilarity(o.words, i.words) >= .99;
      final nameless = sameNexo && apart && !thirdParty(o) && !thirdParty(i);
      if (!(owner && (apart || sameNexo)) &&
          !(sameName && apart) &&
          !nameless) {
        continue;
      }
      final known = o.nexoAccountId != null && i.nexoAccountId != null;
      final proof = owner || nameless;
      if (sameNexo && proof) {
        set(o, Resolution.internal, automatic: true, pair: i);
        set(i, Resolution.internal, automatic: true, pair: o);
      } else if (known && proof) {
        set(o, Resolution.ownTransfer,
            automatic: true,
            pair: i,
            from: o.nexoAccountId,
            to: i.nexoAccountId);
        set(i, Resolution.ownTransfer,
            automatic: true,
            pair: o,
            from: o.nexoAccountId,
            to: i.nexoAccountId);
      } else {
        set(o, Resolution.ownTransfer, pair: i);
        set(i, Resolution.ownTransfer, pair: o);
      }
      break;
    }
  }

  // 6. Entries already in the Nexo: one movement, one entry, same kind,
  // close in time, best pairs first. Money to or from the person's own name
  // is never spending, so it never stands for an entry.
  final candidates = transactions.where((t) {
    final source = metadata[t.id]?.source ?? '';
    return !used.contains(t.id) &&
        !t.id.startsWith('notification:') &&
        !source.startsWith('transfer:') &&
        source != 'opening_balance';
  }).toList();
  final rest = open()
      .where((m) =>
          !iofs.contains(m.id) && m.kind != 'transfer' && !mentionsOwner(m))
      .toList();
  final options = <_Option>[];
  for (final m in rest) {
    final category = learnedCategory?.call(m);
    final iof = iofOf[m.id];
    for (final (ei, e) in candidates.indexed) {
      if ((isOut(m) ? 'expense' : 'income') != e.type) continue;
      final wrong = creditAccounts.isNotEmpty &&
          (m.medium == 'credit') != creditAccounts.contains(e.accountId);
      // Another account of the same kind is another account.
      if (m.nexoAccountId != null && e.accountId != m.nexoAccountId && !wrong) {
        continue;
      }
      final cents = _cents(e.amount);
      for (final target in iof != null
          ? [m.amountCents + iof.amountCents, m.amountCents]
          : [m.amountCents]) {
        final rel = (cents - target).abs() / (target > 0 ? target : 1);
        final days = (entryDay(e.date) - mday(m)).abs();
        if (rel > .3 || days > 7) continue;
        var s = 50 * (1 - rel / .3) +
            35 * textSimilarity(m.description, e.description) +
            15 * (1 - days / 7);
        if (category != null && category == e.categoryId) s += 25;
        final score = s.round().clamp(0, 100);
        if (score > 0) {
          options.add(_Option(m, e, score, days, cents == target, wrong, ei,
              iof != null && target != m.amountCents ? iof : null));
        }
      }
    }
  }
  options.sort((a, b) {
    var c = b.score - a.score;
    if (c == 0) c = a.days - b.days;
    if (c == 0) c = (a.withIof != null ? 0 : 1) - (b.withIof != null ? 0 : 1);
    if (c == 0) c = pos(a.m) - pos(b.m);
    if (c == 0) c = a.ei - b.ei;
    return c;
  });
  bool unique(_Option o) =>
      options.where((x) => x.m.id == o.m.id && x.exact && x.days <= 1).length ==
          1 &&
      rest
          .where((x) =>
              x.id != o.m.id &&
              x.amountCents == o.m.amountCents &&
              isOut(x) == isOut(o.m) &&
              (mday(x) - mday(o.m)).abs() <= 1)
          .isEmpty;
  for (final o in options) {
    if (out.containsKey(o.m.id) ||
        used.contains(o.e.id) ||
        dismissedPairs.contains('${o.m.id}|${o.e.id}')) {
      continue;
    }
    final similar = textSimilarity(o.m.description, o.e.description) >= .6;
    if (o.wrong ||
        !o.exact ||
        o.days > 3 ||
        !(similar || (o.days <= 1 && unique(o)))) {
      continue;
    }
    used.add(o.e.id);
    set(o.m, Resolution.linked,
        automatic: true,
        transaction: o.e,
        score: o.score < 85 ? 85 : o.score,
        withIof: o.withIof);
    if (o.withIof != null) {
      set(o.withIof!, Resolution.linked,
          automatic: true, transaction: o.e, pair: o.m, score: 85);
    }
  }

  // 7. Rules the person marked "lançar sozinho". Never over a likely
  // duplicate: a close entry with the same amount makes it a question.
  for (final m in open()) {
    if (iofs.contains(m.id)) continue;
    final text = normalizeMerchant(m.description);
    final lower = m.description.toLowerCase();
    final rule = rules.where((r) {
      final p = r.pattern.trim().toLowerCase();
      return r.auto &&
          p.length >= 3 &&
          (lower.contains(p) || (text.isNotEmpty ? text : lower).contains(p)) &&
          (r.type == 'expense'
              ? isOut(m)
              : r.type == 'income'
                  ? !isOut(m)
                  : true) &&
          (r.type != 'transfer' || r.targetAccountId != null);
    }).firstOrNull;
    if (rule == null) continue;
    final twin = options.any((o) =>
        o.m.id == m.id && o.exact && o.days <= 3 && !used.contains(o.e.id));
    if (twin) continue;
    if (rule.type == 'internal') {
      set(m, Resolution.internal, automatic: true, ruleId: rule.id);
    } else if (rule.type == 'transfer') {
      // Naming the person, the other side may still arrive from another of
      // their banks: the rule waits for it.
      final wait = mentionsOwner(m) && recent(m);
      set(m, Resolution.rule,
          automatic: m.nexoAccountId != null && !wait,
          waiting: wait,
          ruleId: rule.id,
          from: isOut(m) ? m.nexoAccountId : rule.targetAccountId,
          to: isOut(m) ? rule.targetAccountId : m.nexoAccountId);
    } else if (!mentionsOwner(m)) {
      set(m, Resolution.rule,
          automatic: m.nexoAccountId != null,
          ruleId: rule.id,
          categoryId: rule.categoryId);
    }
  }

  // Only one side seen, naming the person: money leaving to (or coming
  // from) a place that is not connected, such as a broker. Never spending;
  // the person says where it went (or a transfer rule does).
  for (final m in open()) {
    if (iofs.contains(m.id)) continue;
    if (mentionsOwner(m)) set(m, Resolution.ownName, waiting: recent(m));
  }

  // 8. Possibly already there (the person decides), or new.
  for (final o in options) {
    if (out.containsKey(o.m.id) ||
        used.contains(o.e.id) ||
        dismissedPairs.contains('${o.m.id}|${o.e.id}')) {
      continue;
    }
    final similar = textSimilarity(o.m.description, o.e.description) >= .6;
    if (o.wrong
        ? !(o.exact && o.days <= 3)
        : !(o.score >= 45 && (o.days <= 3 || similar))) {
      continue;
    }
    used.add(o.e.id);
    set(o.m, Resolution.maybe,
        transaction: o.e, score: o.score, wrongAccount: o.wrong);
  }
  for (final m in open()) {
    if (iofs.contains(m.id)) continue;
    set(m, Resolution.newEntry, categoryId: learnedCategory?.call(m));
  }

  // The IOF follows its purchase: into the same entry when the purchase is
  // already there; with the purchase when it is new.
  for (final MapEntry(key: purchaseId, value: iof) in iofOf.entries) {
    if (out.containsKey(iof.id)) continue;
    final p = out[purchaseId]!;
    final purchase = pending[position[purchaseId]!];
    if (p.resolution == Resolution.linked || p.resolution == Resolution.maybe) {
      set(iof, Resolution.iof,
          automatic: p.resolution == Resolution.linked,
          transaction: p.transaction,
          pair: purchase);
    } else {
      set(iof, Resolution.iof, pair: purchase);
    }
  }
  return [for (final m in pending) out[m.id]!];
}

/// The category most used for this merchant in past entries.
String? Function(PendingMovement) categoryFromHistory(
    List<AppTransaction> transactions,
    Map<String, TransactionMetadata> metadata) {
  final byMerchant = <String, Map<String, int>>{};
  for (final t in transactions) {
    if (FinanceRules.isNeutral(t, metadata[t.id]) || t.categoryId.isEmpty) {
      continue;
    }
    final key = '${t.type}|${normalizeMerchant(t.description)}';
    if (key.endsWith('|')) continue;
    (byMerchant[key] ??= {})
        .update(t.categoryId, (v) => v + 1, ifAbsent: () => 1);
  }
  return (m) {
    final type = m.outgoing ? 'expense' : 'income';
    final counts = byMerchant['$type|${normalizeMerchant(m.description)}'];
    if (counts == null) return null;
    return (counts.entries.toList()..sort((a, b) => b.value - a.value))
        .first
        .key;
  };
}
