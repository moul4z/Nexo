import 'package:flutter/material.dart';
import '../widgets/nexo_ui.dart';
import 'package:provider/provider.dart';
import '../database/db_helper.dart';
import '../providers/app_provider.dart';
import '../services/cash_forecast.dart';
import '../services/daily_spending.dart';
import '../services/transaction_metadata_service.dart';
import '../theme/app_theme.dart';
import '../utils/finance_input.dart';
import 'add_transaction_screen.dart';
import 'card_invoice_screen.dart';
import 'recurring_detail_screen.dart';
import 'recurring_screen.dart' show confirmRecurringAction;
import 'dart:convert';
import '../services/agenda_ics.dart';
import '../services/file_output.dart';
import '../widgets/nexo_month_grid.dart';
import '../utils/snackbar.dart';
import 'dart:typed_data';

class AgendaScreen extends StatefulWidget {
  final int initialDays;
  const AgendaScreen({super.key, this.initialDays = 7})
      : assert(initialDays == -1 || initialDays >= 0 && initialDays <= 90);
  @override
  State<AgendaScreen> createState() => _AgendaScreenState();
}

class _AgendaScreenState extends State<AgendaScreen> {
  late int _days = widget.initialDays;

  /// In the month grid, the day the person tapped (null = all days).
  DateTime? _day;

  /// Day-to-day spending (average of four weeks) as an estimate.
  bool _withDaily = false;

  Map<DateTime, DayLoad> _loads(List<ForecastEvent> events) {
    final loads = <DateTime, DayLoad>{};
    for (final e in events) {
      if (e.kind == 'closing' || e.kind == 'estimate') continue;
      final k = NexoMonthGrid.dayKey(e.date);
      loads[k] = (loads[k] ?? const DayLoad()).add(e.amount);
    }
    return loads;
  }

  bool _visible(ForecastEvent e) =>
      e.kind != 'estimate' &&
      (_days != -2 ||
          _day == null ||
          NexoMonthGrid.dayKey(e.date) == NexoMonthGrid.dayKey(_day!));

  Future<void> _exportIcs(List<ForecastEvent> events, AppProvider app) async {
    final ics = AgendaIcs.build(
        events.where((e) => e.kind != 'estimate').toList(),
        money: formatAmount,
        accountName: (id) => app.accountById(id)?.name ?? '');
    try {
      final path = await FileOutput.save(
          title: 'Agenda do Nexo',
          name: 'nexo-agenda',
          extension: 'ics',
          bytes: Uint8List.fromList(utf8.encode(ics)));
      if (!mounted) return;
      showAppSnackbar(context,
          path == null ? 'Exportação cancelada.' : 'Agenda salva: $path');
    } catch (e) {
      if (mounted) showAppSnackbar(context, 'Não foi possível salvar: $e');
    }
  }

  bool _busy = false;
  Future<List<Map<String, dynamic>>> _payments() async =>
      (await DBHelper.database).query('card_invoice_payments');

