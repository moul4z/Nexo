import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:intl/intl.dart';
import '../models/models.dart';
import '../providers/app_provider.dart';
import '../services/notification_inbox.dart';
import '../services/import_rules_service.dart';
import '../services/transaction_metadata_service.dart';
import '../utils/finance_input.dart';
import '../theme/app_theme.dart';
import '../services/notification_preferences.dart';
import '../services/pluggy_inbox.dart';
import '../services/inbox_reconciler.dart';
import '../services/inbox_writer.dart';
import '../services/reconciliation.dart';
import '../widgets/nexo_ui.dart';
import '../utils/snackbar.dart';
import '../services/category_memory.dart';
import '../services/subscription_detector.dart';
import 'recurring_screen.dart';

class NotificationInboxScreen extends StatefulWidget {
  const NotificationInboxScreen({super.key});
  @override
  State<NotificationInboxScreen> createState() =>
      _NotificationInboxScreenState();
}

class _NotificationInboxScreenState extends State<NotificationInboxScreen>
    with WidgetsBindingObserver {
  InboxState? state;
  String? error;

  /// "Os dados de hoje ainda não chegaram…" (Open Finance is daily).
  String? _freshness;

  /// Newest bank movement the server holds, across connections.
  DateTime? _lastRead;

  /// Pending purchases the bank stopped returning (out of the list).
  int _vanished = 0;
  bool _showResolved = false;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    reload();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) reload();
  }

  InboxWriter _writer({bool here = false}) =>
      AppInboxWriter(context.read<AppProvider>(),
          canCreate: here ? true : null);

  /// [createHere]: the person asked this device to register what the phone
  /// would register by itself.
  Future<void> _queue = Future.value();
  bool _acting = false;

  /// One at a time: a second request (a pull to refresh during the first
  /// read, an action that ends while another reload runs) waits its turn,
  /// so the reconciler never runs twice over the same suggestions.
  Future<void> reload({bool force = false, bool createHere = false}) {
    final run =
        _queue.then((_) => _reload(force: force, createHere: createHere));
    _queue = run.catchError((Object _) {});
    return run;
  }

  Future<void> _reload({bool force = false, bool createHere = false}) async {
    try {
      String? syncError;
      String? freshness;
      DateTime? lastRead;
      if (PluggyInbox.instance case final pluggy?) {
        final problem = await pluggy.sync(force: force);
        if (problem != null) syncError = 'Open Finance: $problem';
        try {
          final items = await pluggy.remote.items();
          freshness = todayMissing(items, DateTime.now());
          lastRead = items
              .map((i) => i.bankUpdatedAt)
              .whereType<DateTime>()
              .fold<DateTime?>(
                  null, (a, b) => a == null || b.isAfter(a) ? b : a);
        } catch (_) {
          // Only a hint: the inbox works without it.
        }
      }
      if (!mounted) return;
      final app = context.read<AppProvider>();
      final result = await InboxReconciler.run(
          pendingRows: await NotificationInbox.pending(),
          transactions: app.transactions,
          metadata: app.transactionMetadata,
          accounts: app.accounts,
          profileName: app.settings.userName,
          recurring: app.recurring,
          writer: _writer(here: createHere));
      // What the app settled leaves the assistant's queue too.
      unawaited(PluggyInbox.instance?.pushNow());
      final vanished = await NotificationInbox.vanishedCount();
      if (mounted)
        setState(() {
          state = result;
          _vanished = vanished;
          error = syncError;
          _freshness = freshness;
          _lastRead = lastRead;
        });
    } catch (_) {
      if (mounted)
        setState(() =>
            error = 'Não foi possível carregar as sugestões. Tente novamente.');
    }
  }

  Future<void> _act(Future<void> Function() action, String done,
      {Future<void> Function()? undo}) async {
    // A second tap while the first is being written does nothing.
    if (_acting) return;
    _acting = true;
    try {
      await action();
      await reload();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(done),
          action: undo == null
              ? null
              : SnackBarAction(
                  label: 'Desfazer',
                  onPressed: () async {
                    try {
                      await undo();
                      await reload();
                    } catch (_) {
                      if (mounted)
                        setState(() => error =
                            'Não foi possível desfazer. Atualize e tente novamente.');
                    }
                  })));
    } catch (_) {
      if (mounted)
        setState(() => error =
            'Não foi possível concluir. A sugestão pode já ter sido resolvida.');
    } finally {
      _acting = false;
    }
  }

  /// The bank movement is the open occurrence of [r]: the recurring is paid
  /// with the bank's amount and day. A different amount (the subscription
  /// went up) is offered as the new value, never applied alone.
  Future<void> _payRecurring(Match m, RecurringPayment r) async {
    final app = context.read<AppProvider>();
    final mv = m.movement;
    final amount = mv.amountCents / 100;
    var paid = false;
    await _act(() async {
      await app.payRecurringFromBank(r,
          suggestionId: mv.id, amount: amount, paidOn: mv.occurredAt);
      paid = true;
    }, '${r.name}: paga com o valor do banco.');
    if (!paid || !mounted || r.amount <= 0) return;
    if ((amount - r.amount).abs() / r.amount <= recurringPriceChange) return;
    final money = (double v) => formatAmount(v, 'BRL');
    final update = await showDialog<bool>(
        context: context,
        builder: (d) => AlertDialog(
                title: Text('${r.name} mudou de valor'),
                content: Text(
                    'Estava cadastrada com ${money(r.amount)} e o banco cobrou ${money(amount)}. Usar o novo valor daqui em diante?'),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(d, false),
                      child: const Text('Manter')),
                  FilledButton(
                      onPressed: () => Navigator.pop(d, true),
                      child: const Text('Usar o novo valor')),
                ]));
    if (update != true || !mounted) return;
    final current = app.recurring.where((x) => x.id == r.id).firstOrNull;
    if (current == null) return;
    await app.updateRecurring(RecurringPayment.fromMap(current.toMap(),
        skippedOccurrences: current.skippedOccurrences)
      ..amount = amount);
    if (mounted) showAppSnackbar(context, 'Valor de ${r.name} atualizado.');
  }

  Future<void> _undoIgnore(Iterable<String> ids) async {
    for (final id in ids) {
      await NotificationInbox.undoIgnore(id);
    }
    if (ids.any(PluggyInbox.isPluggy)) await PluggyInbox.instance?.pushNow();
  }

  Map<String, dynamic> _row(Match m, {PendingMovement? pair, Match? iof}) {
    final mv = m.movement;
    return {
      'id': mv.id,
      'app_id': PluggyInbox.isPluggy(mv.id) ? 'pluggy' : 'notification',
      'amount_cents': mv.amountCents,
      'description': mv.description,
      'kind': mv.kind,
      'medium': mv.medium,
      'occurred_at': mv.occurredAt.millisecondsSinceEpoch,
      'direction': mv.outgoing ? 'out' : 'in',
      'bank': mv.bank,
      'nexo_account_id': mv.nexoAccountId,
      'counterparty': mv.counterparty,
      if (pair != null) 'pair_id': pair.id,
      if (pair != null) 'pair_nexo_account_id': pair.nexoAccountId,
      if (m.fromAccountId != null) 'from_account_id': m.fromAccountId,
      if (m.toAccountId != null) 'to_account_id': m.toAccountId,
      if (iof != null) 'iof_id': iof.movement.id,
      if (iof != null) 'iof_cents': iof.movement.amountCents,
    };
  }

  Future<void> _review(Map<String, dynamic> row,
      {String? type, String? categoryId}) async {
    await Navigator.push(
        context,
        MaterialPageRoute(
            builder: (_) => SuggestionReviewScreen(
                row: row, initialType: type, suggestedCategory: categoryId)));
    await reload();
  }

  Future<void> _ownerName() async {
    final controller = TextEditingController(
        text: (await InboxReconciler.ownerNames()).join(', '));
    if (!mounted) return;
    final saved = await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
                title: const Text('Seu nome no banco'),
                content: Column(mainAxisSize: MainAxisSize.min, children: [
                  const Text(
                      'Como seu nome aparece em "Pix enviado/recebido". Serve para reconhecer dinheiro entre suas próprias contas. Fica só neste aparelho.'),
                  const SizedBox(height: 12),
                  TextField(
                      controller: controller,
                      autofocus: true,
                      decoration: const InputDecoration(
                          hintText:
                              'Nome Sobrenome (separe variações por vírgula)')),
                ]),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(c, false),
                      child: const Text('Cancelar')),
                  FilledButton(
                      onPressed: () => Navigator.pop(c, true),
                      child: const Text('Salvar')),
                ]));
    if (saved == true) {
      await InboxReconciler.setOwnerNames(controller.text.split(','));
      await reload();
    }
  }

  Future<bool> _confirmMany(int count, String what,
          {String verb = 'Ignorar',
          String body =
              'Nada é lançado nem apagado. Elas saem desta caixa e podem voltar com Desfazer.'}) async =>
      await showDialog<bool>(
          context: context,
          builder: (c) => AlertDialog(
                  title: Text('$verb $count $what?'),
                  content: Text(body),
                  actions: [
                    TextButton(
                        onPressed: () => Navigator.pop(c, false),
                        child: const Text('Cancelar')),
                    FilledButton(
                        onPressed: () => Navigator.pop(c, true),
                        child: Text(verb)),
                  ])) ==
      true;

  /// A card bill the bank saw paid: asks only what the banks did not tell.
  Future<void> _registerInvoice(Match m) async {
    final app = context.read<AppProvider>();
    final mv = m.movement;
    final bank = mv.medium == 'credit' ? m.pair : mv;
    final card = mv.medium == 'credit' ? mv : m.pair;
    var from = m.fromAccountId, to = m.toAccountId;
    final cards = app.accounts.where((a) => a.type == 'credit').toList();
    final banks = app.accounts
        .where((a) => a.type != 'credit' && !a.isGold && a.currency == 'BRL')
        .toList();
    if (cards.isEmpty || banks.isEmpty) {
      setState(() => error =
          'Cadastre o cartão e a conta de onde a fatura é paga em Contas.');
      return;
    }
    to ??= cards.length == 1 ? cards.single.id : null;
    from ??= app.accountById(to ?? '')?.linkedAccountId;
    if (from == null || to == null) {
      final picked = await showDialog<(String, String)>(
          context: context,
          builder: (c) {
            var f = from ?? banks.first.id, t = to ?? cards.first.id;
            return StatefulBuilder(
                builder: (c, set) => AlertDialog(
                        title: const Text('Pagamento da fatura'),
                        content:
                            Column(mainAxisSize: MainAxisSize.min, children: [
                          DropdownButtonFormField<String>(
                              initialValue: f,
                              isExpanded: true,
                              decoration:
                                  const InputDecoration(labelText: 'Saiu de'),
                              items: [
                                for (final a in banks)
                                  DropdownMenuItem(
                                      value: a.id, child: Text(a.name))
                              ],
                              onChanged: (v) => set(() => f = v!)),
                          DropdownButtonFormField<String>(
                              initialValue: t,
                              isExpanded: true,
                              decoration:
                                  const InputDecoration(labelText: 'Cartão'),
                              items: [
                                for (final a in cards)
                                  DropdownMenuItem(
                                      value: a.id, child: Text(a.name))
                              ],
                              onChanged: (v) => set(() => t = v!)),
                        ]),
                        actions: [
                          TextButton(
                              onPressed: () => Navigator.pop(c),
                              child: const Text('Cancelar')),
                          FilledButton(
                              onPressed: () => Navigator.pop(c, (f, t)),
                              child: const Text('Registrar')),
                        ]));
          });
      if (picked == null || !mounted) return;
      (from, to) = picked;
    }
    await _act(
        () =>
            _writer().addInvoicePayment(bank, card, fromId: from!, cardId: to!),
        'Pagamento da fatura registrado. Não conta como gasto.');
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppProvider>();
    final hidden = app.settings.hideBalance;
    String money(int cents) =>
        hidden ? '••••' : formatAmount(cents / 100, 'BRL');
    String when(DateTime d) => DateFormat('dd/MM HH:mm').format(d);
    String account(String? id) => app.accountById(id ?? '')?.name ?? '—';
    final matches = state?.matches ?? const <Match>[];
    final ids = {for (final m in matches) m.movement.id};
    bool waits(PendingMovement? p) => p != null && ids.contains(p.id);
    // The IOF of a purchase still waiting is reviewed with the purchase.
    final iofOf = {
      for (final m in matches)
        if (m.resolution == Resolution.iof && waits(m.pair)) m.pair!.id: m
    };
    final iofAlone = matches
        .where((m) => m.resolution == Resolution.iof && !waits(m.pair))
        .toList();
    final maybe =
        matches.where((m) => m.resolution == Resolution.maybe).toList();
    // One card per payment: the bank's side when both were seen.
    final invoices = matches
        .where((m) =>
            m.resolution == Resolution.invoicePayment &&
            (!waits(m.pair) || m.movement.medium != 'credit'))
        .toList();
    final ownPairs = matches
        .where((m) =>
            m.resolution == Resolution.ownTransfer &&
            (m.movement.outgoing || !waits(m.pair)))
        .toList();
    final ownSingles =
        matches.where((m) => m.resolution == Resolution.ownName).toList();
    // A recurring that no longer exists is just a new movement.
    final recurringOf = {
      for (final m in matches)
        if (m.resolution == Resolution.recurring)
          if (app.recurring.where((r) => r.id == m.recurringId).firstOrNull
              case final r?)
            m.movement.id: r
    };
    final bills = [
      for (final m in matches)
        if (recurringOf.containsKey(m.movement.id)) m
    ];
    final fresh = matches
        .where((m) =>
            (m.resolution == Resolution.recurring &&
                !recurringOf.containsKey(m.movement.id)) ||
            m.resolution == Resolution.newEntry ||
            m.resolution == Resolution.rule ||
            m.resolution == Resolution.yieldIncome)
        .toList();
    final yields = app.categories
        .where((c) =>
            c.type == 'income' &&
            (c.id == AppInboxWriter.yieldCategoryId ||
                normalizeMerchant(c.name).startsWith('rendiment')))
        .firstOrNull;
    final needs = maybe.length +
        invoices.length +
        ownPairs.length +
        ownSingles.length +
        iofAlone.length +
        bills.length +
        fresh.length;
    final resolved = state?.resolved ?? const <AutoResolved>[];
    final deferred = state?.deferred ?? const <Match>[];
    final cs = Theme.of(context).colorScheme;
    final small = Theme.of(context).textTheme.bodySmall;

    Widget movementCard(Match m,
        {List<Widget> extra = const [], Widget? hint}) {
      final mv = m.movement;
      final income = !mv.outgoing;
      final source = mv.bank ??
          (PluggyInbox.isPluggy(mv.id) ? 'Banco (Open Finance)' : 'Banco');
      return NexoCard(
          padding: const EdgeInsets.all(14),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Expanded(
                  child: Text(hidden ? 'Movimentação' : mv.description,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w600))),
              Text('${income ? '+' : '−'}${money(mv.amountCents)}',
                  style: TextStyle(
                      fontWeight: FontWeight.w600,
                      color: income
                          ? NexoTones.income(context)
                          : NexoTones.expense(context))),
            ]),
            Text(
                '$source${mv.medium == 'credit' ? ' · cartão' : ''} · ${when(mv.occurredAt)}',
                style: small),
            if (hint != null) ...[const SizedBox(height: 6), hint],
            if (m.waiting) ...[
              const SizedBox(height: 6),
              Text(
                  'O outro lado costuma chegar no dia seguinte: se chegar, o app resolve sozinho.',
                  style: small?.copyWith(color: cs.onSurfaceVariant)),
            ],
            const SizedBox(height: 8),
            Wrap(spacing: 8, runSpacing: 4, children: extra),
          ]));
    }

    return Scaffold(
        appBar: AppBar(title: const Text('Para revisar'), actions: [
          PopupMenuButton<String>(
              tooltip: 'Opções',
              onSelected: (v) async {
                if (v == 'owner') await _ownerName();
                if (v == 'auto') {
                  await InboxReconciler.setAutomatic(
                      !await InboxReconciler.automatic());
                  await reload();
                }
                if (v == 'yields') {
                  final income = !await InboxReconciler.yieldsAsIncome();
                  await InboxReconciler.setYieldsAsIncome(income);
                  await reload();
                  if (context.mounted)
                    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                        content: Text(income
                            ? 'Rendimentos do banco viram receita "Rendimentos".'
                            : 'Rendimentos do banco saem da caixa sem lançamento.')));
                }
                if (v == 'forget') {
                  await NotificationPreferences.clear();
                  if (context.mounted)
                    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                        content: Text('Contas sugeridas esquecidas.')));
                }
              },
              itemBuilder: (_) => [
                    const PopupMenuItem(
                        value: 'owner', child: Text('Seu nome no banco')),
                    const PopupMenuItem(
                        value: 'auto',
                        child: Text('Ligar/desligar conciliação automática')),
                    const PopupMenuItem(
                        value: 'yields',
                        child: Text('Rendimentos: lançar ou só ignorar')),
                    const PopupMenuItem(
                        value: 'forget',
                        child: Text('Esquecer contas sugeridas')),
                  ]),
          IconButton(
              onPressed: () => reload(force: true),
              icon: const Icon(Icons.refresh),
              tooltip: 'Atualizar')
        ]),
        body: RefreshIndicator(
          onRefresh: () => reload(force: true),
          child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
              children: [
                if (error != null)
                  Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Text(error!, style: TextStyle(color: cs.error))),
                if (_freshness != null)
                  Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Icon(Icons.schedule, size: 18, color: cs.tertiary),
                            const SizedBox(width: 6),
                            Expanded(child: Text(_freshness!)),
                          ])),
                if (_lastRead != null)
                  Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Row(children: [
                        Icon(Icons.sync, size: 18, color: cs.onSurfaceVariant),
                        const SizedBox(width: 6),
                        Expanded(
                            child: Text(
                                'Banco lido em ${DateFormat('dd/MM').format(_lastRead!)} às ${DateFormat('HH:mm').format(_lastRead!)}. A próxima leitura costuma chegar na manhã seguinte.',
                                style: TextStyle(color: cs.onSurfaceVariant))),
                      ])),
                if (state == null && error == null)
                  const LinearProgressIndicator(),
                if (state != null) ...[
                  Text(
                      needs == 0
                          ? PluggyInbox.instance == null &&
                                  resolved.isEmpty &&
                                  deferred.isEmpty
                              ? 'Nada para revisar. As movimentações chegam pelo Open Finance, com a sincronização ligada (Mais › Conexões com bancos).'
                              : 'Tudo em dia. Nada precisa de você agora.'
                          : '${ptCount(needs, 'movimentação precisa', 'movimentações precisam')} de você. O app já resolveu o que era repetitivo.',
                      style: Theme.of(context).textTheme.bodyMedium),
                  if (_vanished > 0) ...[
                    const SizedBox(height: 4),
                    Text(
                        '${ptCount(_vanished, 'compra pendente saiu', 'compras pendentes saíram')} da lista: o banco não mostra mais (cancelada?). Se voltar com outro código, o app reconhece.',
                        style: TextStyle(color: cs.onSurfaceVariant)),
                  ],
                  const SizedBox(height: 12),
                ],
                if (resolved.isNotEmpty)
                  NexoCard(
                      padding: EdgeInsets.zero,
                      child: Column(children: [
                        ListTile(
                            leading:
                                Icon(Icons.auto_awesome, color: cs.primary),
                            title: Text(
                                '${ptCount(resolved.length, 'resolvida')} automaticamente'),
                            subtitle: const Text(
                                'Já lançadas, entre suas contas, estornos, reservas e rendimentos'),
                            trailing: Icon(_showResolved
                                ? Icons.expand_less
                                : Icons.expand_more),
                            onTap: () =>
                                setState(() => _showResolved = !_showResolved)),
                        if (_showResolved)
                          for (final r in resolved.take(60))
                            ListTile(
                                dense: true,
                                title: Text(
                                    hidden ? 'Movimentação' : r.description,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis),
                                subtitle: Text(
                                    '${InboxReconciler.reasonLabel(r.reason)} · ${money(r.amountCents)}'),
                                trailing: r.undoable
                                    ? TextButton(
                                        onPressed: () => _act(
                                            () => InboxReconciler.undo(r,
                                                writer: _writer()),
                                            r.created || r.iof != null
                                                ? 'Desfeito. Voltou para a revisão.'
                                                : 'Voltou para a revisão.'),
                                        child: const Text('Desfazer'))
                                    : null),
                      ])),
                if (deferred.isNotEmpty) ...[
                  const SizedBox(height: 10),
                  NexoCard(
                      padding: const EdgeInsets.all(14),
                      child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(children: [
                              Icon(Icons.phone_android, color: cs.primary),
                              const SizedBox(width: 8),
                              Expanded(
                                  child: Text(
                                      '${ptCount(deferred.length, 'movimentação', 'movimentações')} que o celular lança sozinho',
                                      style: const TextStyle(
                                          fontWeight: FontWeight.w600))),
                            ]),
                            const SizedBox(height: 4),
                            Text(
                                'Rendimentos, transferências entre suas contas, IOF e regras. Só um aparelho lança sozinho, para nada entrar em dobro.',
                                style: small),
                            const SizedBox(height: 4),
                            for (final m in deferred.take(6))
                              Text(
                                  '• ${hidden ? 'Movimentação' : m.movement.description} · ${money(m.movement.amountCents)}',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: small),
                            if (deferred.length > 6)
                              Text('… e mais ${deferred.length - 6}',
                                  style: small),
                            const SizedBox(height: 6),
                            TextButton(
                                onPressed: () => reload(createHere: true),
                                child:
                                    const Text('Lançar agora neste aparelho')),
                          ])),
                ],
                if (maybe.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  NexoSectionTitle('Na dúvida',
                      subtitle: 'Parece um lançamento que você já fez',
                      icon: Icons.help_outline,
                      action: maybe.where((m) => !m.wrongAccount).length > 1
                          ? 'É o mesmo em todas'
                          : null, onAction: () async {
                    final all = maybe.where((m) => !m.wrongAccount).toList();
                    if (await _confirmMany(all.length, 'movimentações',
                        verb: 'Vincular',
                        body:
                            'Cada movimentação do banco fica ligada ao lançamento parecido que já existe. Nada é lançado de novo.')) {
                      await _act(() async {
                        for (final m in all) {
                          await InboxReconciler.link(
                              m.movement.id, m.transaction!.id);
                        }
                      }, '${all.length} vinculadas. Nada foi lançado de novo.');
                    }
                  }),
                  const SizedBox(height: 8),
                  for (final m in maybe)
                    Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: movementCard(m,
                            hint: Text(
                                'No Nexo: ${hidden ? 'lançamento' : m.transaction!.description} · ${hidden ? '••••' : formatAmount(m.transaction!.amount, 'BRL')} · ${DateFormat('dd/MM').format(m.transaction!.date)}',
                                style: TextStyle(color: cs.primary)),
                            extra: [
                              FilledButton.tonal(
                                  onPressed: () => _act(
                                      () => InboxReconciler.link(
                                          m.movement.id, m.transaction!.id),
                                      'Vinculado. Nada foi lançado de novo.'),
                                  child: const Text('É o mesmo')),
                              TextButton(
                                  onPressed: () => _act(
                                      () => InboxReconciler.dismissPair(
                                          m.movement.id, m.transaction!.id),
                                      'Separados.'),
                                  child: const Text('São diferentes')),
                              if (m.wrongAccount)
                                Text(
                                    m.movement.medium == 'credit'
                                        ? 'O banco viu no cartão; aqui está em uma conta.'
                                        : 'O banco viu Pix ou débito; aqui está no cartão. Confira a fatura.',
                                    style: TextStyle(
                                        color: NexoTones.warning(context))),
                            ])),
                ],
                if (invoices.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  const NexoSectionTitle('Fatura do cartão',
                      subtitle: 'Pagamento visto no banco; não é gasto',
                      icon: Icons.credit_score_outlined),
                  const SizedBox(height: 8),
                  for (final m in invoices)
                    Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: movementCard(m,
                            hint: Text(
                                m.pair != null
                                    ? 'O banco e o cartão mostram o mesmo pagamento.'
                                    : m.movement.medium == 'credit'
                                        ? 'O cartão recebeu o pagamento.'
                                        : 'Saiu da conta para pagar o cartão.',
                                style: small),
                            extra: [
                              FilledButton.tonal(
                                  onPressed: () => _registerInvoice(m),
                                  child: const Text(
                                      'Registrar pagamento da fatura')),
                              TextButton(
                                  onPressed: () {
                                    final both = [
                                      m.movement.id,
                                      if (waits(m.pair)) m.pair!.id
                                    ];
                                    _act(() => InboxReconciler.ignoreAll(both),
                                        'Ignorado.',
                                        undo: () => _undoIgnore(both));
                                  },
                                  child: const Text('Já está nos saldos')),
                            ])),
                ],
                if (ownPairs.isNotEmpty || ownSingles.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  NexoSectionTitle('Entre suas contas',
                      subtitle: 'Não é gasto nem receita',
                      icon: Icons.swap_horiz,
                      action: 'Ignorar todas', onAction: () async {
                    final all = [
                      for (final m in [...ownPairs, ...ownSingles]) ...[
                        m.movement.id,
                        if (waits(m.pair)) m.pair!.id
                      ]
                    ];
                    if (await _confirmMany(all.length, 'movimentações')) {
                      await _act(() => InboxReconciler.ignoreAll(all),
                          '${all.length} ignoradas.',
                          undo: () => _undoIgnore(all));
                    }
                  }),
                  const SizedBox(height: 8),
                  for (final m in ownPairs)
                    Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: movementCard(m,
                            hint: m.pair == null
                                ? null
                                : Text(
                                    'Com: ${hidden ? 'entrada' : m.pair!.description}${m.pair!.bank == null ? '' : ' (${m.pair!.bank})'} · ${when(m.pair!.occurredAt)}'),
                            extra: [
                              FilledButton.tonal(
                                  onPressed: () => _review(
                                      _row(m,
                                          pair: waits(m.pair) ? m.pair : null),
                                      type: 'transfer'),
                                  child: const Text('Registrar transferência')),
                              TextButton(
                                  onPressed: () {
                                    final both = [
                                      m.movement.id,
                                      if (waits(m.pair)) m.pair!.id
                                    ];
                                    _act(() => InboxReconciler.ignoreAll(both),
                                        'Ignoradas.',
                                        undo: () => _undoIgnore(both));
                                  },
                                  child: const Text('Já está nos saldos')),
                            ])),
                  for (final m in ownSingles)
                    Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: movementCard(m,
                            hint: Text(
                                m.movement.outgoing
                                    ? 'Foi para uma conta sua que o Nexo não vê (corretora, outro banco).'
                                    : 'Veio de uma conta sua que o Nexo não vê.',
                                style: small),
                            extra: [
                              FilledButton.tonal(
                                  onPressed: () =>
                                      _review(_row(m), type: 'transfer'),
                                  child: const Text('Registrar transferência')),
                              TextButton(
                                  onPressed: () => _act(
                                      () => NotificationInbox.ignore(
                                          m.movement.id),
                                      'Ignorada.',
                                      undo: () => _undoIgnore([m.movement.id])),
                                  child: const Text('Já está nos saldos')),
                            ])),
                  TextButton.icon(
                      onPressed: _ownerName,
                      icon: const Icon(Icons.badge_outlined),
                      label: const Text(
                          'Informar seu nome para reconhecer melhor')),
                ],
                if (iofAlone.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  const NexoSectionTitle('IOF de compra internacional',
                      subtitle: 'Cobrado no dia seguinte; faz parte da compra',
                      icon: Icons.public),
                  const SizedBox(height: 8),
                  for (final m in iofAlone)
                    Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: movementCard(m,
                            hint: m.transaction == null
                                ? null
                                : Text(
                                    'Compra no Nexo: ${hidden ? 'lançamento' : m.transaction!.description} · ${hidden ? '••••' : formatAmount(m.transaction!.amount, 'BRL')} · ${DateFormat('dd/MM').format(m.transaction!.date)}',
                                    style: TextStyle(color: cs.primary)),
                            extra: [
                              if (m.transaction != null) ...[
                                FilledButton.tonal(
                                    onPressed: () => _act(
                                        () => _writer().addIof(
                                            m.movement, m.transaction!.id),
                                        'IOF somado à compra.'),
                                    child: const Text('Somar à compra')),
                                TextButton(
                                    onPressed: () => _act(
                                        () => InboxReconciler.link(
                                            m.movement.id, m.transaction!.id),
                                        'Vinculado. O valor da compra não mudou.'),
                                    child: const Text('Já está incluído')),
                              ],
                              TextButton(
                                  onPressed: () => _review(_row(m),
                                      categoryId: m.categoryId),
                                  child: const Text('Lançar separado')),
                            ])),
                ],
                if (bills.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  const NexoSectionTitle('Recorrentes',
                      subtitle:
                          'O banco cobrou o que estava previsto: pagar a recorrente, sem lançamento solto',
                      icon: Icons.event_repeat),
                  const SizedBox(height: 8),
                  for (final m in bills)
                    Builder(builder: (context) {
                      final r = recurringOf[m.movement.id]!;
                      final cents = (r.amount * 100).round();
                      final due = DateFormat('dd/MM').format(r.nextDate);
                      return Padding(
                          padding: const EdgeInsets.only(bottom: 10),
                          child: movementCard(m,
                              hint: Text(
                                  'É ${r.name}, prevista para $due (${money(cents)})'
                                  '${cents == m.movement.amountCents ? '.' : '. O banco cobrou ${money(m.movement.amountCents)}.'}',
                                  style: small),
                              extra: [
                                FilledButton(
                                    onPressed: () => _payRecurring(m, r),
                                    child: const Text('Pagar a recorrente')),
                                TextButton(
                                    onPressed: () => _review(_row(m),
                                        categoryId: r.categoryId),
                                    child: const Text('Lançar separado')),
                                TextButton(
                                    onPressed: () => _act(
                                        () => InboxReconciler.ignoreAll(
                                            [m.movement.id]),
                                        'Sugestão ignorada.',
                                        undo: () =>
                                            _undoIgnore([m.movement.id])),
                                    child: const Text('Ignorar')),
                              ]));
                    }),
                ],
                if (fresh.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  NexoSectionTitle('Novas',
                      subtitle: 'Sem lançamento parecido no Nexo',
                      icon: Icons.fiber_new_outlined,
                      action: 'Ignorar todas', onAction: () async {
                    final all = [
                      for (final m in fresh) ...[
                        m.movement.id,
                        if (iofOf[m.movement.id] case final iof?)
                          iof.movement.id
                      ]
                    ];
                    if (await _confirmMany(all.length, 'sugestões')) {
                      await _act(() => InboxReconciler.ignoreAll(all),
                          '${all.length} ignoradas.',
                          undo: () => _undoIgnore(all));
                    }
                  }),
                  const SizedBox(height: 8),
                  for (final m in fresh)
                    Builder(builder: (context) {
                      final iof = iofOf[m.movement.id];
                      final transfer = m.resolution == Resolution.rule &&
                          (m.fromAccountId != null || m.toAccountId != null);
                      final isYield = m.resolution == Resolution.yieldIncome;
                      final category = isYield ? yields?.id : m.categoryId;
                      final hints = [
                        if (isYield) 'Parece rendimento do banco.',
                        if (iof != null)
                          'Com o IOF de ${money(iof.movement.amountCents)}, cobrado depois: ${money(m.movement.amountCents + iof.movement.amountCents)}',
                        if (transfer)
                          'Regra: transferência ${m.movement.outgoing ? 'para ${account(m.toAccountId)}' : 'de ${account(m.fromAccountId)}'}'
                        else if (category != null)
                          '${m.resolution == Resolution.rule ? 'Regra' : 'Categoria sugerida'}: ${app.categoryById(category)?.name ?? '—'}',
                      ];
                      return Padding(
                          padding: const EdgeInsets.only(bottom: 10),
                          child: movementCard(m,
                              hint: hints.isEmpty
                                  ? null
                                  : Text(hints.join('\n'), style: small),
                              extra: [
                                FilledButton(
                                    onPressed: () => _review(_row(m, iof: iof),
                                        type: transfer
                                            ? 'transfer'
                                            : isYield
                                                ? 'income'
                                                : null,
                                        categoryId: category),
                                    child: const Text('Revisar')),
                                TextButton(
                                    onPressed: () {
                                      final both = [
                                        m.movement.id,
                                        if (iof != null) iof.movement.id
                                      ];
                                      _act(
                                          () => InboxReconciler.ignoreAll(both),
                                          'Sugestão ignorada.',
                                          undo: () => _undoIgnore(both));
                                    },
                                    child: const Text('Ignorar')),
                              ]));
                    }),
                ],
              ]),
        ));
  }
}

