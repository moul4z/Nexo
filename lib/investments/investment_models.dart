/// Operations may explicitly link to cash. All persisted portfolio money is
/// integer cents; quantities and unit prices use six decimal places.
const investmentScale = 1000000;
const investmentClasses = [
  'Ações',
  'FIIs',
  'ETFs',
  'Renda fixa',
  'Cripto',
  'Outros'
];

int? parseInvestmentQuantity(String text) {
  final value = text.trim().replaceAll(',', '.');
  if (!RegExp(r'^\d+(\.\d{1,6})?$').hasMatch(value)) return null;
  final parts = value.split('.');
  final whole = int.tryParse(parts.first);
  if (whole == null || whole > 1000000) return null;
  final units = whole * investmentScale +
      (parts.length == 1 ? 0 : int.parse(parts.last.padRight(6, '0')));
  return units > 0 && units <= 1000000000000 ? units : null;
}

/// Units a corporate event adds (desdobramento, bonificação) or takes away
/// (grupamento) from [held], all in millionths. A ratio is "from N to M":
/// desdobramento 1 para 2, grupamento 10 para 1, and bonificação of p% is
/// 100 para 100 + p. Rounded down to the millionth; a fraction the company
/// cannot deliver is sold apart and registered as a sale.
int eventUnits(int held, {required int from, required int to}) {
  if (held <= 0 || from <= 0 || to <= 0 || from == to) {
    throw const FormatException('Proporção inválida.');
  }
  return (held * to ~/ from - held).abs();
}

/// The ratio of a bonificação of [percent] (up to two decimals).
(int from, int to) bonusRatio(num percent) {
  final basis = (percent * 100).round();
  if (basis <= 0 || basis > 100000) {
    throw const FormatException('Percentual de bonificação inválido.');
  }
  return (10000, 10000 + basis);
}

/// Currencies an asset can be priced in. The portfolio adds everything up in
/// reais: a foreign operation keeps what it cost in reais on its own day.
const investmentCurrencies = ['BRL', 'USD'];

/// Country of the market, from the currency the asset trades in.
String investmentCountry(String currency) =>
    currency == 'USD' ? 'EUA' : 'Brasil';

/// One rate unit: reais per unit of the asset currency, in millionths.
const fxScale = 1000000;

/// A ticker as the person types or the broker prints it. The fractional
/// market of the B3 (BBAS3F) is the same asset as BBAS3.
String normalizeTicker(String raw, {String currency = 'BRL'}) {
  final t = raw.trim().toUpperCase();
  if (currency != 'BRL') return t;
  final m = RegExp(r'^([A-Z]{4}\d{1,2})F$').firstMatch(t);
  return m == null ? t : m.group(1)!;
}

final _tickerPattern = RegExp(r'^[A-Z0-9][A-Z0-9.\-]{0,11}$');

int roundedRatio(int a, int b, int divisor) =>
    ((BigInt.from(a) * BigInt.from(b) + BigInt.from(divisor ~/ 2)) ~/
            BigInt.from(divisor))
        .toInt();

class Investment {
  final String id, name, assetClass, ticker, institution, priceSource;
  final int priceMicros;
  final DateTime priceAt;
  final bool archived;

  /// Currency of the price and of every operation of this asset.
  final String currency;

  /// Reais per unit of [currency] when the price was last set; 1,000000 for
  /// reais. The value in reais is quantity × price × this.
  final int fxMicros;
  const Investment(
      {required this.id,
      required this.name,
      required this.assetClass,
      this.ticker = '',
      this.institution = '',
      required this.priceMicros,
      required this.priceAt,
      this.priceSource = 'manual',
      this.archived = false,
      this.currency = 'BRL',
      this.fxMicros = fxScale});
  bool get foreign => currency != 'BRL';
  String get country => investmentCountry(currency);
  bool get canQuote =>
      ['Ações', 'FIIs', 'ETFs'].contains(assetClass) && ticker.isNotEmpty;

