import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../database/db_helper.dart';
import '../investments/investment_models.dart';
import '../investments/investment_repository.dart';
import '../models/models.dart';
import '../providers/app_provider.dart';
import '../services/bank_snapshots.dart';
import '../services/balance_check.dart';
import '../services/cash_forecast.dart';
import '../services/cash_simulation.dart';
import '../services/daily_spending.dart';
import '../theme/app_theme.dart';
import '../utils/finance_input.dart';
import '../widgets/nexo_ui.dart';

/// "What if": the cash forecast with hypothetical events (a purchase, a
/// sale, paying only part of an invoice). Nothing is recorded here.
class SimulateScreen extends StatefulWidget {
  const SimulateScreen({super.key});
  @override
  State<SimulateScreen> createState() => _SimulateScreenState();
}

const _kinds = {
  'expense': 'Saída',
  'income': 'Entrada',
  'sell_asset': 'Venda de bem',
  'sell_investment': 'Venda de investimento',
  'partial_invoice': 'Pagar só parte da fatura',
};

class _SimulateScreenState extends State<SimulateScreen> {
  int _days = 60;
  bool _withDaily = false;
  final _events = <SimEvent>[];
  List<InvestmentPosition> _positions = const [];
  List<BankAccountSnapshot> _bank = const [];
  late final Future<List<Map<String, dynamic>>> _payments =
      DBHelper.database.then((db) => db.query('card_invoice_payments'));

  @override
  void initState() {
    super.initState();
    InvestmentRepository().load().then((p) {
      if (mounted) setState(() => _positions = p);
    }, onError: (_) {});
    BankSnapshots.load().then((b) {
      if (mounted) setState(() => _bank = b);
    });
  }

