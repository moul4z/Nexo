import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../models/models.dart';
import '../providers/app_provider.dart';
import '../services/account_reconciliation.dart';
import '../services/balance_check.dart';
import '../services/inbox_reconciler.dart';
import '../utils/finance_input.dart';
import '../widgets/analysis_widgets.dart';
import '../widgets/nexo_ui.dart';
import 'add_transaction_screen.dart';
import 'notification_inbox_screen.dart';

/// What explains the difference between the bank and the Nexo in one
/// account: the bank movements without an entry, the entries no bank
/// movement confirms and what was discarded. Nothing is changed here; the
/// person goes to "Para revisar" or to the entry.
class AccountReconcileScreen extends StatefulWidget {
  const AccountReconcileScreen(
      {super.key, required this.account, required this.check, this.until});
  final Account account;
  final BalanceCheck check;

  /// When the bank was read: the period ends there.
  final DateTime? until;

  @override
  State<AccountReconcileScreen> createState() => _AccountReconcileScreenState();
}

/// The sentence under the numbers, the same the assistant reads.
String reconcileReading(int differenceCents, int explainedCents) => differenceCents ==
        0
    ? 'O saldo do Nexo é igual ao do banco.'
    : differenceCents == explainedCents
        ? 'A diferença é exatamente o que está listado abaixo: lance o que falta e confira o que só o Nexo tem.'
        : 'A diferença não fecha só com este período: pode haver movimento anterior, lançamento em outra conta ou dado do banco atrasado. Amplie o período antes de ajustar o saldo.';

class _AccountReconcileScreenState extends State<AccountReconcileScreen> {
  static const _periods = [7, 30, 90];
  var _days = 30;
  AccountReconciliation? _result;
  var _loading = 0;

