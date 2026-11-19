import '../models/models.dart';
import 'billing_cycle.dart';
import 'cash_forecast.dart';
import 'liquidity.dart';

/// A hypothetical event for the simulator. Nothing is recorded.
class SimEvent {
  /// income | expense | sell_asset | sell_investment | partial_invoice
  final String kind;

  /// Day of the event (late days count today); for a sale, the order day.
  final DateTime? date;

  /// Positive, in the main currency. For partial_invoice, what is paid.
  final double amount;
  final String label;

  /// sell_investment: the kind of asset ("Ações", "Renda fixa"…).
  final String? assetClass;

  /// partial_invoice: the card.
  final String? cardId;

  const SimEvent(this.kind, this.amount,
      {this.date, this.label = '', this.assetClass, this.cardId});
}

class SimItem {
  final DateTime date;
  final String what;

  /// Signed, in the main currency.
  final double amount;

  /// The part of [amount] that is an estimate (signed).
  final double estimated;
  const SimItem(this.date, this.what, this.amount, {this.estimated = 0});
}

/// The cash day by day: the end of each day, the lowest one and when.
class CashWalk {
  final double end, lowest;
  final DateTime lowestDate;
  final List<(DateTime, double)> days;
  const CashWalk(this.end, this.lowest, this.lowestDate, this.days);
}

/// "What if": the forecast with hypothetical events, same rule as
/// simulate_cash in the connector (supabase/functions/nexo-mcp/cash.ts) and
/// the cases in test/fixtures/forecast_cases.json. Pure: nothing is saved.
class CashSimulation {
  final CashWalk before, after;
  final List<SimItem> added;
  final List<String> warnings;
  const CashSimulation(this.before, this.after, this.added, this.warnings);

  /// How much would be missing on the lowest day.
  double get missing => after.lowest < 0 ? -after.lowest : 0;

  static DateTime _day(DateTime d) => DateTime(d.year, d.month, d.day);
  static int _cents(double v) => (v * 100).round();

  /// What the card asks as the minimum: the bank's number when there is
  /// one, else the minimum entered for the card.
  static double? minimumFor(Account card, double owed, {int? bankCents}) {
    if (bankCents != null) return bankCents / 100;
    if (card.minPaymentAmount != null) return card.minPaymentAmount;
    final p = card.minPaymentPercent;
    return p == null ? null : (owed * p).roundToDouble() / 100;
  }