  Future<void> _add(AppProvider app, CashForecast base) async {
    final e = await showModalBottomSheet<SimEvent>(
        context: context,
        isScrollControlled: true,
        builder: (_) => _EventSheet(
            app: app, base: base, positions: _positions, bank: _bank));
    if (e != null && mounted) setState(() => _events.add(e));
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppProvider>();
    final theme = Theme.of(context);
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final until = today.add(Duration(days: _days));
    String money(double v) => app.settings.hideBalance
        ? '••••'
        : formatAmount(v, app.settings.currency);
    return Scaffold(
      appBar: AppBar(title: const Text('Simular')),
      body: FutureBuilder<List<Map<String, dynamic>>>(
          future: _payments,
          builder: (context, snapshot) {
            if (snapshot.hasError) {
              return const Center(
                  child: Text('Não foi possível carregar a previsão.'));
            }
            if (!snapshot.hasData) {
              return const Center(child: CircularProgressIndicator());
            }
            final daily = _withDaily
                ? DailySpending.average(
                    now: now,
                    accounts: app.accounts,
                    transactions: app.transactions,
                    metadata: app.transactionMetadata,
                    currency: app.settings.currency,
                    convert: app.convertToMain)
                : null;
            final base = CashForecast.calculate(
                now: now,
                until: until,
                accounts: app.accounts,
                transactions: app.transactions,
                recurring: app.recurring,
                metadata: app.transactionMetadata,
                invoicePayments: snapshot.data!,
                convert: app.convertToMain,
                daily: daily);
            final sim = CashSimulation.run(
                base: base,
                events: _events,
                now: now,
                until: until,
                accounts: app.accounts,
                convert: app.convertToMain);
            final low = sim.after;
            final error = theme.colorScheme.error;
            return ListView(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
                children: [
                  Text(
                      'Teste uma compra, uma venda ou pagar só parte da fatura antes de decidir. Nada é gravado.',
                      style: theme.textTheme.bodyMedium),
                  const SizedBox(height: 8),
                  NexoChipRow(children: [
                    for (final d in const [30, 60, 90, 180])
                      ChoiceChip(
                          label: Text('$d dias'),
                          selected: _days == d,
                          onSelected: (_) => setState(() => _days = d))
                  ]),
                  SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      value: _withDaily,
                      onChanged: (v) => setState(() => _withDaily = v),
                      title: const Text('Incluir o gasto do dia a dia'),
                      subtitle: const Text(
                          'Estimativa pela média das últimas 4 semanas.')),
                  NexoCard(
                      child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                        Text('Até ${ptDate(until)}',
                            style: theme.textTheme.titleMedium),
                        const SizedBox(height: 8),
                        Text('Saldo hoje: ${money(base.current)}'),
                        Text(
                            'Sem os eventos: termina em ${money(sim.before.end)}; o menor saldo é ${money(sim.before.lowest)} em ${ptDate(sim.before.lowestDate)}.'),
                        if (_events.isNotEmpty) ...[
                          const SizedBox(height: 8),
                          Text(
                              'Com os eventos: termina em ${money(low.end)}; o menor saldo é ${money(low.lowest)} em ${ptDate(low.lowestDate)}.',
                              style: TextStyle(
                                  fontWeight: FontWeight.w600,
                                  color: low.lowest < 0 ? error : null)),
                          if (sim.missing > 0)
                            Text(
                                'Faltariam ${money(sim.missing)} em ${ptDate(low.lowestDate)}.',
                                style: TextStyle(color: error)),
                        ],
                      ])),
                  const SizedBox(height: 12),
                  Row(children: [
                    Expanded(
                        child:
                            Text('Eventos', style: theme.textTheme.titleSmall)),
                    FilledButton.tonalIcon(
                        onPressed:
                            _events.length >= 20 ? null : () => _add(app, base),
                        icon: const Icon(Icons.add),
                        label: const Text('Adicionar')),
                  ]),
                  if (_events.isEmpty)
                    const Padding(
                        padding: EdgeInsets.symmetric(vertical: 12),
                        child: Text(
                            'Nenhum evento ainda. Adicione uma saída, uma entrada, uma venda ou um pagamento parcial de fatura.')),
                  for (final (i, e) in _events.indexed)
                    ListTile(
                        contentPadding: EdgeInsets.zero,
                        title:
                            Text(e.label.isEmpty ? _kinds[e.kind]! : e.label),
                        subtitle: Text(
                            '${_kinds[e.kind]} · ${money(e.amount)}${e.date == null ? '' : ' · ${ptDate(e.date!)}'}'),
                        trailing: IconButton(
                            tooltip: 'Tirar',
                            icon: const Icon(Icons.close),
                            onPressed: () =>
                                setState(() => _events.removeAt(i)))),
                  if (sim.added.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Text('O que muda no caixa',
                        style: theme.textTheme.titleSmall),
                    for (final a in sim.added)
                      ListTile(
                          contentPadding: EdgeInsets.zero,
                          dense: true,
                          title: Text(a.what),
                          subtitle: Text(ptDate(a.date)),
                          trailing: Text(
                              '${a.amount >= 0 ? '+' : '−'} ${money(a.amount.abs())}${a.estimated != 0 ? '\n(${money(a.estimated.abs())} estimado)' : ''}',
                              textAlign: TextAlign.end)),
                  ],
                  for (final w in sim.warnings)
                    Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: Text(w, style: theme.textTheme.bodySmall)),
                  const SizedBox(height: 12),
                  Text(
                      'Venda de investimento cai na liquidação: ações, FIIs e ETFs em 2 dias úteis; renda fixa no mesmo dia útil. No pagamento parcial, o resto vai para a fatura seguinte com um mês de juros do rotativo pela taxa do cartão (estimativa, sem IOF e encargos). Pela Lei 14.690/2023, juros e encargos do rotativo não passam do valor original da dívida.',
                      style: theme.textTheme.bodySmall),
                ]);
          }),
    );
  }
}

class _EventSheet extends StatefulWidget {
  const _EventSheet(
      {required this.app,
      required this.base,
      required this.positions,
      required this.bank});
  final AppProvider app;
  final CashForecast base;
  final List<InvestmentPosition> positions;
  final List<BankAccountSnapshot> bank;
  @override
  State<_EventSheet> createState() => _EventSheetState();
}

class _EventSheetState extends State<_EventSheet> {
  final _amount = TextEditingController();
  final _label = TextEditingController();
  String _kind = 'expense';
  DateTime? _date;
  String? _investment;
  String? _card;
  String? _error;

  @override
  void dispose() {
    _amount.dispose();
    _label.dispose();
    super.dispose();
  }

  List<Account> get _cards =>
      widget.app.accounts.where((a) => a.type == 'credit').toList();

  /// The first invoice of the card in the forecast, if any.
  ForecastEvent? _bill(String cardId) => widget.base.events
      .where((e) => e.kind == 'invoice' && e.id == cardId)
      .firstOrNull;

  void _minimum() {
    final card = widget.app.accountById(_card ?? '');
    final bill = card == null ? null : _bill(card.id);
    if (card == null || bill == null) return;
    final owed = widget.app.convertToMain(-bill.amount, bill.currency);
    final min = CashSimulation.minimumFor(card, owed,
        bankCents:
            BankSnapshots.linkedTo(widget.bank, card.id)?.minimumPaymentCents);
    setState(() {
      if (min == null) {
        _error =
            'Sem mínimo do banco nem cadastrado no cartão. Confira na fatura.';
      } else {
        _error = null;
        _amount.text = min.toStringAsFixed(2).replaceAll('.', ',');
      }
    });
  }

