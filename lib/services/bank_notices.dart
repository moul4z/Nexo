import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../utils/finance_input.dart';
import 'financial_reminders.dart';
import 'inbox_reconciler.dart';
import 'platform_capabilities.dart';
import 'reconciliation.dart';

/// Shows one local notification: id, title, body, the route a tap opens.
typedef NoticeSender = Future<void> Function(
    int id, String title, String body, String route);

/// Notices of the bank pass made with the app closed (Android): what the
/// app registered by itself (SEC-08), and, once a morning, what yesterday
/// left without an entry. With the app open the person sees "Para revisar";
/// Windows has no notifications.
abstract final class BankNotices {
  static const autoKey = 'nexo_notice_auto_v1';
  static const morningKey = 'nexo_notice_morning_v1';
  static const _morningDayKey = 'nexo_notice_morning_day_v1';
  static const inboxRoute = 'notification_inbox';
  static const autoId = 7301, morningId = 7302;

  static Future<bool> autoEnabled() async =>
      (await SharedPreferences.getInstance()).getBool(autoKey) ?? true;
  static Future<void> setAutoEnabled(bool on) async =>
      (await SharedPreferences.getInstance()).setBool(autoKey, on);
  static Future<bool> morningEnabled() async =>
      (await SharedPreferences.getInstance()).getBool(morningKey) ?? true;
  static Future<void> setMorningEnabled(bool on) async =>
      (await SharedPreferences.getInstance()).setBool(morningKey, on);

  /// The route of the morning notice: "Para revisar" on that day.
  static String dayRoute(DateTime day) =>
      '$inboxRoute:${DateFormat('yyyy-MM-dd').format(day)}';

  /// The day a route asks for, or null for the whole list.
  static DateTime? dayOf(String route) {
    if (!route.startsWith('$inboxRoute:')) return null;
    return DateTime.tryParse(route.substring(inboxRoute.length + 1));
  }

  /// What still needs the person on [day]: nothing the app settles itself.
  static List<Match> waitingOn(DateTime day, List<Match> matches) => [
        for (final m in matches)
          if (!m.automatic &&
              m.movement.occurredAt.year == day.year &&
              m.movement.occurredAt.month == day.month &&
              m.movement.occurredAt.day == day.day)
            m
      ];

  /// After a pass with the app closed. [started]: when the pass began, so
  /// only what this pass registered is told.
  static Future<void> afterPass(InboxState state,
      {required DateTime started, DateTime? now, NoticeSender? send}) async {
    if (send == null && !PlatformCapabilities.scheduledNotifications) return;
    final notify = send ?? _show;
    final clock = now ?? DateTime.now();
    final created = state.resolved
        .where((r) => r.created && !r.at.isBefore(started))
        .length;
    if (created > 0 && await autoEnabled()) {
      await notify(
          autoId,
          'O Nexo lançou ${ptCount(created, 'movimento')} sozinho',
          'Vindos do banco, pelas suas regras. Toque para ver e desfazer em Para revisar.',
          inboxRoute);
    }
    if (clock.hour < 7 || !await morningEnabled()) return;
    final prefs = await SharedPreferences.getInstance();
    final today = DateFormat('yyyy-MM-dd').format(clock);
    if (prefs.getString(_morningDayKey) == today) return;
    final yesterday = DateTime(clock.year, clock.month, clock.day - 1);
    final waiting = waitingOn(yesterday, state.matches);
    await prefs.setString(_morningDayKey, today);
    if (waiting.isEmpty) return;
    await notify(
        morningId,
        'Ontem: ${ptCount(waiting.length, 'movimento')} sem lançamento',
        'Toque para revisar; o que já tem categoria pode ser confirmado de uma vez.',
        dayRoute(yesterday));
  }

  /// In the closed app's isolate the plugin was not started by the screens.
  static Future<void> _show(
      int id, String title, String body, String route) async {
    final plugin = FinancialReminders.instance.plugin;
    await plugin.initialize(const InitializationSettings(
        android: AndroidInitializationSettings('ic_notification')));
    await plugin.show(
        id,
        title,
        body,
        const NotificationDetails(
            android: AndroidNotificationDetails(
                'nexo_bank_notices', 'Movimentos do banco',
                channelDescription:
                    'O que o Nexo lançou sozinho e o resumo da manhã',
                visibility: NotificationVisibility.private,
                importance: Importance.defaultImportance)),
        payload: route);
  }
}
