import '../models/models.dart';
import '../models/transaction_metadata.dart';
import 'text_normalize.dart';

class FinanceRules {
  /// A category the person made for fixing a balance ("Ajuste de saldo",
  /// "Acerto"). Fixing a balance is never income or spending: what is
  /// entered there is kept as a neutral adjustment.
  static bool isAdjustmentCategory(String name) {
    final n = normalizeText(name).trim();
    return const {
      'ajuste de saldo',
      'ajustes de saldo',
      'ajuste',
      'ajustes',
      'acerto de saldo',
      'acerto',
      'correcao de saldo',
    }.contains(n);
  }

  /// Entries older than the explicit mark, recognised by their text. Only
  /// without a category: a real expense always has one, even when the bank
  /// calls it "Transferência enviada - Fulano" or "Pagamento fatura de luz".
  static bool isImplicitNeutral(AppTransaction tx) {
    if (tx.categoryId.isNotEmpty) return false;
    final text = '${tx.description} ${tx.note}'.toLowerCase();
    return text.contains('transfer out') ||
        text.contains('transfer in') ||
        text.startsWith('transferência enviada') ||
        text.startsWith('transferência recebida') ||
        (text.contains('fatura') && text.contains('pagamento')) ||
        text.contains('pagamento da fatura') ||
        text.contains('pagamento de fatura');
  }

  static bool isNeutral(
    AppTransaction tx,
    TransactionMetadata? metadata,
  ) {
    return (metadata?.excludeFromSpending ?? false) || isImplicitNeutral(tx);
  }

  /// What a card's invoice charges. Some neutral entries still belong to it:
  /// the balance adjustment, and the part of a split bill others will repay.
  /// A credit still forecast has not happened, so it lowers nothing yet.
  static bool onInvoice(AppTransaction tx, TransactionMetadata? metadata) {
    if (tx.type == 'income' && metadata?.isPending == true) return false;
    return !isNeutral(tx, metadata) ||
        metadata?.source == 'opening_balance' ||
        (metadata?.source.startsWith('shared_bill:') ?? false);
  }
}
