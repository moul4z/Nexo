import 'dart:io';
import 'package:flutter/foundation.dart' show kReleaseMode;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import '../database/database_platform.dart';
import 'platform_capabilities.dart';

/// An explicit QA profile isolates synthetic data and protection preferences.
/// It never imports or copies the regular profile.
///
/// On Android the test build (package `com.ma.expensy.teste`, from
/// `flutter build apk --profile` or `--debug`) is a QA profile too: it is a
/// separate app with its own data, and with this flag it only ever sees
/// synthetic datasets and no bank connection.
abstract final class DesktopProfile {
  static bool isTest = false;

  /// The Android package of test builds.
  static const testPackageSuffix = '.teste';

  /// QA only: a test profile closes normally unless this is given.
  static bool testTray = false;

  /// Empty for `--test-profile`; `pc2` for `--test-profile=pc2`. Each named
  /// profile is a separate synthetic device (data, preferences, PIN, session).
  static String testName = '';
  static bool _configured = false;

  /// A development build (`flutter run`, a debug or profile executable) of
  /// the Windows app never opens the person's database: a newer schema would
  /// upgrade the file and the installed version could no longer open it. It
  /// uses the synthetic profile `dev` instead; `--real-data` is the explicit
  /// way in.
  static bool developmentProfile(
          {required bool release,
          required bool test,
          required List<String> arguments}) =>
      !release && !test && !arguments.contains('--real-data');

  /// Appended to every QA storage key so named profiles never share secrets.
  static String get qaSuffix => testName.isEmpty ? '' : '_$testName';

  static Future<void> initialize(List<String> arguments) async {
    if (!_configured) {
      if (PlatformCapabilities.windows) {
        for (final argument in arguments) {
          if (argument == '--test-profile') isTest = true;
          if (argument == '--qa-tray') testTray = true;
          if (argument.startsWith('--test-profile=')) {
            final name = argument.substring('--test-profile='.length);
            if (!RegExp(r'^[a-z0-9]{1,16}$').hasMatch(name)) {
              throw StateError('Nome de perfil de teste inválido.');
            }
            isTest = true;
            testName = name;
          }
        }
        if (developmentProfile(
            release: kReleaseMode, test: isTest, arguments: arguments)) {
          isTest = true;
          testName = 'dev';
        }
      }
      if (Platform.isAndroid) {
        try {
          final package = (await PackageInfo.fromPlatform()).packageName;
          if (package.endsWith(testPackageSuffix)) isTest = true;
        } catch (_) {
          // Without the plugin (unit tests) this is not a test build.
        }
      }
      if (isTest && PlatformCapabilities.windows)
        SharedPreferences.setPrefix('nexo_windows_qa$qaSuffix.');
      _configured = true;
    }
    await DatabasePlatform.initialize(
        testDirectory: isTest
            ? p.join(Directory.systemTemp.path,
                testName.isEmpty ? 'NexoWindowsQA' : 'NexoWindowsQA-$testName')
            : null);
  }
}
