import 'dart:async';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../providers/app_provider.dart';
import '../services/desktop_profile.dart';
import '../services/diagnostics.dart';
import '../services/inbox_reconciler.dart';
import '../services/inbox_writer.dart';
import '../services/bank_notices.dart';
import '../services/notification_inbox.dart';
import '../services/platform_capabilities.dart';
import '../services/pluggy_inbox.dart';
import 'assistant_commands.dart';
import 'claude_queue.dart';
import 'ledger_sync.dart';
import 'supabase_auth.dart';
import 'sync_config.dart';
import 'sync_controller.dart';

/// Where the pass that is running now came from (see [QueueCheck.source]).
String? _passSource;

/// Connects the assistant to sync: after every successful round this
/// device claims and applies the pending requests, then records the check,
/// and the bank inbox settles what needs nobody. [background]: the headless
/// pass, which reads the banks itself (the app does it on opening).
AssistantCommands wireAssistant(AppProvider provider, SyncConfig config,
    {bool background = false}) {
  final assistant = AssistantCommands.instance = AssistantCommands(
      SupabaseAssistantRemote(config, SupabaseAuth.app!), provider);
  SyncController.instance?.afterSync = () async {
    final sync = SyncController.instance!;
    if (!sync.bound || sync.datasetId == null || sync.deviceId == null) {
      return;
    }
    // After a round, the other device's settings are already here.
    await provider.seedSharedSettings();
    final before = assistant.handled;
    var ok = true;
    try {
      await assistant.run(datasetId: sync.datasetId!, deviceId: sync.deviceId!);
    } catch (e) {
      ok = false;
      rethrow;
    } finally {
      await ClaudeQueue.record(QueueCheck(
          at: DateTime.now(),
          source:
              _passSource ?? (PlatformCapabilities.windows ? 'tray' : 'app'),
          applied: assistant.handled - before,
          ok: ok));
    }
    await bankPass(provider, headless: background);
  };
  return assistant;
}

/// The bank part of a round: what the banks sent is settled by the app when
/// it needs nobody (already registered, between the person's accounts,
/// yields, rules), the decisions go to the server, so the assistant sees a
/// clean queue too. With the app closed the banks are read at most once an
/// hour. A failure waits for the next round: nothing here blocks the queue.
Future<void> bankPass(AppProvider provider, {required bool headless}) async {
  try {
    final pluggy = PluggyInbox.instance;
    if (headless) {
      if (pluggy == null) return;
      final prefs = await SharedPreferences.getInstance();
      final now = DateTime.now().millisecondsSinceEpoch;
      // Once an hour. A clock set back must not block it: a mark in the
      // future counts as no mark.
      final last = prefs.getInt(_bankPassKey) ?? 0;
      if (last <= now && now - last < 3600000) return;
      await prefs.setInt(_bankPassKey, now);
      await pluggy.sync();
    }
    final started = DateTime.now();
    final state = await InboxReconciler.background(
        pending: NotificationInbox.pending,
        transactions: provider.transactions,
        metadata: provider.transactionMetadata,
        accounts: provider.accounts,
        profileName: provider.settings.userName,
        recurring: provider.recurring,
        writer: AppInboxWriter(provider),
        push: () async => pluggy?.pushNow(),
        every: headless ? Duration.zero : const Duration(minutes: 10));
    // With the app closed nobody sees "Para revisar": what the app did by
    // itself, and in the morning what yesterday left, become notices.
    if (headless && state != null) {
      await BankNotices.afterPass(state, started: started);
    }
  } catch (e) {
    Diagnostics.note('bank pass', e);
  }
}

const _bankPassKey = 'nexo_bank_pass_at_v1';

/// The app's own engine answers the worker (app alive but not in front).
Future<QueueCheck> runQueueInApp(String source) async {
  final sync = SyncController.instance;
  final assistant = AssistantCommands.instance;
  if (sync == null || assistant == null || !sync.bound) {
    return QueueCheck(at: DateTime.now(), source: source, note: 'sem_acervo');
  }
  final before = assistant.handled;
  _passSource = source == 'app' ? 'app' : 'background';
  try {
    await sync.syncNow();
    if (sync.pending > 0) await sync.syncNow();
  } finally {
    _passSource = null;
  }
  return QueueCheck(
      at: DateTime.now(),
      source: 'background',
      applied: assistant.handled - before,
      ok: sync.status == LedgerSyncStatus.idle ||
          sync.status == LedgerSyncStatus.progressed);
}

/// The headless pass: no screen, no timers. Loads the ledger, syncs, applies
/// what the assistant asked, sends the result and, when something was
/// recorded, says so in a notification without amounts.
Future<QueueCheck> runHeadlessQueue(String source) async {
  await DesktopProfile.initialize(const []);
  Intl.defaultLocale = 'pt_BR';
  await initializeDateFormatting('pt_BR');
  final config = SyncConfig.current;
  if (config == null) {
    return QueueCheck(at: DateTime.now(), source: source, note: 'sem_servidor');
  }
  if (!await ClaudeQueue.enabled()) {
    return QueueCheck(at: DateTime.now(), source: source, note: 'desligado');
  }
  SupabaseAuth.app = SupabaseAuth(config);
  // Real bank data never reaches a test profile.
  if (!DesktopProfile.isTest) {
    PluggyInbox.instance =
        PluggyInbox(SupabasePluggyRemote(config, SupabaseAuth.app!));
  }
  final provider = AppProvider();
  await provider.load();
  final sync = SyncController.instance = SyncController.forApp(
      config, SupabaseAuth.app, provider.reloadFromStorage,
      real: !DesktopProfile.isTest)!;
  final assistant = wireAssistant(provider, config, background: true);
  _passSource = source;
  try {
    await sync.runOnce();
  } finally {
    _passSource = null;
  }
  final applied = assistant.handled;
  if (applied > 0 && await ClaudeQueue.notifies()) {
    await _tell(applied);
  }
  final ok = sync.status == LedgerSyncStatus.idle ||
      sync.status == LedgerSyncStatus.progressed;
  final check = QueueCheck(
      at: DateTime.now(),
      source: source,
      applied: applied,
      ok: ok,
      note: !sync.bound ? 'sem_acervo' : (ok ? null : sync.status?.name));
  // A successful round already recorded itself; a failed one did not.
  if (!ok || !sync.bound) await ClaudeQueue.record(check);
  return check;
}

Future<void> _tell(int applied) async {
  try {
    final plugin = FlutterLocalNotificationsPlugin();
    await plugin.initialize(const InitializationSettings(
        android: AndroidInitializationSettings('ic_notification')));
    await plugin.show(
        7318,
        'Feito pelo Claude',
        applied == 1
            ? '1 pedido gravado com o app fechado. Toque para conferir.'
            : '$applied pedidos gravados com o app fechado. Toque para conferir.',
        const NotificationDetails(
            android: AndroidNotificationDetails(
                'nexo_claude_done', 'Feito pelo Claude',
                channelDescription:
                    'Quando o Nexo grava um pedido do Claude com o app fechado. Sem valores.',
                importance: Importance.low,
                priority: Priority.low)));
  } catch (e) {
    Diagnostics.note('queue', e);
  }
}