  Future<void> _act(ForecastEvent event, String action) async {
    final app = context.read<AppProvider>();
    if (action == 'edit') {
      Widget? page;
      if (event.kind == 'transaction') {
        final tx = app.transactions.where((t) => t.id == event.id).firstOrNull;
        if (tx != null)
          page = AddTransactionScreen(existing: tx, initialType: tx.type);
      } else if (event.kind == 'recurring') {
        final r = app.recurring.where((r) => r.id == event.id).firstOrNull;
        if (r != null)
          page = RecurringDetailScreen(
              recurring: r, fmt: (v) => formatAmount(v, event.currency));
      } else {
        page = CardInvoiceScreen(
            cardId: event.id, initialCycleEnd: event.cycleEnd);
      }
      if (page != null)
        await Navigator.push(context, MaterialPageRoute(builder: (_) => page!));
      if (mounted) setState(() {});
      return;
    }
    // Paying a recurring asks the same as the Recorrentes screen, including
    // "já foi paga" when an entry already looks like it.
    if (event.kind == 'recurring' && action != 'skip') {
      final r = app.recurring.where((r) => r.id == event.id).firstOrNull;
      if (r == null ||
          r.nextActionDate.year != event.date.year ||
          r.nextActionDate.month != event.date.month ||
          r.nextActionDate.day != event.date.day) return;
      await confirmRecurringAction(context, app, r);
      if (mounted) setState(() {});
      return;
    }
    final confirmed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
                title: Text(action == 'skip'
                    ? 'Pular ocorrência?'
                    : 'Confirmar pagamento ou recebimento?'),
                content: Text('${event.title}\n${ptDate(event.date)}'),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(ctx, false),
                      child: const Text('Cancelar')),
                  FilledButton(
                      onPressed: () => Navigator.pop(ctx, true),
                      child: const Text('Confirmar'))
                ]));
    if (confirmed != true || !mounted) return;
    setState(() => _busy = true);
    try {
      if (event.kind == 'recurring') {
        final r = app.recurring.firstWhere((r) => r.id == event.id);
        if (r.nextActionDate.year != event.date.year ||
            r.nextActionDate.month != event.date.month ||
            r.nextActionDate.day != event.date.day) return;
        if (action == 'skip') {
          await app.skipNextRecurring(r);
        } else {
          await app.markRecurringPaid(r);
        }
      } else {
        final tx = app.transactions.firstWhere((t) => t.id == event.id);
        final meta = app.transactionMetadata[tx.id] ??
            TransactionMetadata(transactionId: tx.id);
        if (meta.isPending)
          await app.updateTransaction(tx, tx,
              metadata: TransactionMetadata.fromMap(
                  {...meta.toMap(), 'status': 'paid'}));
      }
    } catch (_) {
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text(
                'Não foi possível concluir. Revise o lançamento e tente novamente.')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppProvider>();
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final until = _days == -1 || _days == -2
        ? DateTime(now.year, now.month + 1, 0)
        : today.add(Duration(days: _days));
    String money(double v) => app.settings.hideBalance
        ? '••••'
        : formatAmount(v, app.settings.currency);
    return Scaffold(
        appBar: AppBar(title: const Text('Agenda e previsão')),
        body: FutureBuilder<List<Map<String, dynamic>>>(
            future: _payments(),
            builder: (context, snapshot) {
              if (snapshot.hasError)
                return const Center(
                    child: Text(
                        'Não foi possível carregar a previsão. Reabra a agenda.'));
              if (!snapshot.hasData)
                return const Center(child: CircularProgressIndicator());
              CashForecast calculate(DailySpending? daily) =>
                  CashForecast.calculate(
                      now: now,
                      until: until,
                      accounts: app.accounts,
                      transactions: app.transactions,
                      recurring: app.recurring,
                      metadata: app.transactionMetadata,
                      invoicePayments: snapshot.data!,
                      convert: app.convertToMain,
                      daily: daily);
              final base = calculate(null);
              final daily = _withDaily
                  ? DailySpending.average(
                      now: now,
                      accounts: app.accounts,
                      transactions: app.transactions,
                      metadata: app.transactionMetadata,
                      currency: app.settings.currency,
                      convert: app.convertToMain)
                  : null;
              final forecast = daily == null ? base : calculate(daily);
              final safe = until.isAfter(today)
                  ? CashForecast.safePerDay(base, now, until, app.convertToMain)
                  : null;
              final cardsPerDay = daily?.cards.entries.fold<double>(
                      0,
                      (s, e) =>
                          s +
                          app.convertToMain(
                              e.value,
                              app.accountById(e.key)?.currency ??
                                  app.settings.currency)) ??
                  0;
              return ListView(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
                  children: [
                    NexoChipRow(children: [
                      for (final e in {
                        0: 'Hoje',
                        7: '7 dias',
                        15: '15 dias',
                        30: '30 dias',
                        90: '90 dias',
                        -1: 'Este mês',
                        -2: 'Mês em grade'
                      }.entries)
                        ChoiceChip(
                            label: Text(e.value),
                            selected: _days == e.key,
                            onSelected: _busy
                                ? null
                                : (_) => setState(() => _days = e.key))
                    ]),
                    Card(
                        child: Padding(
                            padding: const EdgeInsets.all(16),
                            child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                      'Saldo atual: ${money(forecast.current)}'),
                                  const SizedBox(height: 8),
                                  Text('Previsto até ${ptDate(until)}',
                                      style: Theme.of(context)
                                          .textTheme
                                          .titleMedium),
                                  FittedBox(
                                      fit: BoxFit.scaleDown,
                                      alignment: Alignment.centerLeft,
                                      child: Text(money(forecast.projected),
                                          style: Theme.of(context)
                                              .textTheme
                                              .headlineSmall
                                              ?.copyWith(
                                                  fontFeatures:
                                                      NexoTones.figures,
                                                  color: forecast.projected < 0
                                                      ? Theme.of(context)
                                                          .colorScheme
                                                          .error
                                                      : null))),
                                  if (safe != null) ...[
                                    const SizedBox(height: 8),
                                    Text(
                                        safe > 0
                                            ? 'Para não ficar negativo até ${ptDate(until)}: até ${money(safe)} por dia, a partir de amanhã.'
                                            : 'Os compromissos já passam do saldo antes de ${ptDate(until)}: não sobra para o dia a dia.',
                                        style: Theme.of(context)
                                            .textTheme
                                            .bodyMedium),
                                  ],
                                  SwitchListTile(
                                      contentPadding: EdgeInsets.zero,
                                      value: _withDaily,
                                      onChanged: until.isAfter(today)
                                          ? (v) =>
                                              setState(() => _withDaily = v)
                                          : null,
                                      title: const Text(
                                          'Incluir o gasto do dia a dia'),
                                      subtitle: Text(daily == null
                                          ? 'Estimativa pela média das últimas 4 semanas.'
                                          : 'Estimativa: ${money(daily.cash)} por dia na conta e ${money(cardsPerDay)} no cartão (média de 4 semanas, sem recorrentes, parcelas e gastos pontuais).')),
                                  const ExpansionTile(
                                      tilePadding: EdgeInsets.zero,
                                      title: Text('Como calculamos'),
                                      children: [
                                        Text(
                                            'Saldo atual + receitas previstas − compromissos cadastrados, incluindo atrasados e faturas após pagamentos parciais. O gasto do dia a dia só entra se você ligar a opção acima, como estimativa: o da conta sai todo dia e o do cartão entra na fatura do ciclo. O valor por dia é o menor saldo de cada dia dividido pelos dias até ele, sem o gasto do dia a dia. Usa as cotações disponíveis no app; não é dinheiro disponível.')
                                      ]),
                                  for (final warning in forecast.warnings)
                                    Padding(
                                        padding: const EdgeInsets.only(top: 8),
                                        child: Text(warning)),
                                ]))),
                    if (_days == -2) ...[
                      const SizedBox(height: 8),
                      NexoMonthGrid(
                          month: today,
                          loads: _loads(forecast.events),
                          money: money,
                          today: today,
                          selected: _day,
                          hidden: app.settings.hideBalance,
                          onDay: (d) =>
                              setState(() => _day = _day == d ? null : d)),
                      const SizedBox(height: 6),
                      Text(
                          _day == null
                              ? 'Toque em um dia para ver só o que vence nele.'
                              : 'Mostrando ${ptDate(_day!)}. Toque de novo para ver o mês.',
                          style: Theme.of(context).textTheme.bodySmall),
                    ],
                    Align(
                        alignment: Alignment.centerLeft,
                        child: TextButton.icon(
                            onPressed: forecast.events.isEmpty || _busy
                                ? null
                                : () => _exportIcs(forecast.events, app),
                            icon: const Icon(Icons.calendar_month_outlined),
                            label: const Text(
                                'Exportar para o calendário (.ics)'))),
                    if (forecast.events.isEmpty)
                      const Padding(
                          padding: EdgeInsets.all(24),
                          child: Text('Nenhum compromisso neste período.')),
                    for (final event in forecast.events.where(_visible))
                      Card(
                          child: Padding(
                              padding: const EdgeInsets.all(12),
                              child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                        '${ptDate(event.date)}${event.date.isBefore(today) ? ' • Atrasado' : ''}',
                                        style: TextStyle(
                                            color: event.date.isBefore(today)
                                                ? Theme.of(context)
                                                    .colorScheme
                                                    .error
                                                : null)),
                                    Text(event.title,
                                        style: Theme.of(context)
                                            .textTheme
                                            .titleMedium),
                                    Text(app
                                            .accountById(event.accountId)
                                            ?.name ??
                                        ''),
                                    if (event.kind != 'closing')
                                      Text(app.settings.hideBalance
                                          ? '••••'
                                          : '${event.amount >= 0 ? '+' : '−'} ${formatAmount(event.amount.abs(), event.currency)}${event.estimated != 0 ? ' (inclui ${formatAmount(event.estimated.abs(), event.currency)} estimado)' : ''}'),
                                    Wrap(spacing: 8, children: [
                                      TextButton(
                                          onPressed: _busy
                                              ? null
                                              : () => _act(event, 'edit'),
                                          child: Text(event.kind == 'invoice' ||
                                                  event.kind == 'closing'
                                              ? 'Ver fatura'
                                              : 'Editar / detalhes')),
                                      if (event.kind == 'transaction' ||
                                          (event.kind == 'recurring' &&
                                              app.recurring.any((r) =>
                                                  r.id == event.id &&
                                                  r.nextActionDate.year ==
                                                      event.date.year &&
                                                  r.nextActionDate.month ==
                                                      event.date.month &&
                                                  r.nextActionDate.day ==
                                                      event.date.day))) ...[
                                        TextButton(
                                            onPressed: _busy
                                                ? null
                                                : () => _act(event, 'pay'),
                                            child: Text(event.amount >= 0
                                                ? 'Receber'
                                                : 'Pagar')),
                                        if (event.kind == 'recurring' &&
                                            app.recurring.any((r) =>
                                                r.id == event.id && r.canSkip))
                                          TextButton(
                                              onPressed: _busy
                                                  ? null
                                                  : () => _act(event, 'skip'),
                                              child: const Text('Pular')),
                                      ],
                                    ])
                                  ]))),
                  ]);
            }));
  }
}
