import '../database/db_helper.dart';
import '../models/models.dart';
import 'package:sqflite/sqflite.dart';

/// "Description contains X → category Y". Types: expense and income (a
/// category), transfer (to [targetAccountId]: Pix to the broker) and
/// internal (between the person's own accounts: never an entry).
class ImportRule {
  final String id, pattern, type, categoryId, subcategory;

  /// "Lançar sozinho": a bank movement that matches becomes an entry (or a
  /// transfer) without asking, on the device that writes. Never over an
  /// entry that looks the same.
  final bool auto;
  final String? targetAccountId;
  const ImportRule(
      {required this.id,
      required this.pattern,
      required this.type,
      required this.categoryId,
      this.subcategory = '',
      this.auto = false,
      this.targetAccountId});

  static const types = ['expense', 'income', 'transfer', 'internal'];

  Map<String, Object?> toMap() => {
        'id': id,
        'pattern': pattern.trim(),
        'type': type,
        'category_id': categoryId,
        'subcategory': subcategory.trim(),
        'auto': auto ? 1 : 0,
        'target_account_id': targetAccountId,
      };
  factory ImportRule.fromMap(Map<String, dynamic> m) => ImportRule(
      id: m['id'],
      pattern: m['pattern'],
      type: m['type'],
      categoryId: m['category_id'] ?? '',
      subcategory: m['subcategory'] ?? '',
      auto: m['auto'] == 1,
      targetAccountId: m['target_account_id'] as String?);
}

class ImportRulesService {
  static Future<List<ImportRule>> load() async =>
      (await (await DBHelper.database).query('import_rules'))
          .map(ImportRule.fromMap)
          .toList();
  static Future<void> save(ImportRule rule) async {
    if (rule.pattern.trim().isEmpty || !ImportRule.types.contains(rule.type)) {
      throw ArgumentError('Informe o texto da descrição e o tipo.');
    }
    if (rule.auto && rule.pattern.trim().length < 3) {
      throw ArgumentError(
          'Para lançar sozinho, use pelo menos 3 letras do texto do banco.');
    }
    await DBHelper.operation('import_rule.save', (txn) async {
      if (rule.type == 'expense' || rule.type == 'income') {
        final cats = await txn.query('categories',
            where: 'id = ? AND type = ?',
            whereArgs: [rule.categoryId, rule.type]);
        if (cats.isEmpty)
          throw ArgumentError('Selecione uma categoria válida para o tipo.');
      }
      if (rule.type == 'transfer') {
        final target = rule.targetAccountId == null
            ? const <Map<String, Object?>>[]
            : await txn.query('accounts',
                where: "id = ? AND type NOT IN ('credit', 'gold')",
                whereArgs: [rule.targetAccountId]);
        if (target.isEmpty) {
          throw ArgumentError(
              'Escolha a conta de destino da transferência (não pode ser cartão).');
        }
      }
      await txn.insert(
          'import_rules',
          {
            ...rule.toMap(),
            if (rule.type == 'transfer' || rule.type == 'internal')
              'category_id': '',
            if (rule.type != 'transfer') 'target_account_id': null,
          },
          conflictAlgorithm: ConflictAlgorithm.replace);
    });
  }

  static Future<void> delete(String id) => DBHelper.operation(
      'import_rule.delete',
      (txn) => txn.delete('import_rules', where: 'id = ?', whereArgs: [id]));
  static ImportRule? match(List<ImportRule> rules, String description,
      String type, List<AppCategory> categories) {
    final candidates = rules
        .where((r) =>
            r.pattern.trim().isNotEmpty &&
            r.type == type &&
            description
                .toLowerCase()
                .contains(r.pattern.trim().toLowerCase()) &&
            categories.any((c) => c.id == r.categoryId && c.type == type))
        .toList()
      ..sort((a, b) {
        final length =
            b.pattern.trim().length.compareTo(a.pattern.trim().length);
        return length == 0 ? a.id.compareTo(b.id) : length;
      });
    return candidates.firstOrNull;
  }

  /// Candidates only: never merges or modifies balances.
  static List<AppTransaction> candidates(List<AppTransaction> transactions,
          {required String accountId,
          required DateTime date,
          required double amount,
          required String type}) =>
      transactions
          .where((t) =>
              t.accountId == accountId &&
              t.type == type &&
              (t.amount - amount).abs() < 0.005 &&
              DateTime(t.date.year, t.date.month, t.date.day)
                      .difference(DateTime(date.year, date.month, date.day))
                      .inDays
                      .abs() <=
                  3)
          .toList();
}
