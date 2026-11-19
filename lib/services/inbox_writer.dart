import 'subcategories.dart';
import '../models/models.dart';
import '../models/transaction_metadata.dart';
import '../providers/app_provider.dart';
import 'desktop_profile.dart';
import 'inbox_reconciler.dart';
import 'reconciliation.dart';

/// The app's own write paths for what the inbox settles by itself: the same
/// validations, balances and sync as a tap of the person.
class AppInboxWriter implements InboxWriter {
  AppInboxWriter(this.app, {bool? canCreate})
      : _canCreate = canCreate ?? (defaultCanCreate() || DesktopProfile.isTest);
  final AppProvider app;
  final bool _canCreate;

  @override
  bool get canCreate => _canCreate;

  static const yieldCategoryId = 'nexo-rendimentos';

  @override
  Future<String> addEntry(PendingMovement m,
      {required String type,
      required String accountId,
      required String categoryId,
      required String description,
      String subcategory = '',
      String? note}) async {
    final id = 'notification:${m.id}';
    await app.addTransaction(
        AppTransaction(
            id: id,
            type: type,
            amount: m.amountCents / 100,
            description: description,
            accountId: accountId,
            categoryId: categoryId,
            date: m.occurredAt,
            note: note ?? ''),
        metadata: TransactionMetadata(
            transactionId: id,
            source: 'notification',
            // Food without a subcategory: Delivery or Mercado when the
            // merchant makes it clear (visible and editable in the entry).
            subcategory: subcategory.isEmpty && categoryId == 'food_exp'
                ? foodSubcategory(description) ?? ''
                : subcategory),
        generateInstallments: false,
        suggestionId: m.id);
    return id;
  }

  @override
  Future<void> addTransfer(PendingMovement out, PendingMovement? incoming,
      {required String fromId, required String toId}) {
    // The suggestion that left the account is the debit leg; an incoming
    // movement alone is the credit leg.
    final outgoing = out.outgoing;
    return app.addTransfer(
        fromId: fromId,
        toId: toId,
        fromAmount: out.amountCents / 100,
        occurredAt: out.occurredAt,
        note: 'Entre contas suas (Open Finance)',
        id: 'notification:${out.id}',
        suggestionId: outgoing ? out.id : incoming?.id,
        pairSuggestionId: outgoing ? incoming?.id : out.id);
  }

  @override
  Future<void> addInvoicePayment(PendingMovement? bank, PendingMovement? card,
      {required String fromId, required String cardId}) {
    final any = (bank ?? card)!;
    return app.payInvoiceFromBank(
        fromId: fromId,
        cardId: cardId,
        amount: any.amountCents / 100,
        paidOn: any.occurredAt,
        id: 'notification:${any.id}',
        suggestionId: bank?.id,
        pairSuggestionId: card?.id);
  }

  @override
  Future<void> addIof(PendingMovement iof, String transactionId) =>
      app.addIofToTransaction(transactionId, iof.id, iof.amountCents / 100);

  @override
  Future<void> removeIof(String transactionId, int cents) =>
      app.removeIofFromTransaction(transactionId, cents / 100);

  @override
  Future<String> yieldCategory() async {
    final existing = app.categories
        .where((c) =>
            c.type == 'income' &&
            (c.id == yieldCategoryId ||
                normalizeMerchant(c.name).startsWith('rendiment')))
        .firstOrNull;
    if (existing != null) return existing.id;
    await app.addCategory(AppCategory(
        id: yieldCategoryId,
        name: 'Rendimentos',
        type: 'income',
        colorValue: 0xff00897b));
    return yieldCategoryId;
  }

  @override
  Future<void> deleteEntry(String transactionId) =>
      app.deleteTransaction(transactionId);
}
