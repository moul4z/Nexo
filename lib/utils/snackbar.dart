import 'package:flutter/material.dart';

void showAppSnackbar(BuildContext context, String message,
    {VoidCallback? onUndo}) {
  final scaffold = ScaffoldMessenger.of(context);
  scaffold.hideCurrentSnackBar();

  final controller = scaffold.showSnackBar(
    SnackBar(
      content: Text(message),
      action: onUndo != null
          ? SnackBarAction(label: 'Desfazer', onPressed: onUndo)
          : null,
      behavior: SnackBarBehavior.floating,
      duration: const Duration(seconds: 3),
    ),
  );

  // Forcefully close the snackbar after 3 seconds to override accessibility services
  // keeping the snackbar open indefinitely when it has an action.
  Future.delayed(const Duration(seconds: 3), () {
    try {
      controller.close();
    } catch (_) {}
  });
}

/// The app's own reason for a refused write, or null when it has none.
String? failureReason(Object e) => switch (e) {
      StateError(:final message) => message,
      FormatException(:final message) => message,
      ArgumentError(:final message) => '$message',
      _ => null,
    };

/// Runs a form's save once: a second tap while it runs does nothing (UX-04),
/// and a refused write says why instead of failing silently (UX-08).
/// Returns whether the save finished.
Future<bool> saveOnce(State state, bool Function() busy,
    void Function(bool) setBusy, Future<void> Function() save,
    {String fallback =
        'Não foi possível salvar. Confira os dados e tente novamente.'}) async {
  if (busy()) return false;
  setBusy(true);
  try {
    await save();
    return true;
  } catch (e) {
    if (state.mounted) {
      ScaffoldMessenger.of(state.context)
          .showSnackBar(SnackBar(content: Text(failureReason(e) ?? fallback)));
    }
    return false;
  } finally {
    if (state.mounted) setBusy(false);
  }
}