class SuggestionReviewScreen extends StatefulWidget {
  final Map<String, dynamic> row;

  /// Preselected type (e.g. transfer between own accounts).
  final String? initialType;

  /// Category learned from rules or past entries.
  final String? suggestedCategory;
  const SuggestionReviewScreen(
      {super.key, required this.row, this.initialType, this.suggestedCategory});
  @override
  State<SuggestionReviewScreen> createState() => _SuggestionReviewScreenState();
}

class _SuggestionReviewScreenState extends State<SuggestionReviewScreen> {
  final amount = TextEditingController(),
      description = TextEditingController(),
      subcategory = TextEditingController();
  String type = 'expense';
  String? account, destination, category, error;
  bool busy = false;
  bool remember = false;
  bool alwaysCategory = false;

  /// "Sempre que for este texto, transferir para esta conta, sem perguntar."
  bool alwaysTransfer = false;

  /// What a rule should look for: the description without card prefixes
  /// and numbers ("Ifd*Wesley 123" → "wesley").
  String get rulePattern {
    var d = description.text.trim().toLowerCase();
    d = d.replaceFirst(
        RegExp(r'^(ifd\*|ifd |mp \*|mp\*|pg \*|pg\*|pag\*|pp\*)'), '');
    d = d.replaceAll(RegExp(r'[0-9]'), ' ').replaceAll(RegExp(r'\s+'), ' ');
    d = d.trim();
    return d.length > 40 ? d.substring(0, 40).trim() : d;
  }