  void _done() {
    final amount = parseMoney(_amount.text);
    String? error;
    if (amount == null || amount <= 0) error = 'Informe um valor.';
    if (_kind == 'sell_investment' && _investment == null) {
      error = 'Escolha o investimento.';
    }
    if (_kind == 'partial_invoice' && _card == null)
      error = 'Escolha o cartão.';
    if (error != null) {
      setState(() => _error = error);
      return;
    }
    final position = widget.positions
        .where((p) => p.investment.id == _investment)
        .firstOrNull;
    Navigator.pop(
        context,
        SimEvent(_kind, amount!,
            date: _kind == 'partial_invoice' ? null : _date,
            label: _label.text.trim().isNotEmpty
                ? _label.text.trim()
                : position != null
                    ? 'Venda de ${position.investment.name}'
                    : '',
            assetClass: position?.investment.assetClass,
            cardId: _kind == 'partial_invoice' ? _card : null));
  }

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final positions = widget.positions
        .where((p) => !p.investment.archived && p.value > 0)
        .toList();
    final bill = _card == null ? null : _bill(_card!);
    return Padding(
        padding: EdgeInsets.fromLTRB(
            16, 16, 16, 16 + MediaQuery.viewInsetsOf(context).bottom),
        child: SingleChildScrollView(
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
              Text('Adicionar evento',
                  style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 8),
              Wrap(spacing: 8, runSpacing: 4, children: [
                for (final k in _kinds.entries)
                  ChoiceChip(
                      label: Text(k.value),
                      selected: _kind == k.key,
                      onSelected: (_) => setState(() {
                            _kind = k.key;
                            _error = null;
                          }))
              ]),
              const SizedBox(height: 12),
              if (_kind == 'sell_investment')
                DropdownButtonFormField<String>(
                    isExpanded: true,
                    initialValue: _investment,
                    decoration:
                        const InputDecoration(labelText: 'Investimento'),
                    items: [
                      for (final p in positions)
                        DropdownMenuItem(
                            value: p.investment.id,
                            child: Text(p.investment.name,
                                overflow: TextOverflow.ellipsis))
                    ],
                    onChanged: (v) => setState(() => _investment = v)),
              if (_kind == 'partial_invoice') ...[
                DropdownButtonFormField<String>(
                    isExpanded: true,
                    initialValue: _card,
                    decoration: const InputDecoration(labelText: 'Cartão'),
                    items: [
                      for (final c in _cards)
                        DropdownMenuItem(value: c.id, child: Text(c.name))
                    ],
                    onChanged: (v) => setState(() => _card = v)),
                if (_card != null)
                  Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Text(bill == null
                          ? 'Nenhuma fatura deste cartão vence no período.'
                          : 'Fatura de ${ptDate(bill.date)}: ${formatAmount(-bill.amount, bill.currency)}. Informe quanto você pagaria.')),
              ],
              TextField(
                  controller: _amount,
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  decoration: InputDecoration(
                      labelText: _kind == 'partial_invoice'
                          ? 'Quanto você paga'
                          : 'Valor',
                      prefixText:
                          '${currencyInfo(widget.app.settings.currency).symbol} ')),
              if (_kind == 'partial_invoice' && bill != null)
                Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton(
                        onPressed: _minimum,
                        child: const Text('Usar o pagamento mínimo'))),
              if (_kind != 'partial_invoice') ...[
                TextField(
                    controller: _label,
                    decoration: const InputDecoration(
                        labelText: 'Descrição (opcional)')),
                const SizedBox(height: 8),
                TextButton.icon(
                    icon: const Icon(Icons.event_outlined),
                    label: Text(_date == null
                        ? (_kind == 'sell_investment' ? 'Ordem hoje' : 'Hoje')
                        : ptDate(_date!)),
                    onPressed: () async {
                      final d = await showDatePicker(
                          context: context,
                          initialDate: _date ?? now,
                          firstDate: DateTime(now.year, now.month, now.day),
                          lastDate: now.add(const Duration(days: 400)));
                      if (d != null && mounted) setState(() => _date = d);
                    }),
              ],
              if (_error != null)
                Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(_error!,
                        style: TextStyle(
                            color: Theme.of(context).colorScheme.error))),
              const SizedBox(height: 12),
              Align(
                  alignment: Alignment.centerRight,
                  child: FilledButton(
                      onPressed: _done, child: const Text('Adicionar'))),
            ])));
  }
}