  DateTime get _to => widget.until ?? DateTime.now();
  DateTime get _from => _to.subtract(Duration(days: _days - 1));

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    final app = context.read<AppProvider>();
    final turn = ++_loading;
    final result = await InboxReconciler.account(
        accountId: widget.account.id,
        from: _from,
        to: _to,
        transactions: app.transactions,
        metadata: app.transactionMetadata,
        accounts: app.accounts,
        profileName: app.settings.userName);
    // A slower, older answer never replaces the newer period.
    if (mounted && turn == _loading) setState(() => _result = result);
  }

  Future<void> _open(Widget screen) async {
    await Navigator.push(context, MaterialPageRoute(builder: (_) => screen));
    if (mounted) await _load();
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppProvider>();
    final theme = Theme.of(context);
    final small = theme.textTheme.bodySmall
        ?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final r = _result;
    final day = DateFormat('dd/MM');
    String money(int cents) => analysisMoney(app, cents / 100);
    String signed(int cents) =>
        '${cents > 0 ? '+' : cents < 0 ? '−' : ''}${money(cents.abs())}';
    final difference = widget.check.differenceCents;
    return Scaffold(
      appBar: AppBar(title: Text('${widget.account.name} × banco')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          NexoCard(
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              _Line('No banco', money(widget.check.bankCents)),
              _Line('No Nexo naquele momento',
                  money(widget.check.nexoAtBankCents)),
              _Line('Diferença', signed(difference), strong: true),
              if (r != null) ...[
                const Divider(height: 20),
                _Line('O período explica', signed(r.explainedCents)),
                _Line('Sem explicação', signed(difference - r.explainedCents),
                    strong: true,
                    color: difference == r.explainedCents
                        ? NexoTones.income(context)
                        : NexoTones.warning(context)),
                const SizedBox(height: 8),
                Text(reconcileReading(difference, r.explainedCents),
                    style: small),
              ],
            ]),
          ),
          const SizedBox(height: 12),
          Wrap(spacing: 8, children: [
            for (final d in _periods)
              ChoiceChip(
                  label: Text('$d dias'),
                  selected: _days == d,
                  onSelected: (_) {
                    setState(() {
                      _days = d;
                      _result = null;
                    });
                    _load();
                  }),
          ]),
          Padding(
            padding: const EdgeInsets.only(top: 6, bottom: 4),
            child: Text(
                'De ${day.format(_from)} a ${day.format(_to)}. Positivo entra na conta, negativo sai.',
                style: small),
          ),
          if (r == null) const LinearProgressIndicator(),
          if (r != null && r.isEmpty)
            const Padding(
              padding: EdgeInsets.only(top: 12),
              child: Text(
                  'Nada neste período explica a diferença: todo movimento do banco tem lançamento e todo lançamento tem movimento.'),
            ),
          if (r != null && r.onlyBank.isNotEmpty) ...[
            const SizedBox(height: 16),
            NexoSectionTitle('No banco, sem lançamento',
                subtitle:
                    '${ptCount(r.onlyBank.length, 'movimento')} · ${signed(r.onlyBankCents)}',
                action: 'Para revisar',
                onAction: () => _open(const NotificationInboxScreen())),
            for (final e in r.onlyBank)
              _Item(
                  title: e.match.movement.description,
                  detail: [
                    day.format(e.match.movement.occurredAt),
                    if (e.match.movement.bank case final bank?) bank,
                  ].join(' · '),
                  amount: signed(e.cents)),
          ],
          if (r != null && r.maybe.isNotEmpty) ...[
            const SizedBox(height: 16),
            NexoSectionTitle('Talvez já lançado',
                subtitle:
                    '${ptCount(r.maybe.length, 'movimento')} parecido com um lançamento: decida em Para revisar',
                action: 'Para revisar',
                onAction: () => _open(const NotificationInboxScreen())),
            for (final m in r.maybe)
              _Item(
                  title: m.movement.description,
                  detail: [
                    day.format(m.movement.occurredAt),
                    if (m.transaction case final t?)
                      'parece "${t.description}" de ${day.format(t.date)}',
                  ].join(' · '),
                  amount: signed(m.movement.outgoing
                      ? -m.movement.amountCents
                      : m.movement.amountCents)),
          ],
          if (r != null && r.onlyNexo.isNotEmpty) ...[
            const SizedBox(height: 16),
            NexoSectionTitle('Só no Nexo',
                subtitle:
                    '${ptCount(r.onlyNexo.length, 'lançamento')} que o banco não confirma · ${signed(r.onlyNexoCents)}'),
            Text(
                'Dinheiro vivo, lançamento repetido ou em outra conta, ou um dia que o banco ainda não enviou.',
                style: small),
            for (final e in r.onlyNexo)
              _Item(
                  title: e.entry.description.isEmpty
                      ? e.kind
                      : e.entry.description,
                  detail: '${day.format(e.entry.date)} · ${e.kind}',
                  amount: signed(e.cents),
                  onTap: () => _open(AddTransactionScreen(
                      existing: e.entry, initialType: e.entry.type))),
          ],
          if (r != null && r.ignoredCount > 0) ...[
            const SizedBox(height: 16),
            NexoSectionTitle('Ignorados por você',
                subtitle:
                    '${ptCount(r.ignoredCount, 'movimento')} · ${signed(r.ignoredCents)}'),
            Text(
                'O banco mexeu nesse dinheiro e o Nexo não: entra na conta da diferença.',
                style: small),
          ],
        ],
      ),
    );
  }
}

class _Line extends StatelessWidget {
  const _Line(this.label, this.value, {this.strong = false, this.color});
  final String label, value;
  final bool strong;
  final Color? color;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(children: [
          Expanded(child: Text(label)),
          Text(value,
              style: TextStyle(
                  fontWeight: strong ? FontWeight.w600 : null,
                  color: color,
                  fontFeatures: NexoTones.figures)),
        ]),
      );
}

class _Item extends StatelessWidget {
  const _Item(
      {required this.title,
      required this.detail,
      required this.amount,
      this.onTap});
  final String title, detail, amount;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => ListTile(
        contentPadding: EdgeInsets.zero,
        dense: true,
        onTap: onTap,
        title: Text(title, maxLines: 2, overflow: TextOverflow.ellipsis),
        subtitle: Text(detail, maxLines: 2, overflow: TextOverflow.ellipsis),
        trailing: Text(amount,
            style: TextStyle(
                fontWeight: FontWeight.w600, fontFeatures: NexoTones.figures)),
      );
}