  late DateTime date;
  String get ruleScope => NotificationPreferences.scope(
      widget.row['app_id'], widget.row['medium'] ?? 'unknown', type);
  bool get incoming => widget.row['direction'] == 'in';
  List<ImportRule> rules = [];
  @override
  void initState() {
    super.initState();
    type = widget.initialType ??
        switch (widget.row['kind']) {
          'refund' => 'income',
          'transfer' => incoming ? 'income' : 'expense',
          final String kind => kind,
          _ => 'expense',
        };
    date = DateTime.fromMillisecondsSinceEpoch(widget.row['occurred_at']);
    // The IOF charged the next day is part of the purchase.
    amount.text = (((widget.row['amount_cents'] as int) +
                (widget.row['iof_cents'] as int? ?? 0)) /
            100)
        .toStringAsFixed(2)
        .replaceAll('.', ',');
    description.text = widget.row['description'];
    loadRules();
  }

  Future<void> loadRules() async {
    setState(() => busy = true);
    try {
      rules = await ImportRulesService.load();
      final accounts = await NotificationPreferences.load();
      if (!mounted) return;
      final app = context.read<AppProvider>();
      final rule = ImportRulesService.match(
          rules, description.text, type, app.categories);
      // The Nexo account the bank account is linked to, when it can hold
      // this kind of movement.
      String? usable(Object? id) {
        final a = app.accountById(id as String? ?? '');
        return a == null ||
                a.isGold ||
                a.currency != 'BRL' ||
                (type == 'transfer' && a.type == 'credit')
            ? null
            : a.id;
      }

      final own = usable(widget.row['nexo_account_id']);
      final other = usable(widget.row['pair_nexo_account_id']);
      setState(() {
        category = rule?.categoryId ??
            widget.suggestedCategory ??
            CategoryMemory.fromTransactions(app.transactions)
                .suggest(description.text, type: type);
        subcategory.text = rule?.subcategory ?? '';
        if (type == 'transfer') {
          account =
              usable(widget.row['from_account_id']) ?? (incoming ? other : own);
          destination =
              usable(widget.row['to_account_id']) ?? (incoming ? own : other);
          if (account == destination) destination = null;
        } else {
          account = own ??
              NotificationPreferences.suggest(accounts, ruleScope, app.accounts,
                  medium: widget.row['medium'] ?? 'unknown', type: type);
        }
        busy = false;
      });
    } catch (_) {
      if (mounted)
        setState(() {
          busy = false;
          error =
              'Não foi possível carregar as regras. Você pode revisar os campos manualmente.';
        });
    }
  }