  /// Where a quote comes from: the B3 through brapi, the United States
  /// through the Nexo server, which keeps the key.
  String get quoteSource => foreign ? 'mercado' : 'brapi';
  Investment copyWith(
          {int? priceMicros,
          DateTime? priceAt,
          String? priceSource,
          int? fxMicros}) =>
      Investment(
          id: id,
          name: name,
          assetClass: assetClass,
          ticker: ticker,
          institution: institution,
          priceMicros: priceMicros ?? this.priceMicros,
          priceAt: priceAt ?? this.priceAt,
          priceSource: priceSource ?? this.priceSource,
          archived: archived,
          currency: currency,
          fxMicros: fxMicros ?? this.fxMicros);
  Map<String, Object?> toMap() => {
        'id': id,
        'name': name,
        'asset_class': assetClass,
        'ticker': ticker,
        'institution': institution,
        'price_micros': priceMicros,
        'price_at': priceAt.toUtc().toIso8601String(),
        'price_source': priceSource,
        'archived': archived ? 1 : 0,
        'currency': currency,
        'fx_micros': fxMicros
      };
  factory Investment.fromMap(Map<String, dynamic> m) {
    final item = Investment(
        id: m['id'] as String,
        name: m['name'] as String,
        assetClass: m['asset_class'] as String,
        ticker: m['ticker'] as String,
        institution: m['institution'] as String,
        priceMicros: m['price_micros'] as int,
        priceAt: DateTime.parse(m['price_at'] as String),
        priceSource: m['price_source'] as String,
        archived: (m['archived'] as int? ?? 0) == 1,
        currency: m['currency'] as String? ?? 'BRL',
        fxMicros: m['fx_micros'] as int? ?? fxScale);
    item.validate();
    return item;
  }
  void validate() {
    if (id.isEmpty ||
        name.trim().isEmpty ||
        name.length > 120 ||
        institution.length > 120 ||
        !investmentClasses.contains(assetClass) ||
        (ticker.isNotEmpty && !_tickerPattern.hasMatch(ticker)) ||
        priceMicros < 0 ||
        priceMicros > 1000000000000 ||
        !investmentCurrencies.contains(currency) ||
        (currency == 'BRL' ? fxMicros != fxScale : fxMicros <= 0) ||
        fxMicros > 1000 * fxScale ||
        !['manual', 'entrada', 'brapi', 'mercado'].contains(priceSource)) {
      throw const FormatException('Dados do investimento inválidos.');
    }
  }
}

class InvestmentOperation {
  final String id, investmentId, kind;

  /// [cents] is in the asset currency: dollars for a US stock.
  final int quantity, cents;
  final DateTime date, createdAt;
  final String? cashAccountId;

  /// What the operation was in reais on its day, for an asset in another
  /// currency. Null for reais, where it is [cents] itself.
  final int? brlCents;

  /// Tax withheld at the source on a dividend, in the asset currency.
  /// [cents] is what arrived; the gross is the sum of both.
  final int taxCents;
  const InvestmentOperation(
      {required this.id,
      required this.investmentId,
      required this.kind,
      required this.quantity,
      required this.cents,
      required this.date,
      required this.createdAt,
      this.cashAccountId,
      this.brlCents,
      this.taxCents = 0});

  /// The operation in reais.
  int get mainCents => brlCents ?? cents;

  /// Reais per unit of the asset currency on the day, in millionths.
  int? get fxMicros => brlCents == null || cents == 0
      ? null
      : roundedRatio(brlCents!, fxScale, cents);
  String get label => switch (kind) {
        'buy' => 'Compra / aporte',
        'sell' => 'Venda / resgate',
        'opening' => 'Posição inicial',
        'split' => 'Desdobramento',
        'reverse_split' => 'Grupamento',
        'bonus' => 'Bonificação',
        _ => 'Provento recebido'
      };

