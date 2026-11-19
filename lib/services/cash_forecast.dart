import '../models/models.dart';
import 'billing_cycle.dart';
import 'daily_spending.dart';
import 'finance_rules.dart';
import 'transaction_metadata_service.dart';

class ForecastEvent {
  final DateTime date;
  final String title, accountId, kind, id, currency;
  final double amount; // Signed cash movement; zero for informational events.
  final DateTime? cycleEnd;

  /// The part of [amount] that is the day-to-day estimate (kind "estimate"
  /// for the account, part of an invoice for a card).
  final double estimated;
  const ForecastEvent(
      {required this.date,
      required this.title,
      required this.accountId,
      required this.kind,
      required this.id,
      required this.currency,
      required this.amount,
      this.cycleEnd,
      this.estimated = 0});
}

class CashForecast {
  final double current, projected;
  final List<ForecastEvent> events;
  final List<String> warnings;
  const CashForecast(this.current, this.projected, this.events, this.warnings);

  /// Read-only projection: does not create transactions or recalculate balances.
  static CashForecast calculate(
      {required DateTime now,
      required DateTime until,
      required List<Account> accounts,
      required List<AppTransaction> transactions,
      required List<RecurringPayment> recurring,
      required Map<String, TransactionMetadata> metadata,
      required List<Map<String, dynamic>> invoicePayments,
      required double Function(double, String) convert,
      DailySpending? daily}) {
    DateTime day(DateTime d) => DateTime(d.year, d.month, d.day);
    final end = day(until);
    final today = day(now);
    final byId = {for (final a in accounts) a.id: a};
    bool cash(Account a) =>
        !a.isGold && a.type != 'credit' && !a.excludeFromTotal;
    final current = accounts
        .where(cash)
        .fold<double>(0, (sum, a) => sum + convert(a.balance, a.currency));
    final events = <ForecastEvent>[];
    final warnings = <String>[];
    final invoices = <String,
        ({
      Account card,
      BillingCycle cycle,
      double amount,
      double estimated
    })>{};
    String key(String id, DateTime d) =>
        '$id|${d.toIso8601String().substring(0, 10)}';
    void cardPurchase(Account a, DateTime date, double amount,
        {bool estimate = false}) {
      final cycle = BillingCycle.forDate(date, a.statementDay, a.dueDay);
      if (cycle.due == null) return;
      final k = key(a.id, cycle.end);
      invoices[k] = (
        card: a,
        cycle: cycle,
        amount: (invoices[k]?.amount ?? 0) + amount,
        estimated: (invoices[k]?.estimated ?? 0) + (estimate ? amount : 0)
      );
    }

    for (final tx in transactions) {
      final a = byId[tx.accountId];
      if (a == null) continue;
      final m = metadata[tx.id] ?? TransactionMetadata(transactionId: tx.id);
      final signed = tx.type == 'income' ? tx.amount : -tx.amount;
      if (a.type == 'credit') {
        if (FinanceRules.onInvoice(tx, m)) {
          final currency = tx.currency.isEmpty ? a.currency : tx.currency;
          final rate = convert(1, a.currency);
          cardPurchase(
              a,
              tx.date,
              currency == a.currency || rate == 0
                  ? -signed
                  : convert(-signed, currency) / rate);
        }
      } else if (m.isPending && m.affectsBalance && cash(a)) {
        final date = day(m.dueDate ?? tx.date);
        if (!date.isAfter(end))
          events.add(ForecastEvent(
              date: date,
              title: tx.description,
              accountId: a.id,
              kind: 'transaction',
              id: tx.id,
              currency: tx.currency.isEmpty ? a.currency : tx.currency,
              amount: signed));
      }
    }
    final ids = transactions.map((t) => t.id).toSet();
    for (final original in recurring) {
      final a = byId[original.accountId];
      if (a == null || (!cash(a) && a.type != 'credit')) continue;
      if (original.freqVal < 1) {
        warnings.add('Revise a frequência de ${original.name}.');
        continue;
      }
      final r = RecurringPayment.fromMap(original.toMap(),
          skippedOccurrences: original.skippedOccurrences);
      if (r.hasSkippedInstallments) {
        for (final missed in r.skippedOccurrences) {
          if (day(missed.date).isAfter(end) || ids.contains(missed.id))
            continue;
          final amount =
              r.paymentType == 'income' ? missed.amount : -missed.amount;
          if (a.type == 'credit') {
            cardPurchase(a, missed.date, -amount);
          } else {
            events.add(ForecastEvent(
                date: day(missed.date),
                title: r.name,
                accountId: a.id,
                kind: 'recurring',
                id: r.id,
                currency: a.currency,
                amount: amount));
          }
        }
      }
      var count = 0;
      while (!day(r.nextDate).isAfter(end) &&
          (r.endDate == null || !day(r.nextDate).isAfter(day(r.endDate!)))) {
        if (++count > 3660) {
          warnings.add('Revise as ocorrências antigas de ${r.name}.');
          break;
        }
        final id = 'recurring:${r.id}:${r.nextDate.toIso8601String()}';
        if (!ids.contains(id)) {
          // With the IOF of a purchase abroad, when the person set one.
          final amount =
              r.paymentType == 'income' ? r.amount : -r.forecastAmount;
          if (a.type == 'credit') {
            cardPurchase(a, r.nextDate, -amount);
          } else {
            events.add(ForecastEvent(
                date: day(r.nextDate),
                title: r.name,
                accountId: a.id,
                kind: 'recurring',
                id: r.id,
                currency: a.currency,
                amount: amount));
          }
        }
        final next = r.calcNextDate();
        if (!next.isAfter(r.nextDate)) break;
        r.nextDate = next;
      }
    }
    for (final a
        in accounts.where((a) => a.type == 'credit' && !a.excludeFromTotal)) {
      if (a.dueDay == null)
        warnings
            .add('${a.name}: configure o vencimento para incluir a fatura.');
      if (a.statementDay == null)
        warnings.add('${a.name}: sem fechamento, usamos o mês civil.');
      if (a.statementDay != null) {
        final cycle = BillingCycle.forDate(today, a.statementDay, a.dueDay);
        if (!cycle.end.isAfter(end))
          events.add(ForecastEvent(
              date: cycle.end,
              title: 'Fechamento ${a.name}',
              accountId: a.id,
              kind: 'closing',
              id: a.id,
              currency: a.currency,
              amount: 0,
              cycleEnd: cycle.end));
      }
    }
    // Day-to-day spending, from tomorrow: what leaves the account on the
    // day, and what goes to each card's invoice of its cycle.
    if (daily != null) {
      for (var d = today.add(const Duration(days: 1));
          !d.isAfter(end);
          d = DateTime(d.year, d.month, d.day + 1)) {
        if (daily.cash > 0)
          events.add(ForecastEvent(
              date: d,
              title: 'Gasto do dia a dia (estimativa)',
              accountId: '',
              kind: 'estimate',
              id: 'estimate',
              currency: daily.currency,
              amount: -daily.cash,
              estimated: -daily.cash));
        for (final e in daily.cards.entries) {
          final card = byId[e.key];
          if (card != null && card.type == 'credit' && e.value > 0)
            cardPurchase(card, d, e.value, estimate: true);
        }
      }
    }
    final paid = <String, double>{};
    for (final p in invoicePayments) {
      final k = '${p['card_id']}|${p['cycle_end']}';
      paid[k] = (paid[k] ?? 0) + (p['amount'] as num).toDouble();
    }
    for (final entry in invoices.entries) {
      final inv = entry.value;
      if (inv.card.excludeFromTotal || inv.cycle.due!.isAfter(end)) continue;
      final remaining = (inv.amount - (paid[entry.key] ?? 0))
          .clamp(0.0, double.infinity)
          .toDouble();
      if (remaining < 0.005) continue;
      final linked = byId[inv.card.linkedAccountId];
      if (linked != null && !cash(linked)) {
        warnings.add(
            '${inv.card.name}: pagamento previsto em conta fora do saldo disponível.');
        continue;
      }
      events.add(ForecastEvent(
          date: inv.cycle.due!,
          title: 'Fatura ${inv.card.name}',
          accountId: inv.card.id,
          kind: 'invoice',
          id: inv.card.id,
          currency: inv.card.currency,
          amount: -remaining,
          cycleEnd: inv.cycle.end,
          estimated: -inv.estimated.clamp(0.0, remaining).toDouble()));
    }
    events.sort((a, b) => a.date.compareTo(b.date));
    return CashForecast(
        current,
        current +
            events.fold<double>(
                0, (sum, e) => sum + convert(e.amount, e.currency)),
        events,
        warnings.toSet().toList());
  }

  /// How much can be spent per day, from tomorrow up to [until], without
  /// the cash going below zero on any day: the lowest balance of each day
  /// divided by the days up to it. Use the forecast without day-to-day
  /// spending. Never negative; cents rounded down.
  static double safePerDay(CashForecast base, DateTime now, DateTime until,
      double Function(double, String) convert) {
    final today = DateTime(now.year, now.month, now.day);
    final end = DateTime(until.year, until.month, until.day);
    final byDay = <DateTime, double>{};
    for (final e in base.events) {
      final d = e.date.isBefore(today) ? today : e.date;
      byDay[d] = (byDay[d] ?? 0) + convert(e.amount, e.currency);
    }
    var balance = base.current + (byDay[today] ?? 0);
    double? safe;
    var n = 0;
    for (var d = today.add(const Duration(days: 1));
        !d.isAfter(end);
        d = DateTime(d.year, d.month, d.day + 1)) {
      balance += byDay[d] ?? 0;
      final perDay = balance / ++n;
      if (safe == null || perDay < safe) safe = perDay;
    }
    if (safe == null || safe <= 0) return 0;
    return (safe * 100 + 1e-6).floor() / 100;
  }
}
