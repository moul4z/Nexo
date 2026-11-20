// The headless pass has a time budget (SYNC-09): Android stops the worker
// at 80 s, so reading the banks starts only with room left. Synthetic data.
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexo/database/database_platform.dart';
import 'package:nexo/database/db_helper.dart';
import 'package:nexo/providers/app_provider.dart';
import 'package:nexo/services/balance_check.dart';
import 'package:nexo/services/pluggy_inbox.dart';
import 'package:nexo/sync/claude_queue_runner.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

class _Remote implements PluggyRemote {
  int reads = 0;
  @override
  Future<List<BankAccountSnapshot>> accounts() async => const [];
  @override
  Future<void> link(String accountId, String? nexoAccountId) async {}
  @override
  Future<List<PluggyItem>> refresh({bool force = false}) async {
    reads++;
    return const [];
  }

  @override
  Future<List<PluggyItem>> items() async => const [];
  @override
  Future<void> addItem(String itemId, String label) async {}
  @override
  Future<void> removeItem(String itemId) async {}
  @override
  Future<List<Map<String, dynamic>>> suggestions(int sinceMs) async {
    reads++;
    return const [];
  }

  @override
  Future<void> decide(List<Map<String, Object?>> list) async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late _Remote remote;

  setUpAll(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('home_widget'), (call) async => true);
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    root = await Directory.systemTemp.createTemp('nexo-headless-');
    await DBHelper.close();
    await DatabasePlatform.initialize(testDirectory: p.join(root.path, 'db'));
    remote = _Remote();
    PluggyInbox.instance = PluggyInbox(remote);
  });

  tearDown(() async {
    headlessDeadline = null;
    PluggyInbox.instance = null;
    debugDefaultTargetPlatformOverride = null;
    await DBHelper.close();
    try {
      await root.delete(recursive: true);
    } catch (_) {}
  });

  test('near the end of the worker the banks wait for the next pass', () async {
    final app = AppProvider();
    headlessDeadline = DateTime.now().add(const Duration(seconds: 20));
    await bankPass(app, headless: true);
    expect(remote.reads, 0, reason: 'not started without time to finish');
    expect((await SharedPreferences.getInstance()).getKeys(), isEmpty,
        reason: 'the hourly mark stays free for the next pass');

    headlessDeadline = DateTime.now().add(const Duration(seconds: 60));
    await bankPass(app, headless: true);
    expect(remote.reads, greaterThan(0));
  });
}