  @override
  void dispose() {
    amount.dispose();
    description.dispose();
    subcategory.dispose();
    super.dispose();
  }

  Future<void> save() async {
    if (busy) return;
    final app = context.read<AppProvider>();
    final value = parseMoney(amount.text);
    if (value == null ||
        value <= 0 ||
        description.text.trim().isEmpty ||
        account == null ||
        (type == 'transfer'
            ? destination == null || destination == account
            : category == null)) {
      setState(() => error =
          'Confira valor, descrição, conta e ${type == 'transfer' ? 'conta de destino' : 'categoria'}.');
      return;
    }
    setState(() {
      busy = true;
      error = null;
    });
    final id = widget.row['id'] as String;
    final candidates = ImportRulesService.candidates(app.transactions,
        accountId: type == 'transfer' && incoming ? destination! : account!,
        date: date,
        amount: value,
        type: type == 'transfer' ? (incoming ? 'income' : 'expense') : type);
    if (candidates.isNotEmpty) {
      final proceed = await showDialog<String>(
          context: context,
          builder: (c) => AlertDialog(
                  title: const Text('Possível lançamento já registrado'),
                  content: Text(
                      'Há um lançamento com a mesma conta, valor e data próxima: "${candidates.first.description}". Se for o mesmo movimento, vincule; nada é lançado de novo.'),
                  actions: [
                    TextButton(
                        onPressed: () => Navigator.pop(c, 'back'),
                        child: const Text('Voltar')),
                    TextButton(
                        onPressed: () => Navigator.pop(c, 'separate'),
                        child: const Text('Registrar separado')),
                    FilledButton(
                        onPressed: () => Navigator.pop(c, 'link'),
                        child: const Text('É o mesmo'))
                  ]));
      if (!mounted) return;
      if (proceed == 'link') {
        try {
          await InboxReconciler.link(id, candidates.first.id);
          if (mounted) Navigator.pop(context);
        } catch (_) {
          if (mounted)
            setState(() {
              busy = false;
              error = 'Não foi possível vincular. Atualize a caixa.';
            });
        }
        return;
      }
      if (proceed != 'separate') {
        setState(() => busy = false);
        return;
      }
    }
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final pair = widget.row['pair_id'] as String?;
      if (type == 'transfer') {
        // The side that left the account is the debit leg; the other bank's
        // side of the same money, the credit leg.
        await app.addTransfer(
            fromId: account!,
            toId: destination!,
            fromAmount: value,
            occurredAt: date,
            note: description.text.trim(),
            id: 'notification:$id',
            suggestionId: incoming ? pair : id,
            pairSuggestionId: incoming ? id : pair);
      } else {
        final entryId = 'notification:$id';
        await app.addTransaction(
            AppTransaction(
                id: entryId,
                type: type,
                amount: value,
                description: description.text.trim(),
                accountId: account!,
                categoryId: category!,
                date: date,
                currency: 'BRL',
                note: widget.row['kind'] == 'refund'
                    ? 'Estorno / reembolso revisado'
                    : widget.row['iof_cents'] != null
                        ? 'Inclui IOF de R\$ ${((widget.row['iof_cents'] as int) / 100).toStringAsFixed(2).replaceAll('.', ',')}'
                        : ''),
            metadata: TransactionMetadata(
                transactionId: entryId,
                source: widget.row['kind'] == 'refund' && type == 'income'
                    ? 'notification_refund'
                    : 'notification',
                subcategory: subcategory.text.trim()),
            suggestionId: id);
        // The bank's IOF movement is this same entry.
        if (widget.row['iof_id'] case final String iof) {
          try {
            await InboxReconciler.link(iof, entryId);
          } catch (_) {
            // It stays in the inbox, where it can be linked or ignored.
          }
        }
      }
      // Preferences must never turn a successful financial save into a retry.
      var remembered = true;
      if (remember) {
        try {
          await NotificationPreferences.remember(ruleScope, account!);
        } catch (_) {
          remembered = false;
        }
      }
      if (alwaysCategory && type != 'transfer' && rulePattern.length >= 3) {
        try {
          await ImportRulesService.save(ImportRule(
              id: 'rule:$type:$rulePattern',
              pattern: rulePattern,
              type: type,
              categoryId: category!,
              subcategory: subcategory.text.trim()));
        } catch (_) {
          remembered = false;
        }
      }
      if (alwaysTransfer && type == 'transfer' && rulePattern.length >= 3) {
        try {
          await ImportRulesService.save(ImportRule(
              id: 'rule:transfer:$rulePattern',
              pattern: rulePattern,
              type: 'transfer',
              categoryId: '',
              auto: true,
              // The account the bank does not show: where it went, or
              // where it came from.
              targetAccountId: incoming ? account! : destination!));
        } catch (_) {
          remembered = false;
        }
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(remembered
                ? 'Lançamento registrado.'
                : 'Lançamento registrado; não foi possível lembrar a escolha.')));
        Navigator.pop(context);
      }
    } catch (_) {
      if (mounted)
        setState(() {
          busy = false;
          error =
              'Não foi possível registrar. A sugestão pode já ter sido resolvida. Atualize a caixa de entrada.';
        });
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppProvider>();
    final accounts = app.accounts
        .where((a) =>
            !a.isGold &&
            a.currency == 'BRL' &&
            (type != 'transfer' || a.type != 'credit'))
        .toList();
    final iofCents = widget.row['iof_cents'] as int?;
    return Scaffold(
        appBar: AppBar(title: const Text('Revisar sugestão')),
        body: ListView(padding: const EdgeInsets.all(16), children: [
          Text(
              'Origem: ${widget.row['bank'] ?? NotificationInbox.knownApps[widget.row['app_id']] ?? widget.row['app_id']}'),
          ListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Data da movimentação'),
              subtitle: Text(DateFormat('dd/MM/yyyy HH:mm').format(date)),
              trailing: const Icon(Icons.calendar_month),
              onTap: busy
                  ? null
                  : () async {
                      final picked = await showDatePicker(
                          context: context,
                          initialDate: date,
                          firstDate: DateTime(2000),
                          lastDate: DateTime.now());
                      if (picked != null && mounted)
                        setState(() => date = DateTime(picked.year,
                            picked.month, picked.day, date.hour, date.minute));
                    }),
          const Text(
              'Escolha a conta correta. Pix entre suas próprias contas é transferência, não receita ou despesa.'),
          if (iofCents != null)
            Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                    'O valor já inclui o IOF de ${formatAmount(iofCents / 100, 'BRL')}, que o cartão cobrou depois da compra.',
                    style: Theme.of(context).textTheme.bodySmall)),
          if (type == 'expense')
            Builder(builder: (context) {
              final key = SubscriptionDetector.normalize(description.text);
              final match = SubscriptionDetector.detect(
                  transactions: app.transactions,
                  metadata: app.transactionMetadata,
                  recurring: app.recurring,
                  now: DateTime.now(),
                  amount: (t) => app.convertToMain(
                      t.amount,
                      t.currency.isEmpty
                          ? app.accountById(t.accountId)?.currency ??
                              app.settings.currency
                          : t.currency)).where((c) => c.key == key).firstOrNull;
              if (match == null) return const SizedBox.shrink();
              return Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: ActionChip(
                      avatar: const Icon(Icons.repeat, size: 18),
                      label: Text(
                          'Parece recorrente (${match.months}× nos últimos meses): criar'),
                      onPressed: () =>
                          openRecurringSheet(context, suggestion: match)));
            }),
          DropdownButtonFormField<String>(
              initialValue: type,
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'Tipo'),
              items: const [
                DropdownMenuItem(value: 'expense', child: Text('Despesa')),
                DropdownMenuItem(
                    value: 'income', child: Text('Receita / reembolso')),
                DropdownMenuItem(
                    value: 'transfer',
                    child: Text('Transferência entre minhas contas',
                        overflow: TextOverflow.ellipsis))
              ],
              onChanged: busy
                  ? null
                  : (v) {
                      setState(() {
                        type = v!;
                        account = null;
                        destination = null;
                        category = null;
                      });
                      loadRules();
                    }),
          TextField(
              enabled: !busy,
              controller: amount,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(labelText: 'Valor em R\$')),
          TextField(
              enabled: !busy,
              controller: description,
              decoration: const InputDecoration(labelText: 'Descrição')),
          DropdownButtonFormField<String>(
              key: ValueKey('account$type$account'),
              initialValue: account,
              isExpanded: true,
              decoration: InputDecoration(
                  labelText: type == 'transfer'
                      ? 'Saiu de'
                      : 'Conta / cartão • confira antes de salvar'),
              items: accounts
                  .map(
                      (a) => DropdownMenuItem(value: a.id, child: Text(a.name)))
                  .toList(),
              onChanged: busy ? null : (v) => setState(() => account = v)),
          if (type != 'transfer')
            CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Lembrar esta escolha'),
                subtitle: const Text(
                    'Sugerir esta conta para o mesmo app, meio e tipo. Você sempre confirma.'),
                value: remember,
                onChanged:
                    busy ? null : (v) => setState(() => remember = v ?? false)),
          if (type == 'transfer')
            DropdownButtonFormField<String>(
                key: ValueKey('destination$destination'),
                initialValue: destination,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Entrou em'),
                items: accounts
                    .map((a) =>
                        DropdownMenuItem(value: a.id, child: Text(a.name)))
                    .toList(),
                onChanged: busy ? null : (v) => setState(() => destination = v))
          else ...[
            DropdownButtonFormField<String>(
                key: ValueKey('$type$category'),
                initialValue: category,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Categoria'),
                items: app.categories
                    .where((c) => c.type == type)
                    .map((c) =>
                        DropdownMenuItem(value: c.id, child: Text(c.name)))
                    .toList(),
                onChanged: busy ? null : (v) => setState(() => category = v)),
            TextField(
                controller: subcategory,
                decoration: const InputDecoration(
                    labelText: 'Subcategoria (opcional)')),
          ],
          if (type != 'transfer' && rulePattern.length >= 3)
            CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                title: Text('Sempre usar esta categoria para "$rulePattern"'),
                subtitle: const Text(
                    'Cria uma regra de importação. Você pode mudar em Regras.'),
                value: alwaysCategory,
                onChanged: busy
                    ? null
                    : (v) => setState(() => alwaysCategory = v ?? false)),
          if (type == 'transfer' &&
              widget.row['pair_id'] == null &&
              rulePattern.length >= 3)
            CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(
                    'Sempre registrar "$rulePattern" como transferência entre estas contas'),
                subtitle: const Text(
                    'O app lança sozinho das próximas vezes (dá para desfazer). Você pode mudar em Regras.'),
                value: alwaysTransfer,
                onChanged: busy
                    ? null
                    : (v) => setState(() => alwaysTransfer = v ?? false)),
          const SizedBox(height: 16),
          if (error != null) Text(error!),
          FilledButton(
              onPressed: busy ? null : save,
              child: Text(busy ? 'Salvando…' : 'Confirmar e registrar')),
        ]));
  }
}