  /// A corporate event: changes the quantity without money moving.
  /// Desdobramento adds units, grupamento takes them away (cost stays);
  /// bonificação adds units at the cost the company assigned to them.
  bool get isEvent => events.contains(kind);
  static const events = {'split', 'reverse_split', 'bonus'};
  static const kinds = {'buy', 'sell', 'opening', 'income', ...events};
  Map<String, Object?> toMap() => {
        'id': id,
        'investment_id': investmentId,
        'kind': kind,
        'quantity': quantity,
        'cents': cents,
        'date': date.toUtc().toIso8601String(),
        'created_at': createdAt.toUtc().toIso8601String(),
        'cash_account_id': cashAccountId,
        'brl_cents': brlCents,
        'tax_cents': taxCents
      };
  factory InvestmentOperation.fromMap(Map<String, dynamic> m) {
    final op = InvestmentOperation(
        id: m['id'] as String,
        investmentId: m['investment_id'] as String,
        kind: m['kind'] as String,
        quantity: m['quantity'] as int,
        cents: m['cents'] as int,
        date: DateTime.parse(m['date'] as String),
        createdAt: DateTime.parse(m['created_at'] as String),
        cashAccountId: m['cash_account_id'] as String?,
        brlCents: m['brl_cents'] as int?,
        taxCents: m['tax_cents'] as int? ?? 0);
    op.validate();
    return op;
  }
  void validate() {
    if (id.isEmpty ||
        investmentId.isEmpty ||
        !kinds.contains(kind) ||
        // An event moves no money: no account, and a split has no cost.
        (isEvent && (cashAccountId != null || taxCents != 0)) ||
        (kind != 'bonus' && isEvent && (cents != 0 || (brlCents ?? 0) != 0)) ||
        cents < 0 ||
        cents > 100000000000000 ||
        quantity < 0 ||
        quantity > 1000000000000 ||
        (cashAccountId != null && (cashAccountId!.isEmpty || cents == 0)) ||
        (brlCents != null && (brlCents! < 0 || brlCents! > 100000000000000)) ||
        taxCents < 0 ||
        taxCents > 100000000000000 ||
        (taxCents > 0 && kind != 'income') ||
        (kind == 'income' ? quantity != 0 || cents == 0 : quantity == 0)) {
      throw const FormatException('Operação de investimento inválida.');
    }
  }
}

/// A position in two currencies. The plain fields ([cost], [value],
/// [realized], [income], [purchases], [sales]) are in reais, so any sum of
/// positions is in reais; the `native` ones are in the asset currency.
class InvestmentPosition {
  final Investment investment;
  final List<InvestmentOperation> operations;
  int quantity = 0,
      cost = 0,
      realized = 0,
      income = 0,
      purchases = 0,
      sales = 0,
      nativeCost = 0,
      nativeRealized = 0,
      nativeIncome = 0,
      nativeTax = 0;
  InvestmentPosition(this.investment, Iterable<InvestmentOperation> entries)
      : operations = entries.toList() {
    investment.validate();
    operations.sort((a, b) {
      var c = a.date.compareTo(b.date);
      if (c == 0) c = a.createdAt.compareTo(b.createdAt);
      return c == 0 ? a.id.compareTo(b.id) : c;
    });
    final ids = <String>{};
    for (final op in operations) {
      op.validate();
      if (!ids.add(op.id) || op.investmentId != investment.id) {
        throw const FormatException('Operação duplicada ou sem investimento.');
      }
      // A foreign operation without its value in reais would make every
      // total in reais up a number.
      if (investment.foreign != (op.brlCents != null)) {
        throw const FormatException(
            'Operação em outra moeda precisa do valor em reais da data.');
      }
      if (op.isEvent && quantity == 0) {
        throw const FormatException('Não há posição nessa data.');
      }
      switch (op.kind) {
        case 'buy':
        case 'opening':
          quantity += op.quantity;
          nativeCost += op.cents;
          cost += op.mainCents;
          if (op.kind == 'buy') purchases += op.mainCents;
        case 'sell':
          if (op.quantity > quantity) {
            throw const FormatException(
                'A venda supera a quantidade disponível nessa data.');
          }
          final removedNative = roundedRatio(nativeCost, op.quantity, quantity);
          final removed = roundedRatio(cost, op.quantity, quantity);
          nativeCost -= removedNative;
          cost -= removed;
          quantity -= op.quantity;
          nativeRealized += op.cents - removedNative;
          realized += op.mainCents - removed;
          sales += op.mainCents;
        case 'income':
          nativeIncome += op.cents;
          nativeTax += op.taxCents;
          income += op.mainCents;
        case 'split':
          quantity += op.quantity;
        case 'reverse_split':
          if (op.quantity >= quantity) {
            throw const FormatException(
                'O grupamento supera a quantidade disponível nessa data.');
          }
          quantity -= op.quantity;
        case 'bonus':
          // Cost of the new units, never a contribution: no money left.
          quantity += op.quantity;
          nativeCost += op.cents;
          cost += op.mainCents;
      }
      if (quantity > 1000000000000 || cost > 100000000000000) {
        throw const FormatException('A posição excede o limite suportado.');
      }
    }
  }

