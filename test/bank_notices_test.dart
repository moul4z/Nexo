// Notices of the bank pass with the app closed: what the app registered by
// itself (SEC-08) and the morning summary of yesterday. Fictitious values.
import 'package:flutter_test/flutter_test.dart';
import 'package:nexo/services/bank_notices.dart';
import 'package:nexo/services/inbox_reconciler.dart';
import 'package:nexo/services/reconciliation.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  final started = DateTime(2026, 11, 20, 8);
  late List<(int, String, String)> sent;
  Future<void> send(int id, String title, String body, String route) async =>
      sent.add((id, title, route));

  Match match(String id, DateTime at, {bool automatic = false}) => Match(
      PendingMovement(
          id: 'pluggy:$id',
          amountCents: 4590,
          description: 'Loja Exemplo $id',
          kind: 'expense',
          occurredAt: at),
      automatic ? Resolution.reserve : Resolution.newEntry,
      automatic: automatic);

  AutoResolved made(String id, DateTime at) =>
      AutoResolved('pluggy:$id', 'rule', 'Loja Exemplo', 4590, at,
          transactionId: 'notification:pluggy:$id', created: true);

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    sent = [];
  });

  test('what this pass registered by itself is told once; links are not',
      () async {
    final state = InboxState(const [], [
      made('a', started.add(const Duration(minutes: 1))),
      made('b', started.add(const Duration(minutes: 1))),
      made('old', started.subtract(const Duration(days: 1))),
      AutoResolved('pluggy:link', 'linked', 'Já lançado', 990, started,
          transactionId: 't'),
    ]);
    await BankNotices.afterPass(state,
        started: started, now: DateTime(2026, 11, 20, 6), send: send);
    expect(sent, [
      (
        BankNotices.autoId,
        'O Nexo lançou 2 movimentos sozinho',
        BankNotices.inboxRoute
      )
    ]);
    sent.clear();
    await BankNotices.setAutoEnabled(false);
    await BankNotices.afterPass(state,
        started: started, now: DateTime(2026, 11, 20, 6), send: send);
    expect(sent, isEmpty, reason: 'turned off');
  });

  test('the morning summary: after 7h, once a day, only what needs the person',
      () async {
    final yesterday = DateTime(2026, 11, 19, 15);
    final state = InboxState([
      match('loja', yesterday),
      match('feira', yesterday),
      match('cofre', yesterday, automatic: true),
      match('hoje', DateTime(2026, 11, 20, 7)),
    ], const []);
    await BankNotices.afterPass(state,
        started: started, now: DateTime(2026, 11, 20, 6, 30), send: send);
    expect(sent, isEmpty, reason: 'too early');
    await BankNotices.afterPass(state,
        started: started, now: DateTime(2026, 11, 20, 8), send: send);
    expect(sent, [
      (
        BankNotices.morningId,
        'Ontem: 2 movimentos sem lançamento',
        'notification_inbox:2026-11-19'
      )
    ]);
    await BankNotices.afterPass(state,
        started: started, now: DateTime(2026, 11, 20, 12), send: send);
    expect(sent, hasLength(1), reason: 'once a day');
    expect(BankNotices.dayOf('notification_inbox:2026-11-19'),
        DateTime(2026, 11, 19));
    expect(BankNotices.dayOf(BankNotices.inboxRoute), isNull);
  });

  test('nothing waiting from yesterday: no summary', () async {
    await BankNotices.afterPass(
        InboxState([match('hoje', DateTime(2026, 11, 20, 7))], const []),
        started: started,
        now: DateTime(2026, 11, 20, 9),
        send: send);
    expect(sent, isEmpty);
  });
}
