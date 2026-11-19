import '../models/models.dart';
import '../models/transaction_metadata.dart';
import 'text_normalize.dart';

/// The subcategories the app offers for each built-in category.
List<String> defaultSubcategories(String? categoryId) {
  const values = <String, List<String>>{
    'food_exp': ['Mercado', 'Lanche', 'Restaurante', 'Delivery'],
    'transport': [
      'Combustível',
      'Transporte por app',
      'Ônibus/Metrô',
      'Manutenção',
      'Estacionamento',
    ],
    'shopping': ['Roupas', 'Eletrônicos', 'Casa', 'Pessoal', 'Outros'],
    'bills': ['Água', 'Luz', 'Internet', 'Telefone', 'Assinaturas', 'Aluguel'],
    'health': ['Farmácia', 'Consulta', 'Exames', 'Academia'],
    'entertainment': ['Streaming', 'Cinema', 'Jogos', 'Passeio'],
    'education': ['Faculdade', 'Cursos', 'Livros', 'Material'],
    'other_exp': ['Outros'],
    'salary': ['Salário'],
    'freelance': ['Freelance', 'Bônus', 'Reembolso', 'Outros'],
    'business': ['Negócios'],
    'investment': ['Rendimentos', 'Dividendos', 'Juros'],
    'gift': ['Presente', 'Doação recebida'],
  };
  return values[categoryId] ?? const [];
}

final _delivery = RegExp(
    r'\b(ifood|ifd|rappi|ze delivery|ze_delivery|aiqfome|uber ?eats|james delivery|delivery)\b');
final _market = RegExp(
    r'\b(supermercado|supermerc|mercado|mercadinho|atacadao|atacadista|assai|carrefour|pao de acucar|hortifruti|sacolao|hiper|minimercado|emporio)\b');

/// Delivery or Mercado for food, from the merchant's text; null when it is
/// not clear. Only a suggestion: it never reclassifies anything by itself.
String? foodSubcategory(String description) {
  final t = normalizeText(description).toLowerCase();
  if (_delivery.hasMatch(t)) return 'Delivery';
  // "Mercado Pago" is a payment app, not a market.
  if (_market.hasMatch(t) &&
      !t.contains('mercado pago') &&
      !t.contains('mercadopago') &&
      !t.contains('mercado livre')) {
    return 'Mercado';
  }
  return null;
}

/// Food entries without a subcategory whose merchant says Delivery or
/// Mercado: what "Classificar antigos" offers, never applied by itself.
List<(AppTransaction, String)> unclassifiedFood(
    List<AppTransaction> transactions,
    Map<String, TransactionMetadata> metadata) {
  return [
    for (final t in transactions)
      if (t.type == 'expense' &&
          t.categoryId == 'food_exp' &&
          !t.id.startsWith('investment:') &&
          (metadata[t.id]?.subcategory ?? '').isEmpty)
        if (foodSubcategory(t.description) case final sub?) (t, sub)
  ];
}