  /// At the last price, in the asset currency.
  int get nativeValue =>
      roundedRatio(quantity, investment.priceMicros, 10000000000);

  /// At the last price and the rate of that day, in reais.
  int get value => investment.foreign
      ? roundedRatio(nativeValue, investment.fxMicros, fxScale)
      : nativeValue;
  int get unrealized => value - cost;
  int get result => unrealized + realized + income;

  /// Average cost per unit, in the asset currency (cents).
  int? get averageCost => quantity == 0
      ? null
      : roundedRatio(nativeCost, investmentScale, quantity);

  /// Average rate paid for the units still held, in reais per unit.
  int? get averageFx => !investment.foreign || nativeCost == 0
      ? null
      : roundedRatio(cost, fxScale, nativeCost);

  /// What the stock itself did, in reais at today's rate.
  int get priceEffect => investment.foreign
      ? roundedRatio(nativeValue - nativeCost, investment.fxMicros, fxScale)
      : unrealized;

  /// What the rate did to the money still invested: the rest of [unrealized].
  int get fxEffect => unrealized - priceEffect;

  /// Units held at the end of [day] (local), from the operations up to it.
  int heldOn(DateTime day) {
    final end = DateTime(day.year, day.month, day.day + 1);
    return InvestmentPosition(
        investment, operations.where((o) => o.date.isBefore(end))).quantity;
  }

  /// A corporate event over this position, counted from what was held at
  /// the end of [day] (the "data com"). It is dated at the very end of
  /// that day, so every trade of the day comes before it. [unitCostCents]
  /// is the cost per new unit of a bonificação, in the asset currency.
  InvestmentOperation event(
      {required String id,
      required String kind,
      required DateTime day,
      required int from,
      required int to,
      int unitCostCents = 0,
      DateTime? createdAt}) {
    if (!InvestmentOperation.events.contains(kind)) {
      throw const FormatException('Evento desconhecido.');
    }
    final grows = kind != 'reverse_split';
    if (grows ? to <= from : to >= from) {
      throw FormatException(switch (kind) {
        'split' => 'No desdobramento você fica com mais ações: 1 para 2.',
        'bonus' => 'Na bonificação você recebe ações novas.',
        _ => 'No grupamento você fica com menos ações: 10 para 1.'
      });
    }
    if (kind == 'bonus' && investment.foreign) {
      throw const FormatException(
          'Bonificação só para ativos em reais por enquanto.');
    }
    if (unitCostCents < 0 || (kind != 'bonus' && unitCostCents != 0)) {
      throw const FormatException('Custo da ação nova inválido.');
    }
    final held = heldOn(day);
    if (held == 0) throw const FormatException('Não havia posição nessa data.');
    final units = eventUnits(held, from: from, to: to);
    if (units == 0) {
      throw const FormatException('A proporção não muda a quantidade.');
    }
    final op = InvestmentOperation(
        id: id,
        investmentId: investment.id,
        kind: kind,
        quantity: units,
        cents: kind == 'bonus'
            ? roundedRatio(units, unitCostCents, investmentScale)
            : 0,
        date: DateTime(day.year, day.month, day.day, 23, 59, 59),
        createdAt: createdAt ?? DateTime.now(),
        brlCents: investment.foreign ? 0 : null);
    InvestmentPosition(investment, [...operations, op]);
    return op;
  }
}
