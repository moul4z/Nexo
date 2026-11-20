import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/app_provider.dart';
import '../services/import_rules_service.dart';
import '../widgets/nexo_ui.dart';

class ImportRulesScreen extends StatefulWidget {
  const ImportRulesScreen({super.key});
  @override
  State<ImportRulesScreen> createState() => _ImportRulesScreenState();
}

class _ImportRulesScreenState extends State<ImportRulesScreen> {
  late Future<List<ImportRule>> _rules = ImportRulesService.load();
  Future<void> _edit([ImportRule? rule]) async {
    final app = context.read<AppProvider>();
    final pattern = TextEditingController(text: rule?.pattern);
    final sub = TextEditingController(text: rule?.subcategory);
    var type = rule?.type ?? 'expense';
    String? category = rule?.categoryId;
    var auto = rule?.auto ?? false;
    String? target = rule?.targetAccountId;
    String? error;
    bool busy = false;
    await showDialog<void>(
        context: context,
        // The fields outlive the closing animation: they are released with
        // the dialog, not when it starts to close.
        builder: (ctx) => OwnsControllers(
            controllers: [pattern, sub],
            child: StatefulBuilder(builder: (ctx, update) {
              final plain = type == 'expense' || type == 'income';
              final cats = app.categories.where((c) => c.type == type).toList();
              if (!cats.any((c) => c.id == category)) category = null;
              final targets = app.cashAccounts.where((a) => !a.isGold).toList();
              if (!targets.any((a) => a.id == target)) target = null;
              return AlertDialog(
                  title: Text(rule == null ? 'Nova regra' : 'Editar regra'),
                  content: SingleChildScrollView(
                      child: Column(mainAxisSize: MainAxisSize.min, children: [
                    TextField(
                        controller: pattern,
                        decoration: const InputDecoration(
                            labelText: 'Descrição contém',
                            hintText: 'Ex.: UBER')),
                    DropdownButtonFormField<String>(
                        initialValue: type,
                        isExpanded: true,
                        items: const [
                          DropdownMenuItem(
                              value: 'expense', child: Text('Despesa')),
                          DropdownMenuItem(
                              value: 'income', child: Text('Receita')),
                          DropdownMenuItem(
                              value: 'transfer',
                              child: Text('Transferência entre contas suas')),
                          DropdownMenuItem(
                              value: 'internal',
                              child: Text('Não é lançamento (sai da fila)'))
                        ],
                        onChanged: busy
                            ? null
                            : (v) => update(() {
                                  type = v!;
                                  category = null;
                                })),
                    if (plain) ...[
                      DropdownButtonFormField<String>(
                          key: ValueKey('$type:$category'),
                          initialValue: category,
                          isExpanded: true,
                          decoration:
                              const InputDecoration(labelText: 'Categoria'),
                          items: cats
                              .map((c) => DropdownMenuItem(
                                  value: c.id,
                                  child: Text(c.name,
                                      overflow: TextOverflow.ellipsis)))
                              .toList(),
                          onChanged:
                              busy ? null : (v) => update(() => category = v)),
                      TextField(
                          controller: sub,
                          decoration: const InputDecoration(
                              labelText: 'Subcategoria (opcional)')),
                    ],
                    if (type == 'transfer')
                      DropdownButtonFormField<String>(
                          key: ValueKey('target:$target'),
                          initialValue: target,
                          isExpanded: true,
                          decoration: const InputDecoration(
                              labelText: 'A outra conta',
                              helperText:
                                  'Saída do banco: o dinheiro vai para ela. Entrada: vem dela.'),
                          items: targets
                              .map((a) => DropdownMenuItem(
                                  value: a.id,
                                  child: Text(a.name,
                                      overflow: TextOverflow.ellipsis)))
                              .toList(),
                          onChanged:
                              busy ? null : (v) => update(() => target = v)),
                    SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        value: auto,
                        onChanged: busy ? null : (v) => update(() => auto = v),
                        title: Text(type == 'internal'
                            ? 'Tirar da fila sozinho'
                            : 'Lançar sozinho'),
                        subtitle: const Text(
                            'Sem perguntar. Cada vez aparece em Para revisar › Resolvidas automaticamente e pode ser desfeito.')),
                    if (error != null)
                      Text(error!,
                          style: TextStyle(
                              color: Theme.of(ctx).colorScheme.error)),
                  ])),
                  actions: [
                    TextButton(
                        onPressed: busy ? null : () => Navigator.pop(ctx),
                        child: const Text('Cancelar')),
                    FilledButton(
                        onPressed: busy
                            ? null
                            : () async {
                                if (pattern.text.trim().isEmpty ||
                                    (plain && category == null)) {
                                  update(() => error =
                                      'Preencha a descrição e a categoria.');
                                  return;
                                }
                                if (type == 'transfer' && target == null) {
                                  update(() => error =
                                      'Escolha a outra conta da transferência.');
                                  return;
                                }
                                update(() => busy = true);
                                try {
                                  await ImportRulesService.save(ImportRule(
                                      id: rule?.id ?? app.newId(),
                                      pattern: pattern.text,
                                      type: type,
                                      categoryId: plain ? category! : '',
                                      subcategory: plain ? sub.text : '',
                                      auto: auto,
                                      targetAccountId:
                                          type == 'transfer' ? target : null));
                                  if (ctx.mounted) Navigator.pop(ctx);
                                } catch (e) {
                                  if (ctx.mounted)
                                    update(() {
                                      busy = false;
                                      // The service says what is missing.
                                      error = e is ArgumentError
                                          ? '${e.message}'
                                          : 'Não foi possível salvar. Revise a categoria e tente novamente.';
                                    });
                                }
                              },
                        child: const Text('Salvar'))
                  ]);
            })));
    if (mounted)
      setState(() {
        _rules = ImportRulesService.load();
      });
  }

  @override
  Widget build(BuildContext context) => Scaffold(
      appBar: AppBar(title: const Text('Regras do banco')),
      floatingActionButton: FloatingActionButton(
          onPressed: () => _edit(),
          tooltip: 'Nova regra',
          child: const Icon(Icons.add)),
      body: FutureBuilder<List<ImportRule>>(
          future: _rules,
          builder: (context, snapshot) {
            if (snapshot.hasError)
              return const Center(
                  child: Text('Não foi possível carregar as regras.'));
            if (!snapshot.hasData)
              return const Center(child: CircularProgressIndicator());
            return ListView(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
                children: [
                  const Text(
                      'Dizem o que fazer com um movimento do banco pelo texto dele: sugerir a categoria, tratar como transferência entre contas suas ou tirar da fila. O texto mais específico tem prioridade. Não alteram lançamentos antigos.'),
                  Wrap(spacing: 8, children: [
                    for (final example in const [
                      ('IFOOD', 'Delivery'),
                      ('UBER', 'Transporte por app'),
                      ('NETFLIX', 'Streaming'),
                      ('POSTO', 'Combustível')
                    ])
                      ActionChip(
                          label: Text('Exemplo: ${example.$1}'),
                          onPressed: () => _edit(ImportRule(
                              id: context.read<AppProvider>().newId(),
                              pattern: example.$1,
                              type: 'expense',
                              categoryId: '',
                              subcategory: example.$2))),
                  ]),
                  if (snapshot.data!.isEmpty)
                    const Padding(
                        padding: EdgeInsets.all(24),
                        child: Text(
                            'Crie sua primeira regra, por exemplo: UBER → Transporte.')),
                  for (final r in snapshot.data!)
                    ListTile(
                        title: Text(r.pattern),
                        subtitle:
                            Text(ruleSummary(r, context.read<AppProvider>())),
                        onTap: () => _edit(r),
                        trailing: IconButton(
                            tooltip: 'Excluir regra',
                            icon: const Icon(Icons.delete_outline),
                            onPressed: () async {
                              final confirmed = await showDialog<bool>(
                                  context: context,
                                  builder: (ctx) => AlertDialog(
                                          title: const Text('Excluir regra?'),
                                          content: Text(r.pattern),
                                          actions: [
                                            TextButton(
                                                onPressed: () =>
                                                    Navigator.pop(ctx, false),
                                                child: const Text('Cancelar')),
                                            TextButton(
                                                onPressed: () =>
                                                    Navigator.pop(ctx, true),
                                                child: const Text('Excluir'))
                                          ]));
                              if (confirmed != true) return;
                              try {
                                await ImportRulesService.delete(r.id);
                                if (mounted)
                                  setState(() {
                                    _rules = ImportRulesService.load();
                                  });
                              } catch (_) {
                                if (context.mounted)
                                  ScaffoldMessenger.of(context).showSnackBar(
                                      const SnackBar(
                                          content: Text(
                                              'Não foi possível excluir a regra.')));
                              }
                            }))
                ]);
          }));
}

/// What a rule does, in a line: the category, the transfer or "sai da fila",
/// and whether the app does it without asking.
String ruleSummary(ImportRule r, AppProvider app) {
  final what = switch (r.type) {
    'transfer' =>
      'Transferência com ${app.accountById(r.targetAccountId ?? '')?.name ?? 'conta removida'}',
    'internal' => 'Não é lançamento',
    _ => [
        app.categoryById(r.categoryId)?.name ?? 'Categoria removida',
        if (r.subcategory.isNotEmpty) r.subcategory
      ].join(' • '),
  };
  return r.auto
      ? '$what • ${r.type == 'internal' ? 'sai da fila sozinho' : 'lança sozinho'}'
      : what;
}