  static CashSimulation run(
      {required CashForecast base,
      required List<SimEvent> events,
      required DateTime now,
      required DateTime until,
      required List<Account> accounts,
      required double Function(double, String) convert,
      SettlementRule rule = const SettlementRule()}) {
    final today = _day(now);
    final end = _day(until);
    DateTime on(DateTime? d) =>
        d == null || _day(d).isBefore(today) ? today : _day(d);
    String money(int cents) =>
        'R\$ ${(cents / 100).toStringAsFixed(2).replaceAll('.', ',')}';
    // The base forecast in cents of the main currency; late days count today.
    final items = <(DateTime, int, ForecastEvent?)>[
      for (final e in base.events)
        if (e.amount != 0)
          (on(e.date), _cents(convert(e.amount, e.currency)), e)
    ];
    final added = <(DateTime, int, int, String)>[];
    final warnings = <String>[];
    final byId = {for (final a in accounts) a.id: a};
    for (final e in events) {
      final amount = _cents(e.amount);
      final label = e.label.trim();
      switch (e.kind) {
        case 'income':
        case 'expense':
        case 'sell_asset':
          final d = on(e.date);
          if (d.isAfter(end)) {
            warnings.add(
                '${label.isEmpty ? 'Evento' : label}: depois da data da simulação.');
            continue;
          }
          added.add((
            d,
            e.kind == 'expense' ? -amount : amount,
            0,
            label.isNotEmpty
                ? label
                : e.kind == 'expense'
                    ? 'Saída simulada'
                    : e.kind == 'sell_asset'
                        ? 'Venda de bem simulada'
                        : 'Entrada simulada'
          ));
        case 'sell_investment':
          final o = on(e.date);
          final d = rule.availableOn(
              e.assetClass ?? '', DateTime(o.year, o.month, o.day, 10));
          final name = label.isEmpty ? 'Venda' : label;
          if (d == null) {
            warnings.add(
                '$name: tipo de investimento sem regra de liquidação; não entrou.');
            continue;
          }
          final iso = d.toIso8601String().substring(0, 10);
          if (d.isAfter(end)) {
            warnings.add(
                '$name: o dinheiro só cai em $iso, depois da data da simulação.');
            continue;
          }
          added.add((
            d,
            amount,
            0,
            '${label.isEmpty ? 'Venda de investimento' : label} (cai em $iso)'
          ));
        case 'partial_invoice':
          final card = byId[e.cardId];
          final bill = items
              .where((i) =>
                  i.$3?.kind == 'invoice' &&
                  i.$3?.id == e.cardId &&
                  i.$3?.cycleEnd != null)
              .firstOrNull;
          if (card == null || bill == null) {
            warnings.add(
                'Pagamento parcial: nenhuma fatura deste cartão vence até a data.');
            continue;
          }
          final owed = -bill.$2;
          final left = owed - (amount < owed ? amount : owed);
          if (left <= 0) {
            warnings.add('Fatura ${card.name}: o valor paga a fatura toda.');
            continue;
          }
          added.add((
            bill.$1,
            left,
            0,
            'Fatura ${card.name}: paga ${money(owed - left)} de ${money(owed)}'
          ));
          // The rest goes to the next invoice with one month of interest
          // (never more than the debt: Lei 14.690/2023). An estimate.
          final rate = card.interestMonthlyPercent;
          if (rate == null) {
            warnings.add(
                '${card.name}: sem juros do rotativo cadastrados; a simulação não soma juros.');
          }
          final raw = (left * (rate ?? 0) / 100).round();
          final interest = raw > left ? left : raw;
          final next = BillingCycle.forDate(
                  bill.$3!.cycleEnd!, card.statementDay, card.dueDay)
              .due;
          if (next == null || next.isAfter(end)) {
            warnings.add(
                'Fatura ${card.name}: ${money(left)}${interest > 0 ? ' + ${money(interest)} de juros estimados' : ''} ficam para a fatura seguinte, fora da simulação.');
            continue;
          }
          added.add((
            _day(next),
            -(left + interest),
            -interest,
            'Resto da fatura ${card.name}${interest > 0 ? ' com ${money(interest)} de juros estimados (${rate == rate!.roundToDouble() ? rate.toStringAsFixed(0) : rate.toString().replaceAll('.', ',')}% ao mês)' : ''}'
          ));
      }
    }
    final start = _cents(base.current);
    CashWalk walk(List<(DateTime, int)> moves) {
      moves.sort((a, b) => a.$1.compareTo(b.$1));
      var running = start, lowest = start, lowestDate = today, next = 0;
      final days = <(DateTime, double)>[];
      for (var d = today;
          !d.isAfter(end);
          d = DateTime(d.year, d.month, d.day + 1)) {
        for (; next < moves.length && !moves[next].$1.isAfter(d); next++) {
          running += moves[next].$2;
        }
        if (running < lowest) {
          lowest = running;
          lowestDate = d;
        }
        days.add((d, running / 100));
      }
      return CashWalk(running / 100, lowest / 100, lowestDate, days);
    }

    final baseMoves = [for (final i in items) (i.$1, i.$2)];
    return CashSimulation(
        walk([...baseMoves]),
        walk([...baseMoves, for (final a in added) (a.$1, a.$2)]),
        [
          for (final a in added)
            SimItem(a.$1, a.$4, a.$2 / 100, estimated: a.$3 / 100)
        ],
        warnings);
  }
}
