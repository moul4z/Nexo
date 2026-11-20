// Parity with the app (29/10/2026): everything a screen does, the assistant
// can ask for. Reads come from the synced ledger with the app's rules;
// changes are requests the app applies through the same calls as its
// screens. Batch changes have a dry run, and every recorded request can be
// undone (undo_request).
import {
  analyze, cents, currencyOf, day, isCalendarDay, isNeutral, type Ledger, meta, metadataIndex, money, num, recurringCents,
  type Row, text,
} from "./finance.ts";
import { balanceCents, callTool, ToolInputError, type ToolDefinition } from "./tools.ts";
import { envelopeById, envelopes, spendingTypes } from "./envelopes.ts";
import { checkSetting, settingDefs, sharedSettings } from "./settings.ts";
import { cardInvoices, occurrences } from "./invoices.ts";
import { dailyAverage, projection, type SimEvent, simulate, walk } from "./cash.ts";
import { reconcileAccount } from "./inbox.ts";
import { FX_SCALE, lastRate, position, ratio } from "./portfolio.ts";
import { toMovement } from "./inbox.ts";
import { direction } from "./reconcile.ts";

type Args = Record<string, unknown>;
export type Enqueue = (kind: string, args: Record<string, unknown>) => Promise<{ id: string; status: string }>;
export interface ParityDeps {
  enqueue: Enqueue;
  request(id: string): Promise<{ id: string; kind: string; status: string; result?: Record<string, unknown> | null } | null>;
  recent?(limit: number): Promise<Record<string, unknown>[]>;
  /// Open Finance accounts with official card invoices (absent: older server).
  bankAccounts?(): Promise<Record<string, unknown>[]>;
  linkBankAccount?(accountId: string, nexoAccountId: string | null): Promise<number>;
  /// Bank movements still pending (absent: nothing is known about them here).
  suggestions?(limit: number): Promise<Record<string, unknown>[]>;
  /// Bank movements of a period, pending or decided (newer servers only).
  bankMovements?(fromMs: number, toMs: number): Promise<Record<string, unknown>[]>;
  /// The clock, for tests.
  now?(): number;
}

/// Category icons of the app, by position (1-based), mirroring
/// kCategoryIconOptions in lib/widgets/shared_widgets.dart.
export const categoryIcons = ["Banco", "Dinheiro", "Cartão", "Poupança", "Investimento", "Câmbio", "Carteira",
  "Dinheiro", "Comprovante", "Conta", "Dólar", "Presente", "Alimentação", "Café", "Lanche", "Mercado", "Casa",
  "Moradia", "Energia", "Água", "Internet", "Combustível", "Carro", "Ônibus", "Voo", "Táxi", "Bicicleta", "Trem",
  "Compras", "Carrinho", "Roupas", "Eletrônicos", "Saúde", "Saúde", "Hospital", "Academia", "Spa", "Cinema", "Jogos",
  "Música", "Livro", "Educação", "Esportes", "Viagem", "Trabalho", "Negócios", "Computador", "Pessoas", "Acordo",
  "Etiqueta", "Estrela", "Troféu", "Categoria", "Animais", "Criança", "Telefone", "Assinatura"];

const dateField = { type: "string", pattern: "^\\d{4}-\\d{2}-\\d{2}$" };
const amountField = { type: "number", exclusiveMinimum: 0, maximum: 1000000000, description: "Valor em reais" };
const idField = { type: "string" };
const colorField = { type: "string", pattern: "^#[0-9A-Fa-f]{6}$", description: "Cor #RRGGBB" };
const obj = (properties: Record<string, unknown>, required: string[] = []) => ({
  type: "object", properties, required, additionalProperties: false,
});
const typeIds = envelopes.map((e) => e.id);
const filterProps = {
  ids: { type: "array", items: idField, maxItems: 200, description: "Ids exatos (alternativa ao filtro)" },
  from: dateField, to: dateField, account_id: idField, category_id: idField,
  type: { type: "string", enum: ["expense", "income"] },
  search: { type: "string", maxLength: 80, description: "Trecho da descrição ou observação" },
  subcategory: { type: "string", maxLength: 60 },
  min_amount: { type: "number", minimum: 0 }, max_amount: { type: "number", minimum: 0 },
  status: { type: "string", enum: ["paid", "pending"] },
  dry_run: { type: "boolean", description: "true: só mostra quantos e quais seriam afetados, sem mudar nada" },
  expected_count: { type: "integer", minimum: 0, description: "Com filtro: a quantidade que o dry_run mostrou (protege contra mudanças entre a prévia e a aplicação)" },
};

export const readOnlyParity = new Set(["describe_app_capabilities", "get_spending_types", "get_settings",
  "list_requests", "get_import_rules", "get_monthly_trend", "get_net_worth", "get_cash_projection", "simulate_cash",
  "get_spending_breakdown", "get_bank_accounts", "reconcile_account"]);

export const parityActions: (ToolDefinition & { destructive?: boolean })[] = [
  {
    name: "describe_app_capabilities", title: "O que dá para fazer no Nexo",
    description: "Catálogo atual: entidades, campos editáveis, ações aceitas pelo app instalado em cada aparelho, configurações, tipos de gasto e ícones. Consulte quando não souber se algo é possível.",
    inputSchema: obj({}),
  },
  {
    name: "get_spending_types", title: "Orçamento por tipo de gasto",
    description: "A tela Orçamento → Por tipo de gasto: renda de referência, % e meta de cada tipo (Custos fixos, Conforto, Metas, Prazeres, Conhecimento, Liberdade financeira), quanto já foi usado, o que sobra e as categorias sem tipo.",
    inputSchema: obj({ month: { type: "string", pattern: "^\\d{4}-\\d{2}$", description: "AAAA-MM; padrão: mês atual" } }),
  },
  {
    name: "set_category_type", title: "Classificar categorias por tipo de gasto",
    description: `O botão Classificar: define o tipo de gasto de uma ou várias categorias de despesa. Tipos: ${typeIds.join(", ")}; null tira o tipo.`,
    inputSchema: obj({
      assignments: {
        type: "array", minItems: 1, maxItems: 100,
        items: obj({ category_id: idField, type: { type: ["string", "null"], enum: [...typeIds, null] } }, ["category_id", "type"]),
      },
    }, ["assignments"]),
  },
  {
    name: "set_spending_targets", title: "Ajustar metas por tipo de gasto",
    description: "O botão Ajustar: renda de referência (0 = usar a renda fixa do ciclo) e/ou % de cada tipo. As % precisam somar 100; mande todas as seis.",
    inputSchema: obj({
      reference_income: { type: "number", minimum: 0, maximum: 1000000000 },
      shares: obj(Object.fromEntries(typeIds.map((id) => [id, { type: "integer", minimum: 0, maximum: 100 }])), typeIds),
    }),
  },
  {
    name: "get_settings", title: "Configurações do app",
    description: "Configurações que o Claude pode ler e mudar: as compartilhadas (iguais em todos os aparelhos) e as de cada aparelho, com os valores aceitos.",
    inputSchema: obj({}),
  },
  {
    name: "set_setting", title: "Mudar configurações",
    description: "Muda uma ou mais configurações (veja get_settings). As compartilhadas valem para todos os aparelhos; as de aparelho valem no aparelho que gravar o pedido.",
    inputSchema: obj({ settings: { type: "object", description: "chave → valor, ex.: {\"weekStart\": \"sunday\"}" } }, ["settings"]),
  },
  {
    name: "update_category", title: "Editar categoria",
    description: `Muda nome, tipo de gasto (${typeIds.join(", ")} ou null), cor (#RRGGBB) e ícone (número de 1 a ${categoryIcons.length} ou o nome, veja describe_app_capabilities).`,
    inputSchema: obj({
      id: idField, name: { type: "string", minLength: 1, maxLength: 40 },
      spending_type: { type: ["string", "null"], enum: [...typeIds, null] }, color: colorField,
      icon: { type: ["integer", "string"] },
    }, ["id"]),
  },
  {
    name: "merge_categories", title: "Juntar categorias",
    description: "Move lançamentos, recorrentes, regras e o orçamento de uma categoria para outra do mesmo tipo e exclui a primeira. Não mexe em saldos. dry_run mostra o que seria movido.",
    destructive: true,
    inputSchema: obj({ from_id: idField, into_id: idField, dry_run: { type: "boolean" } }, ["from_id", "into_id"]),
  },
  {
    name: "update_transactions", title: "Alterar lançamentos em lote",
    description: "Reclassifica vários lançamentos de uma vez (categoria, subcategoria ou gasto pontual), por ids ou por filtro. Não mexe em saldos. Transferências e investimentos ficam de fora. Use dry_run antes; com filtro, mande expected_count.",
    inputSchema: obj({
      ...filterProps,
      set: obj({ category_id: idField, subcategory: { type: "string", maxLength: 60 },
        kind: { type: "string", enum: ["normal", "extraordinary"], description: "extraordinary = gasto pontual (fora das médias)" } }),
    }, ["set"]),
  },
  {
    name: "delete_transactions", title: "Apagar lançamentos em lote",
    description: "Apaga vários lançamentos comuns (saldos ajustados), por ids ou por filtro. Transferências e movimentações de investimento ficam de fora: apague a transferência com delete_transaction e a operação com delete_investment_operation. Use dry_run antes; com filtro, mande expected_count. Desfaz com undo_request.",
    destructive: true,
    inputSchema: obj(filterProps),
  },
  {
    name: "convert_to_balance_adjustment", title: "Transformar em ajuste de saldo",
    description: "Para acertos antigos lançados como receita ou despesa (ex.: categoria \"Ajuste de saldo\"): passam a ser ajuste neutro, sem mudar o saldo, e deixam de contar como receita ou gasto. Use dry_run antes.",
    inputSchema: obj(filterProps),
  },
  {
    name: "split_transaction", title: "Dividir em parcelas",
    description: "Transforma uma compra em N parcelas mensais que somam o mesmo total (a primeira leva os centavos que sobram). No cartão todas ficam no cartão; fora dele as seguintes viram contas pendentes.",
    inputSchema: obj({ id: idField, installments: { type: "integer", minimum: 2, maximum: 120 } }, ["id", "installments"]),
  },
  {
    name: "split_bill", title: "Dividir conta entre pessoas",
    description: "Divide uma despesa paga em partes iguais entre você e as pessoas informadas. Sua parte continua como gasto " +
      "(com os centavos que sobrarem); a parte dos outros sai do gasto, continua na conta ou na fatura do cartão e vira a receber " +
      "de cada pessoa. Quando o dinheiro chegar, use settle_lended com account_id.",
    inputSchema: obj({ id: idField, people: { type: "array", items: { type: "string", minLength: 1, maxLength: 60 }, minItems: 1, maxItems: 20 } }, ["id", "people"]),
  },
  {
    name: "duplicate_transaction", title: "Duplicar lançamento",
    description: "Cria um lançamento igual a outro (mesma conta, categoria e descrição), na data e valor informados ou nos do original.",
    inputSchema: obj({ id: idField, date: dateField, amount: amountField }, ["id"]),
  },
  {
    name: "undo_request", title: "Desfazer um pedido",
    description: "Desfaz um pedido já gravado (lançamento, edição, exclusão, lote, configuração…), voltando os dados e os saldos ao que eram. Recusa se algo mudou depois. Veja os pedidos com list_requests.",
    destructive: true,
    inputSchema: obj({ id: idField }, ["id"]),
  },
  {
    name: "list_requests", title: "Pedidos recentes do Claude",
    description: "O que o Claude pediu ao Nexo: tipo, quando, situação, mensagem e se ainda dá para desfazer.",
    inputSchema: obj({ limit: { type: "integer", minimum: 1, maximum: 100 } }),
  },
  {
    name: "update_budget", title: "Alterar orçamento",
    description: "Muda valor e período de um orçamento e se ele conta o período inteiro (full_period true: limite cheio desde o 1º dia) ou só a partir de hoje, com limite proporcional (false).",
    inputSchema: obj({ id: idField, amount: amountField, period: { type: "string", enum: ["monthly", "weekly"] }, full_period: { type: "boolean" } }, ["id"]),
  },
  {
    name: "archive_investment", title: "Retirar da carteira",
    description: "Retira da carteira uma posição zerada (o histórico fica) ou a traz de volta (archived false).",
    inputSchema: obj({ id: idField, archived: { type: "boolean" } }, ["id"]),
  },
  {
    name: "update_investment", title: "Corrigir dados do ativo",
    description: "Corrige nome, código (ticker) e corretora de um ativo (ids em get_investments). Quantidades, operações e dinheiro não mudam. Corretora vazia tira a corretora.",
    inputSchema: obj({ id: idField, name: { type: "string", minLength: 1, maxLength: 120 },
      ticker: { type: "string", pattern: "^[A-Za-z0-9][A-Za-z0-9.\\-]{0,11}$" },
      institution: { type: "string", maxLength: 120, description: "Corretora ou banco onde o ativo está" } }, ["id"]),
  },
  {
    name: "record_investment_event", title: "Desdobramento, grupamento ou bonificação",
    description: "Registra um evento da empresa num ativo (ids em get_investments): desdobramento (event split, from 1, to 2: cada ação vira duas), grupamento (reverse_split, from 10, to 1) ou bonificação (bonus, percent 10 para 10% e unit_cost, o custo em reais por ação nova do fato relevante; só ativos em reais). A quantidade sai do que havia no fim da data com (date). Nenhuma conta muda; o custo total só sobe na bonificação, que não conta como aporte. Fração do grupamento é leiloada e paga à parte: registre como venda quando o dinheiro cair.",
    inputSchema: obj({ investment_id: idField, event: { type: "string", enum: ["split", "reverse_split", "bonus"] },
      date: { ...dateField, description: "Data com: último dia com direito ao evento" },
      from: { type: "integer", minimum: 1, maximum: 1000 }, to: { type: "integer", minimum: 1, maximum: 1000 },
      percent: { type: "number", exclusiveMinimum: 0, maximum: 1000 },
      unit_cost: { type: "number", minimum: 0, maximum: 1000000, description: "Reais por ação nova" } },
      ["investment_id", "event", "date"]),
  },
  {
    name: "delete_investment_operation", title: "Apagar operação de investimento",
    description: "Apaga uma compra, venda, provento ou evento da empresa (ids em get_investments). A conta vinculada é estornada junto.",
    destructive: true,
    inputSchema: obj({ operation_id: idField }, ["operation_id"]),
  },
  {
    name: "link_investment_operation", title: "Vincular operação a uma conta",
    description: "Para operação antiga registrada sem conta: passa a movimentar a conta escolhida. Use só se o valor ainda não está no saldo dessa conta.",
    inputSchema: obj({ operation_id: idField, account_id: idField }, ["operation_id", "account_id"]),
  },
  {
    name: "add_loan", title: "Novo empréstimo ou financiamento",
    description: "Cadastra empréstimo/financiamento. account_id: conta de onde saem as parcelas; transfer_account_id: conta que recebeu o dinheiro (entra no saldo).",
    inputSchema: obj({
      name: { type: "string", minLength: 1, maxLength: 60 }, principal: amountField, start_date: dateField, end_date: dateField,
      interest_rate: { type: "number", minimum: 0, maximum: 1000, description: "% ao ano" },
      account_id: idField, transfer_account_id: idField, reminder_day: { type: "integer", minimum: 1, maximum: 31 },
      notes: { type: "string", maxLength: 200 },
    }, ["name", "principal", "start_date", "end_date"]),
  },
  {
    name: "update_loan", title: "Alterar empréstimo",
    description: "Muda dados de um empréstimo (null tira a conta). settled true marca como quitado.",
    inputSchema: obj({
      id: idField, name: { type: "string", minLength: 1, maxLength: 60 }, principal: amountField, start_date: dateField, end_date: dateField,
      interest_rate: { type: ["number", "null"], minimum: 0, maximum: 1000 }, account_id: { type: ["string", "null"] },
      transfer_account_id: { type: ["string", "null"] }, reminder_day: { type: "integer", minimum: 1, maximum: 31 },
      notes: { type: "string", maxLength: 200 }, settled: { type: "boolean" },
    }, ["id"]),
  },
  {
    name: "delete_loan", title: "Excluir empréstimo", destructive: true,
    description: "Exclui um empréstimo e seus pagamentos, estornando as contas.",
    inputSchema: obj({ id: idField }, ["id"]),
  },
  {
    name: "delete_loan_payment", title: "Apagar pagamento de parcela", destructive: true,
    description: "Apaga um pagamento de parcela (ids em get_loans); a conta é estornada.",
    inputSchema: obj({ payment_id: idField }, ["payment_id"]),
  },
  {
    name: "update_lended", title: "Alterar empréstimo pessoal",
    description: "Muda valor, vencimento (null tira) ou observação de dinheiro emprestado/devido. A conta vinculada é corrigida pela diferença.",
    inputSchema: obj({ id: idField, amount: amountField, due_date: { type: ["string", "null"] }, notes: { type: "string", maxLength: 200 } }, ["id"]),
  },
  {
    name: "delete_lended", title: "Excluir empréstimo pessoal", destructive: true,
    description: "Exclui um registro; se estava em aberto, a conta vinculada é estornada.",
    inputSchema: obj({ id: idField }, ["id"]),
  },
  {
    name: "update_person", title: "Alterar pessoa",
    description: "Renomeia ou anota uma pessoa da lista de empréstimos pessoais.",
    inputSchema: obj({ id: idField, name: { type: "string", minLength: 1, maxLength: 60 }, notes: { type: "string", maxLength: 200 } }, ["id"]),
  },
  {
    name: "delete_person", title: "Excluir pessoa", destructive: true,
    description: "Exclui uma pessoa sem valores em aberto.",
    inputSchema: obj({ id: idField }, ["id"]),
  },
  {
    name: "get_import_rules", title: "Regras automáticas de categoria",
    description: "Regras \"descrição contém X → categoria Y\" que o app usa para sugerir a categoria de sugestões do banco e importações.",
    inputSchema: obj({}),
  },
  {
    name: "save_import_rule", title: "Criar ou alterar regra do banco",
    description: "Regra para movimentos do banco cujo texto contém pattern. kind expense ou income (padrão: o tipo da categoria): sugere a categoria. kind transfer: é dinheiro entre contas suas, com target_account_id como destino (ex.: depósito numa casa de apostas ou corretora cadastrada como conta). kind internal: movimento que não é lançamento (sai da fila). auto true: o app registra sozinho, sem perguntar, e mostra em Resolvidas automaticamente (pode ser desfeito); use só quando a pessoa pedir e com pattern específico. Não altera lançamentos antigos nem saldos. Com id altera a regra.",
    inputSchema: obj({ id: idField, pattern: { type: "string", minLength: 2, maxLength: 60 }, category_id: idField,
      subcategory: { type: "string", maxLength: 60 },
      kind: { type: "string", enum: ["expense", "income", "transfer", "internal"] },
      auto: { type: "boolean", description: "true: lançar sozinho (pattern com 3 letras ou mais)" },
      target_account_id: { ...idField, description: "Só para kind transfer: a conta de destino (não pode ser cartão)" },
    }, ["pattern"]),
  },
  {
    name: "delete_import_rule", title: "Excluir regra de categoria", destructive: true,
    description: "Exclui uma regra automática.",
    inputSchema: obj({ id: idField }, ["id"]),
  },
  {
    name: "confirm_suggestion_as_transfer", title: "Sugestão do banco como transferência",
    description: "Registra uma sugestão do Open Finance como transferência entre duas contas suas (não é gasto nem receita). Pagamento de fatura de cartão não é aqui: use pay_card_invoice (o app liga a sugestão ao pagamento sozinho); uma transferência para o cartão não dá baixa na fatura.",
    inputSchema: obj({ id: idField, from_account_id: idField, to_account_id: idField }, ["id", "from_account_id", "to_account_id"]),
  },
  {
    name: "link_suggestion", title: "Vincular sugestão a um lançamento",
    description: "Liga uma sugestão do Open Finance a um lançamento que já existe (a mesma movimentação, já lançada): ela sai da fila e nada é lançado de novo. Saída liga a despesa e entrada a receita; uma perna de transferência só responde por uma movimentação do mesmo valor. Para o IOF de uma compra internacional cobrado depois, add_amount true soma o valor ao lançamento da compra (só despesa comum: nunca transferência, investimento, conta dividida ou ajuste).",
    inputSchema: obj({ id: idField, transaction_id: idField,
      add_amount: { type: "boolean", description: "true: soma o valor da sugestão ao lançamento (IOF da compra). Padrão: só vincula." } },
    ["id", "transaction_id"]),
  },
  {
    name: "get_bank_accounts", title: "Saldo do banco × Nexo",
    description: "Contas do Open Finance: saldo informado pelo banco, limite e faturas oficiais dos cartões, a conta do Nexo vinculada e a diferença para o saldo do Nexo (soma de várias contas do banco quando vinculadas à mesma). Para acertar, use adjust_account_balance.",
    inputSchema: obj({}),
  },
  {
    name: "reconcile_account", title: "Conferir conta com o banco",
    description: "Compara uma conta ou cartão do Nexo com o que os bancos vinculados enviaram num período: o que está no banco e não no Nexo, o que está no Nexo e nenhum movimento do banco confirma, e quanto da diferença entre os dois saldos isso explica. Use antes de qualquer adjust_account_balance. Só leitura.",
    inputSchema: obj({
      account_id: { ...idField, description: "Conta ou cartão do Nexo (get_accounts)" },
      from: { type: "string", description: "AAAA-MM-DD. Padrão: 30 dias antes de to" },
      to: { type: "string", description: "AAAA-MM-DD. Padrão: hoje" },
    }, ["account_id"]),
  },
  {
    name: "link_bank_account", title: "Vincular conta do banco",
    description: "Liga uma conta do Open Finance (account_id de get_bank_accounts) a uma conta ou cartão do Nexo, para a conferência de saldo e fatura; null desfaz o vínculo. Não mexe em saldos.",
    inputSchema: obj({ account_id: idField, nexo_account_id: { type: ["string", "null"] } }, ["account_id", "nexo_account_id"]),
  },
  {
    name: "refresh_bank_data", title: "Pedir leitura dos bancos",
    description: "Pede ao app que busque agora as movimentações do Open Finance (o servidor lê no máximo uma vez por hora; os bancos atualizam uma vez por dia).",
    inputSchema: obj({}),
  },
  {
    name: "get_monthly_trend", title: "Tendência mês a mês",
    description: "Receita, consumo, resultado, taxa de poupança e maior categoria de cada um dos últimos meses (mês atual até hoje).",
    inputSchema: obj({ months: { type: "integer", minimum: 2, maximum: 24 } }),
  },
  {
    name: "get_net_worth", title: "Patrimônio líquido",
    description: "Contas, cartões, investimentos (pela última cotação), bens, empréstimos a pagar e dinheiro emprestado, somados em patrimônio. Mostra cada parte.",
    inputSchema: obj({}),
  },
  {
    name: "get_cash_projection", title: "Projeção de caixa até uma data",
    description: "Saldo das contas hoje + receitas e despesas recorrentes previstas + contas pendentes + faturas que vencem até a data. Estimativa explicada item a item. Devolve safe_per_day: quanto dá para gastar por dia, a partir de amanhã, sem ficar negativo até a data. Com daily_spending (\"average\" = média das últimas 4 semanas, à vista e no cartão separados; ou um valor por dia em reais), inclui o gasto do dia a dia como estimativa.",
    inputSchema: obj({ until: dateField,
      daily_spending: { description: '"average" ou um valor por dia em reais (gasto à vista).', anyOf: [{ type: "string", enum: ["average"] }, { type: "number", minimum: 0 }] } }, ["until"]),
  },
  {
    name: "simulate_cash", title: "Simular o caixa (e se…)",
    description: "Só leitura, nada é gravado: a projeção de caixa até a data com eventos hipotéticos (entrada, saída, venda de bem, venda de investimento que cai na liquidação, pagamento parcial de fatura com o resto e juros estimados na fatura seguinte). Devolve o ponto mais baixo, quanto falta e a diferença no fim. Mesma regra da tela Simular do app.",
    inputSchema: obj({
      until: dateField,
      daily_spending: { description: '"average" ou um valor por dia em reais (gasto à vista).', anyOf: [{ type: "string", enum: ["average"] }, { type: "number", minimum: 0 }] },
      events: { type: "array", minItems: 1, maxItems: 20, items: obj({
        kind: { type: "string", enum: ["income", "expense", "sell_asset", "sell_investment", "partial_invoice"] },
        date: { ...dateField, description: "Dia do evento; na venda de investimento, o dia da ordem. Sem data: hoje." },
        amount: { type: "number", exclusiveMinimum: 0, maximum: 1000000000, description: "Em reais. No pagamento parcial, quanto você paga da fatura (o mínimo está em get_card_invoices/get_bank_accounts)." },
        label: { type: "string", maxLength: 80 },
        investment_id: { type: "string", description: "sell_investment: o investimento (get_investments)" },
        card_id: { type: "string", description: "partial_invoice: o cartão; vale a primeira fatura dele que vence até a data" },
      }, ["kind", "amount"]) },
    }, ["until", "events"]),
  },
  {
    name: "get_spending_breakdown", title: "Consumo agrupado",
    description: "Consumo de um período agrupado por categoria, conta, subcategoria, dia da semana, tipo de gasto ou estabelecimento (descrição). Mesma regra de consumo do app.",
    inputSchema: obj({ from: dateField, to: dateField,
      by: { type: "string", enum: ["category", "account", "subcategory", "weekday", "spending_type", "merchant"] } }, ["from", "to", "by"]),
  },
];

// ── Helpers ───────────────────────────────────────────────────────────────
function only(args: Args, allowed: string[]) {
  const extra = Object.keys(args).filter((k) => !allowed.includes(k));
  if (extra.length) throw new ToolInputError(`Parâmetros não suportados: ${extra.join(", ")}.`);
}
function str(args: Args, key: string, max: number, required = true): string | undefined {
  const v = args[key];
  if (v === undefined && !required) return undefined;
  if (typeof v !== "string" || !v.trim() || v.length > max) throw new ToolInputError(`${key} é obrigatório (até ${max} caracteres).`);
  return v.trim();
}
function reais(v: unknown, key: string): number {
  if (typeof v !== "number" || !isFinite(v) || v <= 0 || v > 1e9) throw new ToolInputError(`${key} deve ser um valor positivo em reais.`);
  const c = Math.round(v * 100);
  if (Math.abs(c - v * 100) > 1e-6) throw new ToolInputError(`${key} aceita no máximo 2 casas decimais.`);
  return c;
}
function dateArg(v: unknown, key: string): string {
  if (!isCalendarDay(v)) {
    throw new ToolInputError(`${key} deve ser uma data que existe, no formato AAAA-MM-DD.`);
  }
  return v;
}
function bool(v: unknown, key: string): boolean | undefined {
  if (v === undefined) return undefined;
  if (typeof v !== "boolean") throw new ToolInputError(`${key} deve ser verdadeiro ou falso.`);
  return v;
}
const find = (rows: Row[] | undefined, id: unknown) => (rows ?? []).find((r) => text(r.id) === id);

function account(l: Ledger, id: unknown, noCredit = false) {
  const a = find(l.accounts, id);
  if (!a) throw new ToolInputError("Conta não encontrada. Use get_accounts.");
  if (noCredit && a.type === "credit") throw new ToolInputError("Use uma conta, não um cartão de crédito.");
  return a;
}
function category(l: Ledger, id: unknown) {
  const c = find(l.categories, id);
  if (!c) throw new ToolInputError("Categoria não encontrada. Use get_categories.");
  return c;
}
function color(v: unknown): number | undefined {
  if (v === undefined) return undefined;
  if (typeof v !== "string" || !/^#[0-9A-Fa-f]{6}$/.test(v)) throw new ToolInputError("color deve ser #RRGGBB.");
  return 0xFF000000 + parseInt(v.slice(1), 16);
}
function icon(v: unknown): number | undefined {
  if (v === undefined) return undefined;
  if (typeof v === "number" && Number.isInteger(v) && v >= 1 && v <= categoryIcons.length) return v;
  if (typeof v === "string") {
    const i = categoryIcons.findIndex((n) => n.toLowerCase() === v.trim().toLowerCase());
    if (i >= 0) return i + 1;
  }
  throw new ToolInputError(`icon: use um número de 1 a ${categoryIcons.length} ou um nome de describe_app_capabilities.`);
}
const pending = (id: string, what: string) => ({
  request_id: id,
  status: "pendente",
  message: `Pedido enviado ao Nexo (${what}). O celular ou o PC grava sozinho, mesmo com o app fechado (em segundos com o aviso do servidor, ou na checagem de 15 em 15 min); confira com get_request_status.`,
});
const isPlain = (l: Ledger, t: Row) => {
  const id = text(t.id);
  const source = meta(metadataIndex(l).get(id)).source;
  return !id.startsWith("investment:") && !source.startsWith("transfer:") && !source.startsWith("investment:");
};

/// A filter of the wrong type is refused, never dropped: without it the
/// batch would take more entries than the person asked for.
function checkFilter(args: Args) {
  for (const k of ["account_id", "category_id", "subcategory"]) {
    if (args[k] !== undefined && typeof args[k] !== "string") throw new ToolInputError(`${k} deve ser um texto.`);
  }
  if (args.search !== undefined && (typeof args.search !== "string" || !args.search.trim() || args.search.length > 80)) {
    throw new ToolInputError("search deve ser um texto de 1 a 80 letras.");
  }
  if (args.type !== undefined && args.type !== "expense" && args.type !== "income") {
    throw new ToolInputError("type deve ser expense ou income.");
  }
  if (args.status !== undefined && args.status !== "paid" && args.status !== "pending") {
    throw new ToolInputError("status deve ser paid ou pending.");
  }
  for (const k of ["min_amount", "max_amount"]) {
    const v = args[k];
    if (v !== undefined && (typeof v !== "number" || !isFinite(v) || v < 0)) {
      throw new ToolInputError(`${k} deve ser um valor em reais, zero ou mais.`);
    }
  }
  if (typeof args.min_amount === "number" && typeof args.max_amount === "number" && args.min_amount > args.max_amount) {
    throw new ToolInputError("min_amount não pode ser maior que max_amount.");
  }
  const n = args.expected_count;
  if (n !== undefined && (typeof n !== "number" || !Number.isInteger(n) || n < 0)) {
    throw new ToolInputError("expected_count deve ser um inteiro, zero ou mais.");
  }
}

/// Entries chosen by ids or by a filter, for batch tools.
function select(l: Ledger, args: Args, opts: { allowAdjustments?: boolean; allowInvestments?: boolean } = {}) {
  const metas = metadataIndex(l);
  const ids = args.ids;
  let rows: Row[];
  let byFilter = false;
  if (ids !== undefined) {
    if (!Array.isArray(ids) || ids.length === 0 || ids.length > 200 || ids.some((i) => typeof i !== "string")) {
      throw new ToolInputError("ids deve ser uma lista de 1 a 200 ids.");
    }
    const filterKeys = ["from", "to", "account_id", "category_id", "type", "search", "subcategory", "min_amount", "max_amount", "status"];
    if (filterKeys.some((k) => args[k] !== undefined)) throw new ToolInputError("Use ids ou filtro, não os dois.");
    rows = (ids as string[]).map((id) => {
      const t = find(l.transactions, id);
      if (!t) throw new ToolInputError(`Lançamento não encontrado: ${id}.`);
      return t;
    });
  } else {
    byFilter = true;
    checkFilter(args);
    const from = args.from === undefined ? undefined : dateArg(args.from, "from");
    const to = args.to === undefined ? undefined : dateArg(args.to, "to");
    if (!from && !to && args.category_id === undefined && args.account_id === undefined && args.search === undefined &&
      args.subcategory === undefined) {
      throw new ToolInputError("Informe ids ou um filtro (período, conta, categoria, busca ou subcategoria).");
    }
    const search = typeof args.search === "string" ? args.search.toLowerCase() : undefined;
    const min = typeof args.min_amount === "number" ? Math.round(args.min_amount * 100) : undefined;
    const max = typeof args.max_amount === "number" ? Math.round(args.max_amount * 100) : undefined;
    rows = l.transactions.filter((t) => {
      const d = day(text(t.date));
      const m = meta(metas.get(text(t.id)));
      const v = cents(num(t.amount));
      return (!from || d >= from) && (!to || d <= to) &&
        (args.account_id === undefined || t.account_id === args.account_id) &&
        (args.category_id === undefined || t.category_id === args.category_id) &&
        (args.type === undefined || t.type === args.type) &&
        (args.subcategory === undefined || m.subcategory === args.subcategory) &&
        (args.status === undefined || m.status === args.status) &&
        (min === undefined || v >= min) && (max === undefined || v <= max) &&
        (search === undefined || `${text(t.description)} ${text(t.note)}`.toLowerCase().includes(search));
    });
  }
  const investment = (t: Row) => text(t.id).startsWith("investment:") ||
    meta(metas.get(text(t.id))).source.startsWith("investment:");
  const skipped = rows.filter((t) => (!isPlain(l, t) && !(opts.allowInvestments && investment(t))) ||
    (!opts.allowAdjustments && meta(metas.get(text(t.id))).source === "opening_balance"));
  const chosen = rows.filter((t) => !skipped.includes(t));
  if (chosen.length > 200) {
    throw new ToolInputError(`O filtro pega ${chosen.length} lançamentos; o máximo por pedido é 200. Restrinja o período.`);
  }
  return { chosen, skipped, byFilter };
}

function preview(l: Ledger, chosen: Row[], skipped: Row[], note: string) {
  return {
    dry_run: true,
    would_change: chosen.length,
    total: money(chosen.reduce((s, t) => s + cents(num(t.amount)), 0)),
    items: chosen.slice(0, 50).map((t) => ({
      id: text(t.id), date: day(text(t.date)), type: t.type, amount: money(cents(num(t.amount))),
      description: text(t.description), account: text(find(l.accounts, t.account_id)?.name),
      category: text(find(l.categories, t.category_id)?.name) || undefined,
    })),
    skipped: skipped.length ? { count: skipped.length, why: "transferências, investimentos ou ajustes de saldo ficam de fora" } : undefined,
    note,
  };
}

function guardCount(args: Args, byFilter: boolean, count: number) {
  if (!byFilter) return;
  const expected = args.expected_count;
  if (expected === undefined) {
    throw new ToolInputError(`Com filtro, rode antes com dry_run: true e mande expected_count (agora seriam ${count}).`);
  }
  if (expected !== count) {
    throw new ToolInputError(`O filtro agora pega ${count} lançamentos, não ${expected}. Rode o dry_run de novo.`);
  }
}

const addDays = (iso: string, n: number) => {
  const d = new Date(`${iso}T00:00:00Z`);
  d.setUTCDate(d.getUTCDate() + n);
  return d.toISOString().slice(0, 10);
};
const addMonths = (iso: string, n: number, dayOfMonth: number) => {
  const [y, m] = iso.split("-").map(Number);
  const base = new Date(Date.UTC(y, m - 1 + n, 1));
  const last = new Date(Date.UTC(base.getUTCFullYear(), base.getUTCMonth() + 1, 0)).getUTCDate();
  return new Date(Date.UTC(base.getUTCFullYear(), base.getUTCMonth(), Math.min(dayOfMonth, last))).toISOString().slice(0, 10);
};

/// When a card charges next. The bank only reports an invoice after it
/// closes, and keeps the last due date it sent: a day that has passed is
/// never "next". Order: the official invoice still to pay, the card's cycle
/// in the Nexo, the date of the bank when it is still ahead.
function nextDue(l: Ledger, r: Record<string, unknown>, today: string): Record<string, unknown> {
  if (r.type !== "CREDIT") return {};
  const bills = Array.isArray(r.bills) ? r.bills as Record<string, unknown>[] : [];
  const official = bills
    .filter((b) => typeof b.due_date === "string" && b.due_date >= today && num(b.total_cents) > num(b.paid_cents))
    .map((b) => b.due_date as string).sort()[0];
  if (official) return { next_due: official, next_due_source: "fatura oficial do banco" };
  const card = typeof r.nexo_account_id === "string" ? find(l.accounts, r.nexo_account_id) : undefined;
  if (card && card.type === "credit") {
    const mine = (cardInvoices(l, today, text(card.id)).cards[0]?.invoices ?? [])
      .filter((i) => i.due_date && i.due_date >= today && cents(i.expected_remaining ?? i.remaining) > 0)
      .map((i) => i.due_date as string).sort()[0];
    if (mine) {
      return { next_due: mine, next_due_source: "ciclo do cartão no Nexo (o banco só informa a fatura depois do fechamento)" };
    }
  }
  if (typeof r.due_date === "string" && r.due_date >= today) return { next_due: r.due_date, next_due_source: "banco" };
  return typeof r.due_date === "string" ? { last_due_reported_by_bank: r.due_date } : {};
}

// ── Dispatch ─────────────────────────────────────────────────────────────
export async function callParityAction(name: string, rawArgs: unknown, l: Ledger, today: string,
  deps: ParityDeps): Promise<Record<string, unknown> | null> {
  const args = (rawArgs ?? {}) as Args;
  if (typeof args !== "object" || Array.isArray(args)) throw new ToolInputError("Argumentos inválidos.");
  const enqueue = deps.enqueue;
  switch (name) {
    case "describe_app_capabilities": {
      only(args, []);
      const devices = (l.devices ?? []).map((d) => ({
        app_version: d.app_version, last_seen: d.seen_at,
        kinds: Array.isArray(d.kinds) ? d.kinds : [],
      }));
      return {
        how_it_works: "Leituras vêm da última sincronização. Mudanças viram pedidos que o app grava com as próprias regras, um de cada vez, na ordem; confirme com get_request_status. Todo pedido gravado pode ser desfeito com undo_request. Lotes têm dry_run. Mande idempotency_key para repetir um pedido com segurança.",
        consumption_rule: "Transferências, reservas/objetivos, pagamentos de fatura, ajustes de saldo e aportes não contam como consumo; pendente não sai do saldo.",
        entities: {
          lançamentos: { read: ["list_transactions", "get_transaction", "get_daily_digest"], write: ["add_transaction", "add_transactions", "update_transaction", "delete_transaction", "settle_transaction", "duplicate_transaction", "split_transaction", "split_bill", "update_transactions", "delete_transactions", "convert_to_balance_adjustment"],
            editable: ["amount", "description", "account_id", "category_id", "date", "note", "type", "subcategory", "status", "due_date", "kind", "recurring_income_id"] },
          contas_e_cartões: { read: ["get_accounts", "get_card_invoices"], write: ["add_account", "update_account", "adjust_account_balance", "delete_account", "add_transfer", "pay_card_invoice"],
            editable: ["name", "statement_day", "due_day", "credit_limit", "exclude_from_total", "exclude_from_bank_total", "payment_account_id", "min_payment", "min_payment_percent", "color", "reminder_enabled", "reminder_time"] },
          categorias: { read: ["get_categories"], write: ["add_category", "rename_category", "update_category", "set_category_type", "merge_categories", "delete_category"],
            editable: ["name", "spending_type", "color", "icon"] },
          orçamento: { read: ["get_budgets", "get_spending_types"], write: ["set_budget", "update_budget", "delete_budget", "set_category_type", "set_spending_targets"] },
          objetivos: { read: ["get_goals"], write: ["add_goal", "update_goal", "move_goal", "delete_goal"], editable: ["name", "target", "target_date", "completed", "color"] },
          recorrentes: { read: ["get_recurring", "get_upcoming_bills"], write: ["add_recurring", "update_recurring", "pay_recurring", "skip_recurring", "delete_recurring"],
            editable: ["name", "amount", "account_id", "category_id", "next_date", "end_date", "frequency", "every", "kind", "notes", "reminder_enabled", "reminder_time"] },
          investimentos: { read: ["get_investment_summary", "get_investments"], write: ["add_investment", "record_investment_operation", "update_investment_price", "update_investment", "record_investment_event", "archive_investment", "delete_investment_operation", "link_investment_operation"] },
          empréstimos: { read: ["get_loans"], write: ["add_loan", "update_loan", "delete_loan", "pay_loan_installment", "skip_loan_installment", "delete_loan_payment"] },
          emprestado_e_devido: { read: ["get_lended"], write: ["add_lended", "update_lended", "settle_lended", "delete_lended", "update_person", "delete_person"] },
          bens_e_desejos: { read: ["get_assets", "get_wishlist"], write: ["add_asset", "update_asset", "delete_asset", "add_wishlist_item", "update_wishlist_item", "delete_wishlist_item"] },
          open_finance: { read: ["list_suggestions", "get_bank_sync_status", "get_import_rules", "get_bank_accounts", "reconcile_account"], write: ["confirm_suggestion", "confirm_suggestion_as_transfer", "link_suggestion", "ignore_suggestions", "save_import_rule", "delete_import_rule", "refresh_bank_data", "link_bank_account"] },
          configurações: { read: ["get_settings"], write: ["set_setting", "set_spending_targets"] },
          análises: { read: ["get_financial_summary", "get_spending_by_category", "get_spending_breakdown", "get_monthly_trend", "get_net_worth", "get_cash_projection", "simulate_cash"] },
          pedidos: { read: ["get_request_status", "list_requests", "describe_app_capabilities"], write: ["undo_request"] },
        },
        spending_types: envelopes.map((e) => ({ id: e.id, name: e.name, default_percent: e.defaultShare, what: e.hint })),
        category_icons: categoryIcons.map((name, i) => ({ icon: i + 1, name })),
        settings: settingDefs.map((d) => ({ key: d.key, label: d.label, shared: d.shared === true, values: d.values })),
        devices,
        not_in_the_app: ["anexos e etiquetas (o app não tem)", "pausar recorrente (use end_date ou skip_recurring)", "reconectar banco no Meu Pluggy (feito pela pessoa no site do Pluggy)", "exportar arquivo ou backup (o arquivo fica no aparelho; peça à pessoa)"],
      };
    }
    case "get_spending_types": {
      only(args, ["month"]);
      const month = args.month ?? today.slice(0, 7);
      if (typeof month !== "string" || !/^\d{4}-(0[1-9]|1[0-2])$/.test(month)) throw new ToolInputError("month deve ser AAAA-MM.");
      const s = sharedSettings(l);
      const shares = s.envelopeShares as Record<string, number>;
      const report = spendingTypes(l, month, shares, num(s.referenceIncome));
      return {
        ...report,
        note: report.reference_income === null
          ? "Sem renda de referência configurada o app usa a renda fixa do ciclo (recorrentes de receita), que só ele calcula; por isso as metas em reais não aparecem aqui. Defina com set_spending_targets."
          : "Metas = renda de referência × %. Liberdade financeira e Metas são o objetivo: passar delas não é estouro. Para classificar use set_category_type; para mudar % ou renda, set_spending_targets.",
      };
    }
    case "set_category_type": {
      only(args, ["assignments"]);
      const list = args.assignments;
      if (!Array.isArray(list) || list.length === 0 || list.length > 100) throw new ToolInputError("assignments deve ter de 1 a 100 itens.");
      const assignments = list.map((raw) => {
        const item = raw as Args;
        if (!item || typeof item !== "object") throw new ToolInputError("Item inválido em assignments.");
        only(item, ["category_id", "type"]);
        const c = category(l, item.category_id);
        if (text(c.type) === "income") throw new ToolInputError(`${text(c.name)} é de receita; só despesas têm tipo de gasto.`);
        if (item.type !== null && !envelopeById(item.type)) {
          throw new ToolInputError(`type deve ser ${typeIds.join(", ")} ou null.`);
        }
        return { id: text(c.id), envelope: item.type ?? null };
      });
      const q = await enqueue("category.envelope", { assignments });
      return { ...pending(q.id, "Classificação"), categories: assignments.length };
    }
    case "set_spending_targets": {
      only(args, ["reference_income", "shares"]);
      const values: Args = {};
      const goals = new Set((l.goals ?? []).map((g) => text(g.id)));
      for (const [key, v] of [["referenceIncome", args.reference_income], ["envelopeShares", args.shares]] as const) {
        if (v === undefined) continue;
        const checked = checkSetting(key, v, goals);
        if ("error" in checked) throw new ToolInputError(checked.error);
        values[key] = checked.ok;
      }
      if (!Object.keys(values).length) throw new ToolInputError("Informe reference_income e/ou shares.");
      const q = await enqueue("settings.set", { values });
      return { ...pending(q.id, "Metas por tipo de gasto"), applies_to: "todos os aparelhos" };
    }
    case "get_settings": {
      only(args, []);
      const shared = sharedSettings(l);
      const devices = (l.devices ?? []).map((d) => ({ app_version: d.app_version, last_seen: d.seen_at, settings: d.settings ?? null }));
      return {
        shared: settingDefs.filter((d) => d.shared).map((d) => ({ key: d.key, label: d.label, value: shared[d.key], values: d.values })),
        per_device: settingDefs.filter((d) => !d.shared).map((d) => ({ key: d.key, label: d.label, values: d.values })),
        devices,
        note: "Compartilhadas valem em todos os aparelhos. As de aparelho são do aparelho que gravar o pedido; devices mostra o valor que cada um informou.",
      };
    }
    case "set_setting": {
      only(args, ["settings"]);
      const s = args.settings;
      if (!s || typeof s !== "object" || Array.isArray(s) || !Object.keys(s).length) {
        throw new ToolInputError("settings deve ser um objeto chave → valor.");
      }
      const goals = new Set((l.goals ?? []).map((g) => text(g.id)));
      const values: Args = {};
      for (const [key, v] of Object.entries(s as Args)) {
        const checked = checkSetting(key, v, goals);
        if ("error" in checked) throw new ToolInputError(checked.error);
        values[key] = checked.ok;
      }
      const q = await enqueue("settings.set", { values });
      return pending(q.id, "Configuração");
    }
    case "update_category": {
      only(args, ["id", "name", "spending_type", "color", "icon"]);
      const c = category(l, args.id);
      const body: Args = { id: text(c.id) };
      const nm = str(args, "name", 40, false);
      if (nm) {
        if (l.categories.some((x) => x.id !== c.id && text(x.type) === text(c.type) && text(x.name).toLowerCase() === nm.toLowerCase())) {
          throw new ToolInputError("Já existe uma categoria com esse nome.");
        }
        body.name = nm;
      }
      if (args.spending_type !== undefined) {
        if (args.spending_type !== null && !envelopeById(args.spending_type)) throw new ToolInputError(`spending_type deve ser ${typeIds.join(", ")} ou null.`);
        if (args.spending_type !== null && text(c.type) === "income") throw new ToolInputError("Só categorias de despesa têm tipo de gasto.");
        body.envelope = args.spending_type;
      }
      const col = color(args.color);
      if (col !== undefined) body.color = col;
      const ic = icon(args.icon);
      if (ic !== undefined) body.icon = ic;
      if (Object.keys(body).length === 1) throw new ToolInputError("Informe o que deve mudar.");
      return pending((await enqueue("category.edit", body)).id, "Alteração da categoria");
    }
    case "merge_categories": {
      only(args, ["from_id", "into_id", "dry_run"]);
      const from = category(l, args.from_id), into = category(l, args.into_id);
      if (from.id === into.id) throw new ToolInputError("Escolha categorias diferentes.");
      if (text(from.type) !== text(into.type)) throw new ToolInputError("Só dá para juntar categorias do mesmo tipo.");
      const moved = l.transactions.filter((t) => t.category_id === from.id).length;
      const recurringMoved = l.recurring.filter((r) => r.category_id === from.id).length;
      const budget = (l.budgets ?? []).find((b) => b.category_id === from.id);
      const intoBudget = (l.budgets ?? []).find((b) => b.category_id === into.id);
      const summary = {
        from: text(from.name), into: text(into.name), transactions: moved, recurring: recurringMoved,
        budget: !budget ? "sem orçamento" : intoBudget ? `o orçamento de ${text(from.name)} é removido (fica o de ${text(into.name)})` : "o orçamento passa para a categoria de destino",
      };
      if (bool(args.dry_run, "dry_run")) return { dry_run: true, ...summary, note: "Prévia: nada mudou. Chame sem dry_run para aplicar." };
      const q = await enqueue("category.merge", { from_id: text(from.id), into_id: text(into.id) });
      return { ...pending(q.id, "Junção de categorias"), ...summary };
    }
    case "update_transactions": {
      only(args, [...Object.keys(filterProps), "set"]);
      const set = args.set as Args;
      if (!set || typeof set !== "object" || Array.isArray(set)) throw new ToolInputError("set é obrigatório.");
      only(set, ["category_id", "subcategory", "kind"]);
      if (!Object.keys(set).length) throw new ToolInputError("Informe em set o que deve mudar.");
      // Category and subcategory touch no money, so investment cash can take them.
      const { chosen, skipped, byFilter } = select(l, args, { allowInvestments: set.kind === undefined });
      if (set.category_id !== undefined) {
        const c = category(l, set.category_id);
        const wrong = chosen.find((t) => t.type !== (text(c.type) || "expense"));
        if (wrong) throw new ToolInputError(`A categoria ${text(c.name)} não serve para "${text(wrong.description)}" (tipo diferente). Filtre por type.`);
      }
      if (set.kind !== undefined && set.kind !== "normal" && set.kind !== "extraordinary") throw new ToolInputError("kind deve ser normal ou extraordinary.");
      if (set.subcategory !== undefined && (typeof set.subcategory !== "string" || set.subcategory.length > 60)) throw new ToolInputError("subcategory até 60 letras.");
      if (bool(args.dry_run, "dry_run")) return preview(l, chosen, skipped, "Prévia: nada mudou. Chame de novo sem dry_run (com expected_count, se usou filtro).");
      if (!chosen.length) throw new ToolInputError("Nenhum lançamento corresponde.");
      guardCount(args, byFilter, chosen.length);
      const q = await enqueue("transaction.bulk_update", {
        ids: chosen.map((t) => text(t.id)), category_id: set.category_id, subcategory: set.subcategory, expense_class: set.kind,
      });
      return { ...pending(q.id, "Alteração em lote"), count: chosen.length };
    }
    case "delete_transactions":
    case "convert_to_balance_adjustment": {
      only(args, Object.keys(filterProps));
      const deleting = name === "delete_transactions";
      const { chosen, skipped, byFilter } = select(l, args, { allowAdjustments: deleting });
      if (!deleting) {
        const metas = metadataIndex(l);
        const pend = chosen.find((t) => meta(metas.get(text(t.id))).status === "pending");
        if (pend) throw new ToolInputError(`"${text(pend.description)}" está pendente; um ajuste de saldo já aconteceu.`);
      }
      if (bool(args.dry_run, "dry_run")) {
        return preview(l, chosen, skipped, deleting
          ? "Prévia: nada foi apagado. Saldos seriam estornados. Chame de novo sem dry_run (com expected_count, se usou filtro)."
          : "Prévia: nada mudou. Os saldos ficam iguais; os itens deixam de contar como receita ou gasto.");
      }
      if (!chosen.length) throw new ToolInputError("Nenhum lançamento corresponde.");
      guardCount(args, byFilter, chosen.length);
      const q = await enqueue(deleting ? "transaction.bulk_delete" : "transaction.neutralize", { ids: chosen.map((t) => text(t.id)) });
      return { ...pending(q.id, deleting ? "Exclusão em lote" : "Conversão em ajuste de saldo"), count: chosen.length };
    }
    case "split_transaction": {
      only(args, ["id", "installments"]);
      const t = find(l.transactions, args.id);
      if (!t) throw new ToolInputError("Lançamento não encontrado.");
      if (!isPlain(l, t)) throw new ToolInputError("Transferências e investimentos não se dividem em parcelas.");
      const m = meta(metadataIndex(l).get(text(t.id)));
      if (m.installmentTotal) throw new ToolInputError("Este lançamento já é uma parcela.");
      const n = args.installments;
      if (typeof n !== "number" || !Number.isInteger(n) || n < 2 || n > 120) throw new ToolInputError("installments deve ser de 2 a 120.");
      const total = cents(num(t.amount));
      const each = Math.floor(total / n);
      const q = await enqueue("transaction.split", { id: text(t.id), installments: n });
      return { ...pending(q.id, "Divisão em parcelas"), first: money(each + total - each * n), each: money(each) };
    }
    case "split_bill": {
      only(args, ["id", "people"]);
      const t = find(l.transactions, args.id);
      if (!t) throw new ToolInputError("Lançamento não encontrado.");
      if (t.type && t.type !== "expense") throw new ToolInputError("Só despesa pode ser dividida.");
      const m = meta(metadataIndex(l).get(text(t.id)));
      if (!isPlain(l, t) || m.installmentTotal) throw new ToolInputError("Este lançamento não pode ser dividido.");
      if (m.status === "pending") throw new ToolInputError("Pague a despesa antes de dividir.");
      const people = args.people;
      if (!Array.isArray(people) || !people.length || people.length > 20 ||
        people.some((p) => typeof p !== "string" || !p.trim() || p.length > 60)) {
        throw new ToolInputError("people deve ter de 1 a 20 nomes.");
      }
      const names = [...new Set((people as string[]).map((p) => p.trim()))];
      const q = await enqueue("transaction.split_bill", { id: text(t.id), people: names });
      const total = cents(num(t.amount)), each = Math.floor(total / (names.length + 1));
      return { ...pending(q.id, "Divisão da conta"), each: money(each), yours: money(total - each * names.length) };
    }
    case "duplicate_transaction": {
      only(args, ["id", "date", "amount"]);
      const t = find(l.transactions, args.id);
      if (!t) throw new ToolInputError("Lançamento não encontrado.");
      if (!isPlain(l, t)) throw new ToolInputError("Transferências e investimentos não se duplicam; registre de novo.");
      const q = await enqueue("transaction.add", {
        type: t.type, amount_cents: args.amount === undefined ? cents(num(t.amount)) : reais(args.amount, "amount"),
        description: text(t.description), account_id: text(t.account_id), category_id: text(t.category_id),
        date: args.date === undefined ? today : dateArg(args.date, "date"), note: text(t.note),
      });
      return pending(q.id, "Cópia do lançamento");
    }
    case "undo_request": {
      only(args, ["id"]);
      const id = str(args, "id", 64)!;
      if (!/^[0-9a-f-]{36}$/.test(id)) throw new ToolInputError("id de pedido inválido.");
      const r = await deps.request(id);
      if (!r) throw new ToolInputError("Pedido não encontrado.");
      if (r.status === "pending" || r.status === "applying") {
        throw new ToolInputError("O pedido ainda não foi gravado; espere o app gravar para desfazer.");
      }
      if (r.status !== "done") throw new ToolInputError("O pedido foi recusado: não há o que desfazer.");
      const result = r.result ?? {};
      if (result.undone_at) throw new ToolInputError("Este pedido já foi desfeito.");
      const undo = result.undo as Record<string, unknown> | undefined;
      if (!undo) throw new ToolInputError("Este pedido não guardou como ser desfeito (versão anterior do app). Desfaça pelo app.");
      if (undo.too_large) throw new ToolInputError("Este pedido mexeu em dados demais para desfazer sozinho. Desfaça pelo app.");
      const q = await enqueue("request.undo", { request_id: id, undo });
      return pending(q.id, "Desfazer");
    }
    case "list_requests": {
      only(args, ["limit"]);
      const limit = args.limit ?? 20;
      if (typeof limit !== "number" || !Number.isInteger(limit) || limit < 1 || limit > 100) throw new ToolInputError("limit de 1 a 100.");
      if (!deps.recent) return { requests: [], note: "O servidor ainda não lista os pedidos." };
      const statusText: Record<string, string> = { pending: "pendente", applying: "gravando", done: "gravado", rejected: "recusado" };
      return {
        requests: (await deps.recent(limit)).map((r) => ({
          id: r.id, kind: r.kind, created_at: r.created_at,
          status: r.undone_at ? "desfeito" : statusText[String(r.status)] ?? r.status,
          message: r.message ?? undefined, reason: r.reason ?? undefined, undoable: r.undoable === true,
        })),
      };
    }
    case "update_budget": {
      only(args, ["id", "amount", "period", "full_period"]);
      const b = find(l.budgets, args.id);
      if (!b) throw new ToolInputError("Orçamento não encontrado. Use get_budgets.");
      const body: Args = { id: text(b.id), category_id: text(b.category_id), period: args.period ?? (text(b.period) || "monthly") };
      if (body.period !== "monthly" && body.period !== "weekly") throw new ToolInputError("period deve ser monthly ou weekly.");
      body.amount_cents = args.amount === undefined ? cents(num(b.amount)) : reais(args.amount, "amount");
      const full = bool(args.full_period, "full_period");
      if (full !== undefined) body.full_period = full;
      if (args.amount === undefined && args.period === undefined && full === undefined) throw new ToolInputError("Informe o que deve mudar.");
      return pending((await enqueue("budget.save", body)).id, "Alteração do orçamento");
    }
    case "archive_investment": {
      only(args, ["id", "archived"]);
      const inv = find(l.investments, args.id);
      if (!inv) throw new ToolInputError("Investimento não encontrado. Use get_investments.");
      const archived = bool(args.archived, "archived") ?? true;
      if (archived && position(inv, l.investmentOperations).quantity !== 0) {
        throw new ToolInputError("Encerre a posição (venda tudo) antes de retirá-la da carteira.");
      }
      return pending((await enqueue("investment.archive", { id: text(inv.id), archived })).id, archived ? "Retirada da carteira" : "Volta à carteira");
    }
    case "update_investment": {
      only(args, ["id", "name", "ticker", "institution"]);
      const inv = find(l.investments, args.id);
      if (!inv) throw new ToolInputError("Investimento não encontrado. Use get_investments.");
      const body: Args = { id: text(inv.id) };
      if (args.name !== undefined) {
        if (typeof args.name !== "string" || !args.name.trim() || args.name.length > 120) throw new ToolInputError("name: de 1 a 120 letras.");
        body.name = args.name.trim();
      }
      if (args.ticker !== undefined) {
        if (typeof args.ticker !== "string" || !/^[A-Za-z0-9][A-Za-z0-9.\-]{0,11}$/.test(args.ticker.trim())) {
          throw new ToolInputError("ticker: letras e números, até 12 caracteres.");
        }
        body.ticker = args.ticker.trim().toUpperCase();
      }
      if (args.institution !== undefined) {
        if (typeof args.institution !== "string" || args.institution.length > 120) throw new ToolInputError("institution: até 120 letras.");
        body.institution = args.institution.trim();
      }
      if (Object.keys(body).length === 1) throw new ToolInputError("Informe name, ticker ou institution.");
      return pending((await enqueue("investment.edit", body)).id, "Dados do ativo");
    }
    case "record_investment_event": {
      only(args, ["investment_id", "event", "date", "from", "to", "percent", "unit_cost"]);
      const inv = find(l.investments, args.investment_id);
      if (!inv) throw new ToolInputError("Investimento não encontrado. Use get_investments.");
      const event = args.event;
      if (event !== "split" && event !== "reverse_split" && event !== "bonus") {
        throw new ToolInputError("event deve ser split, reverse_split ou bonus.");
      }
      const body: Args = { investment_id: text(inv.id), event, date: dateArg(args.date, "date") };
      if (event === "bonus") {
        if ((text(inv.currency) || "BRL") !== "BRL") throw new ToolInputError("Bonificação só para ativos em reais por enquanto.");
        if (args.from !== undefined || args.to !== undefined) throw new ToolInputError("Bonificação usa percent, não from/to.");
        const p = args.percent;
        if (typeof p !== "number" || !(p > 0) || p > 1000 || Math.abs(Math.round(p * 100) - p * 100) > 1e-6) {
          throw new ToolInputError("percent: de 0,01 a 1000, com até 2 casas.");
        }
        const cost = args.unit_cost;
        if (typeof cost !== "number" || !(cost >= 0) || cost > 1000000 || Math.abs(Math.round(cost * 100) - cost * 100) > 1e-6) {
          throw new ToolInputError("unit_cost: o custo por ação nova em reais, com até 2 casas (0 se o fato relevante não der).");
        }
        body.percent = p;
        body.unit_cost_cents = Math.round(cost * 100);
      } else {
        if (args.percent !== undefined || args.unit_cost !== undefined) throw new ToolInputError("percent e unit_cost são só da bonificação.");
        const from = args.from, to = args.to;
        const whole = (v: unknown) => typeof v === "number" && Number.isInteger(v) && v >= 1 && v <= 1000;
        if (!whole(from) || !whole(to)) throw new ToolInputError("from e to: inteiros de 1 a 1000, como 1 para 2.");
        if (event === "split" ? (to as number) <= (from as number) : (to as number) >= (from as number)) {
          throw new ToolInputError(event === "split" ? "No desdobramento to é maior que from (1 para 2)." : "No grupamento to é menor que from (10 para 1).");
        }
        body.from = from;
        body.to = to;
      }
      const label = event === "split" ? "Desdobramento" : event === "reverse_split" ? "Grupamento" : "Bonificação";
      return pending((await enqueue("investment.event", body)).id, label);
    }
    case "delete_investment_operation":
    case "link_investment_operation": {
      const linking = name === "link_investment_operation";
      only(args, linking ? ["operation_id", "account_id"] : ["operation_id"]);
      const op = find(l.investmentOperations, args.operation_id);
      if (!op) throw new ToolInputError("Operação não encontrada. Use get_investments.");
      if (!linking) return pending((await enqueue("investment.unrecord", { operation_id: text(op.id) })).id, "Exclusão da operação");
      if (op.cash_account_id) throw new ToolInputError("Esta operação já movimenta uma conta.");
      const a = account(l, args.account_id, true);
      return pending((await enqueue("investment.link", { operation_id: text(op.id), account_id: text(a.id) })).id, "Vínculo da operação");
    }
    case "add_loan":
    case "update_loan": {
      const adding = name === "add_loan";
      only(args, ["id", "name", "principal", "start_date", "end_date", "interest_rate", "account_id", "transfer_account_id",
        "reminder_day", "notes", ...(adding ? [] : ["settled"])].filter((k) => adding ? k !== "id" : true));
      const loan = adding ? undefined : find(l.loans, args.id);
      if (!adding && !loan) throw new ToolInputError("Empréstimo não encontrado. Use get_loans.");
      const body: Args = adding ? {} : { id: text(loan!.id) };
      const nm = str(args, "name", 60, adding);
      if (nm) body.name = nm;
      if (args.principal !== undefined) body.principal_cents = reais(args.principal, "principal");
      for (const k of ["start_date", "end_date"]) if (args[k] !== undefined) body[k] = dateArg(args[k], k);
      const start = (body.start_date as string | undefined) ?? (loan ? day(text(loan.start_date)) : undefined);
      const end = (body.end_date as string | undefined) ?? (loan ? day(text(loan.end_date)) : undefined);
      if (!start || !end || end <= start) throw new ToolInputError("end_date deve ser depois de start_date.");
      if (args.interest_rate !== undefined) {
        if (args.interest_rate !== null && (typeof args.interest_rate !== "number" || args.interest_rate < 0 || args.interest_rate > 1000)) {
          throw new ToolInputError("interest_rate é % ao ano, de 0 a 1000.");
        }
        body.interest_rate = args.interest_rate;
      }
      for (const k of ["account_id", "transfer_account_id"]) {
        if (args[k] === undefined) continue;
        body[k] = args[k] === null ? null : text(account(l, args[k], true).id);
      }
      if (args.reminder_day !== undefined) {
        if (typeof args.reminder_day !== "number" || !Number.isInteger(args.reminder_day) || args.reminder_day < 1 || args.reminder_day > 31) {
          throw new ToolInputError("reminder_day de 1 a 31.");
        }
        body.reminder_day = args.reminder_day;
      }
      if (args.notes !== undefined) body.notes = str(args, "notes", 200, false) ?? "";
      const settled = bool(args.settled, "settled");
      if (settled !== undefined) body.settled = settled;
      if (adding && body.principal_cents === undefined) throw new ToolInputError("principal é obrigatório.");
      if (!adding && Object.keys(body).length === 1) throw new ToolInputError("Informe o que deve mudar.");
      return pending((await enqueue(adding ? "loan.add" : "loan.edit", body)).id, adding ? "Novo empréstimo" : "Alteração do empréstimo");
    }
    case "delete_loan": {
      only(args, ["id"]);
      const loan = find(l.loans, args.id);
      if (!loan) throw new ToolInputError("Empréstimo não encontrado. Use get_loans.");
      return pending((await enqueue("loan.delete", { id: text(loan.id) })).id, "Exclusão do empréstimo");
    }
    case "delete_loan_payment": {
      only(args, ["payment_id"]);
      const p = find(l.loanPayments, args.payment_id);
      if (!p) throw new ToolInputError("Pagamento não encontrado. Use get_loans.");
      return pending((await enqueue("loan.unpay", { payment_id: text(p.id) })).id, "Exclusão do pagamento");
    }
    case "update_lended": {
      only(args, ["id", "amount", "due_date", "notes"]);
      const x = find(l.lended, args.id);
      if (!x) throw new ToolInputError("Registro não encontrado. Use get_lended.");
      const body: Args = { id: text(x.id) };
      if (args.amount !== undefined) body.amount_cents = reais(args.amount, "amount");
      if (args.due_date !== undefined) body.due_date = args.due_date === null ? null : dateArg(args.due_date, "due_date");
      if (args.notes !== undefined) body.notes = typeof args.notes === "string" ? args.notes.slice(0, 200) : "";
      if (Object.keys(body).length === 1) throw new ToolInputError("Informe o que deve mudar.");
      return pending((await enqueue("lended.edit", body)).id, "Alteração do registro");
    }
    case "delete_lended": {
      only(args, ["id"]);
      const x = find(l.lended, args.id);
      if (!x) throw new ToolInputError("Registro não encontrado. Use get_lended.");
      return pending((await enqueue("lended.delete", { id: text(x.id) })).id, "Exclusão do registro");
    }
    case "update_person":
    case "delete_person": {
      const deleting = name === "delete_person";
      only(args, deleting ? ["id"] : ["id", "name", "notes"]);
      const p = find(l.lendedPeople, args.id);
      if (!p) throw new ToolInputError("Pessoa não encontrada. Use get_lended.");
      if (deleting) {
        if ((l.lended ?? []).some((x) => x.person_id === p.id && x.is_settled !== 1)) {
          throw new ToolInputError("Há valores em aberto com essa pessoa. Quite ou exclua antes.");
        }
        return pending((await enqueue("person.delete", { id: text(p.id) })).id, "Exclusão da pessoa");
      }
      const body: Args = { id: text(p.id) };
      const nm = str(args, "name", 60, false);
      if (nm) body.name = nm;
      if (args.notes !== undefined) body.notes = typeof args.notes === "string" ? args.notes.slice(0, 200) : "";
      if (Object.keys(body).length === 1) throw new ToolInputError("Informe o que deve mudar.");
      return pending((await enqueue("person.edit", body)).id, "Alteração da pessoa");
    }
    case "get_import_rules": {
      only(args, []);
      return {
        rules: (l.importRules ?? []).map((r) => ({
          id: text(r.id), pattern: text(r.pattern), type: text(r.type),
          category_id: text(r.category_id) || undefined,
          category: text(r.category_id) ? text(find(l.categories, r.category_id)?.name) || "Categoria removida" : undefined,
          subcategory: text(r.subcategory) || undefined,
          auto: r.auto === 1 || r.auto === true || undefined,
          target_account_id: text(r.target_account_id) || undefined,
          target_account: text(r.target_account_id) ? text(find(l.accounts, r.target_account_id)?.name) || "conta removida" : undefined,
        })),
        note: "O texto mais longo vence quando duas regras servem. type transfer: dinheiro entre contas suas; internal: sai da fila sem lançar; auto: o app registra sozinho. Regras não mudam lançamentos antigos.",
      };
    }
    case "save_import_rule": {
      only(args, ["id", "pattern", "category_id", "subcategory", "kind", "auto", "target_account_id"]);
      if (args.id !== undefined && !find(l.importRules, args.id)) throw new ToolInputError("Regra não encontrada. Use get_import_rules.");
      const kind = args.kind;
      if (kind !== undefined && !["expense", "income", "transfer", "internal"].includes(kind as string)) {
        throw new ToolInputError("kind deve ser expense, income, transfer ou internal.");
      }
      const auto = bool(args.auto, "auto") === true;
      const pattern = str(args, "pattern", 60)!;
      if (auto && pattern.trim().length < 3) {
        throw new ToolInputError("Para lançar sozinho, use pelo menos 3 letras do texto do banco.");
      }
      const body: Args = { pattern, subcategory: "" };
      if (kind === "transfer" || kind === "internal") {
        if (args.category_id !== undefined || args.subcategory !== undefined) {
          throw new ToolInputError("Regra de transferência ou de movimento interno não tem categoria.");
        }
        body.type = kind;
        body.category_id = "";
        if (kind === "transfer") {
          // Never a card: paying an invoice is pay_card_invoice.
          body.target_account_id = text(account(l, args.target_account_id, true).id);
        } else if (args.target_account_id !== undefined) {
          throw new ToolInputError("target_account_id só vale para kind transfer.");
        }
      } else {
        if (args.target_account_id !== undefined) throw new ToolInputError("target_account_id só vale para kind transfer.");
        const c = category(l, args.category_id);
        if (kind !== undefined && text(c.type) !== kind) {
          throw new ToolInputError("A categoria é de outro tipo (receita ou despesa).");
        }
        body.type = text(c.type) || "expense";
        body.category_id = text(c.id);
        body.subcategory = str(args, "subcategory", 60, false) ?? "";
      }
      // Sent only when asked: an older app keeps saving plain rules.
      if (auto) body.auto = true;
      if (args.id !== undefined) body.id = args.id;
      const sent = pending((await enqueue("rule.save", body)).id, auto ? "Regra que lança sozinha" : "Regra do banco");
      return auto
        ? { ...sent, warning: "Esta regra registra sozinha o que casar com o texto, sem perguntar. Cada registro aparece em Para revisar › Resolvidas automaticamente e pode ser desfeito." }
        : sent;
    }
    case "delete_import_rule": {
      only(args, ["id"]);
      const r = find(l.importRules, args.id);
      if (!r) throw new ToolInputError("Regra não encontrada. Use get_import_rules.");
      return pending((await enqueue("rule.delete", { id: text(r.id) })).id, "Exclusão da regra");
    }
    case "confirm_suggestion_as_transfer": {
      only(args, ["id", "from_account_id", "to_account_id"]);
      const id = str(args, "id", 80)!;
      if (!/^pluggy:[0-9A-Za-z-]{1,64}$/.test(id)) throw new ToolInputError("id de sugestão inválido.");
      const from = account(l, args.from_account_id), to = account(l, args.to_account_id);
      if (from.id === to.id) throw new ToolInputError("Escolha contas diferentes.");
      const q = await enqueue("suggestion.transfer", { id, from_account_id: text(from.id), to_account_id: text(to.id) });
      // The app records it as asked, but a transfer never settles an invoice.
      return to.type === "credit"
        ? {
          ...pending(q.id, "Sugestão como transferência"),
          warning: "O destino é um cartão de crédito: a transferência muda o saldo do cartão, mas não dá baixa na fatura, que continua em aberto. " +
            "Se a sugestão é o pagamento da fatura, desfaça este pedido com undo_request e use pay_card_invoice; o app liga a sugestão ao pagamento sozinho.",
        }
        : pending(q.id, "Sugestão como transferência");
    }
    case "link_suggestion": {
      only(args, ["id", "transaction_id", "add_amount"]);
      const id = str(args, "id", 80)!;
      if (!/^pluggy:[0-9A-Za-z-]{1,64}$/.test(id)) throw new ToolInputError("id de sugestão inválido.");
      if (args.add_amount !== undefined && typeof args.add_amount !== "boolean") {
        throw new ToolInputError("add_amount deve ser verdadeiro ou falso.");
      }
      const t = find(l.transactions, args.transaction_id);
      if (!t) throw new ToolInputError("Lançamento não encontrado. Use list_transactions.");
      const source = meta(metadataIndex(l).get(text(t.id))).source;
      const transferLeg = source.startsWith("transfer:");
      if (args.add_amount === true) {
        if (t.type !== "expense") throw new ToolInputError("O IOF só se soma a uma compra (despesa).");
        // The app refuses these as well (addIofToTransaction): said here,
        // before the request waits in the queue to be refused.
        if (transferLeg || text(t.id).startsWith("investment:") || source.startsWith("investment:") ||
          source.startsWith("shared_bill:") || source === "opening_balance") {
          throw new ToolInputError("add_amount só soma o IOF a uma compra comum: transferência, investimento, conta dividida e ajuste de saldo não recebem IOF.");
        }
      }
      // The movement itself, while the server still lists it. An entry of
      // the other direction is not the same movement, and the leg of a
      // transfer only answers for the same amount (the rule of the app links
      // legs to exact amounts only). Linking a purchase to one would make
      // the purchase vanish from the queue without ever being spending.
      let listed: Record<string, unknown>[] = [];
      try {
        listed = deps.suggestions ? await deps.suggestions(200) : [];
      } catch {
        // Not known here: the app checks the suggestion when it applies.
      }
      const s = listed.find((x) => String(x.id) === id);
      if (s) {
        const m = toMovement(s);
        const out = direction(m) === "out";
        if (t.type && t.type !== (out ? "expense" : "income")) {
          throw new ToolInputError(`A sugestão é uma ${out ? "saída" : "entrada"} e o lançamento é uma ${t.type === "income" ? "receita" : "despesa"}: não são a mesma movimentação.`);
        }
        if (transferLeg && args.add_amount !== true && cents(num(t.amount)) !== m.amountCents) {
          throw new ToolInputError("Este lançamento é uma perna de transferência de outro valor: não é a mesma movimentação. " +
            "Se a sugestão é um gasto ou uma receita, use confirm_suggestion; se é dinheiro entre contas suas, confirm_suggestion_as_transfer.");
        }
      }
      return pending((await enqueue("suggestion.link", {
        id, transaction_id: text(t.id), add_amount: args.add_amount === true,
      })).id, args.add_amount === true ? "IOF somado à compra" : "Vínculo da sugestão");
    }
    case "reconcile_account": {
      only(args, ["account_id", "from", "to"]);
      const acc = account(l, args.account_id);
      const to = args.to === undefined ? today : dateArg(args.to, "to");
      const from = args.from === undefined ? addDays(to, -30) : dateArg(args.from, "from");
      if (from > to) throw new ToolInputError("from deve ser antes de to.");
      if (to > today) throw new ToolInputError("to não pode ser no futuro.");
      if (addDays(from, 92) < to) throw new ToolInputError("Confira no máximo 92 dias por vez.");
      if (!deps.bankMovements) {
        return { note: "O servidor ainda não informa os movimentos do banco por período. Atualize o servidor do Nexo." };
      }
      // Brasília days; a few days around, so pairs and an IOF find their other side.
      const movements = await deps.bankMovements(
        Date.parse(`${addDays(from, -5)}T00:00:00-03:00`), Date.parse(`${addDays(to, 6)}T00:00:00-03:00`));
      const fromMs = Date.parse(`${from}T00:00:00-03:00`), toMs = Date.parse(`${addDays(to, 1)}T00:00:00-03:00`);
      // The neighbours help the matching; only the period is reported.
      const inPeriod = (s: Record<string, unknown>) => Number(s.occurred_at) >= fromMs && Number(s.occurred_at) < toMs;
      const linked = deps.bankAccounts
        ? (await deps.bankAccounts()).filter((r) => r.nexo_account_id === acc.id && typeof r.balance_cents === "number")
        : [];
      const bank = linked.length
        ? linked.reduce((sum, r) => sum + (r.type === "CREDIT" ? -1 : 1) * (r.balance_cents as number), 0)
        : null;
      return {
        ...reconcileAccount(l, movements, text(acc.id), from, to, bank, balanceCents(l, text(acc.id)),
          deps.now?.() ?? Date.now(), inPeriod),
        banks: linked.map((r) => ({ bank: r.bank, name: r.name, data_until: r.bank_updated_at ?? undefined })),
      };
    }
    case "get_bank_accounts": {
      only(args, []);
      if (!deps.bankAccounts) return { accounts: [], note: "O servidor ainda não informa as contas do banco." };
      const rows = await deps.bankAccounts();
      const byNexo = new Map<string, number>();
      for (const r of rows) {
        if (typeof r.nexo_account_id !== "string" || typeof r.balance_cents !== "number") continue;
        // The bank shows what a card owes as a positive balance.
        const owed = r.type === "CREDIT" ? -r.balance_cents : r.balance_cents;
        byNexo.set(r.nexo_account_id, (byNexo.get(r.nexo_account_id) ?? 0) + owed);
      }
      return {
        accounts: rows.map((r) => ({
          account_id: r.account_id, bank: r.bank, name: r.name, type: r.type === "CREDIT" ? "cartão" : "conta",
          bank_balance: typeof r.balance_cents === "number" ? money(r.balance_cents) : null,
          credit_limit: typeof r.credit_limit_cents === "number" ? money(r.credit_limit_cents) : undefined,
          available: typeof r.available_cents === "number" ? money(r.available_cents) : undefined,
          ...nextDue(l, r, today),
          official_invoices: Array.isArray(r.bills) && r.bills.length
            ? (r.bills as Record<string, unknown>[]).slice(0, 4).map((b) => ({
              due_date: b.due_date, total: money(num(b.total_cents)), paid: money(num(b.paid_cents)),
              minimum: typeof b.minimum_cents === "number" ? money(b.minimum_cents) : undefined,
            }))
            : undefined,
          nexo_account_id: r.nexo_account_id ?? null,
          nexo_account: r.nexo_account_id ? text(find(l.accounts, r.nexo_account_id)?.name) || "conta removida" : undefined,
          data_until: r.bank_updated_at ?? undefined,
        })),
        check: [...byNexo.entries()].map(([id, bank]) => {
          const nexo = balanceCents(l, id);
          return {
            nexo_account_id: id, nexo_account: text(find(l.accounts, id)?.name) || "conta removida",
            bank: money(bank), nexo: money(nexo), difference: money(bank - nexo),
            hint: bank === nexo ? "Igual ao banco." : "Diferente: confira lançamentos que faltam ou sobram; para acertar use adjust_account_balance.",
          };
        }),
        note: "Saldos do banco são da última leitura do Open Finance (data_until). A fatura oficial é a do banco; a do Nexo segue a regra do fechamento (get_card_invoices).",
      };
    }
    case "link_bank_account": {
      only(args, ["account_id", "nexo_account_id"]);
      const id = str(args, "account_id", 64)!;
      if (args.nexo_account_id !== null) account(l, args.nexo_account_id);
      if (!deps.linkBankAccount) throw new ToolInputError("O servidor ainda não permite vincular contas do banco.");
      const n = await deps.linkBankAccount(id, args.nexo_account_id as string | null);
      if (!n) throw new ToolInputError("Conta do banco não encontrada. Use get_bank_accounts.");
      return { linked: args.nexo_account_id !== null, message: args.nexo_account_id === null ? "Vínculo desfeito." : "Conta vinculada. Nenhum saldo mudou." };
    }
    case "refresh_bank_data": {
      only(args, []);
      return pending((await enqueue("bank.refresh", {})).id, "Pedido de leitura dos bancos");
    }
    case "get_monthly_trend": {
      only(args, ["months"]);
      const months = args.months ?? 6;
      if (typeof months !== "number" || !Number.isInteger(months) || months < 2 || months > 24) throw new ToolInputError("months de 2 a 24.");
      const [y, m] = today.split("-").map(Number);
      const rows = [];
      for (let i = months - 1; i >= 0; i--) {
        const d = new Date(Date.UTC(y, m - 1 - i, 1));
        const from = d.toISOString().slice(0, 10);
        const last = new Date(Date.UTC(d.getUTCFullYear(), d.getUTCMonth() + 1, 0)).toISOString().slice(0, 10);
        const to = i === 0 ? today : last;
        const a = analyze(l, { from, to });
        const top = Object.entries(a.categories).sort((p, q) => q[1] - p[1])[0];
        const income = a.income + a.refunds;
        rows.push({
          month: from.slice(0, 7), partial: i === 0, income: money(a.income), spending: money(a.expense), refunds: money(a.refunds),
          result: money(a.result), savings_rate_percent: income > 0 ? Math.round((a.result / income) * 1000) / 10 : null,
          extraordinary: money(a.extraordinary),
          top_category: top ? { category: text(find(l.categories, top[0])?.name) || "Sem categoria", amount: money(top[1]) } : undefined,
        });
      }
      const full = rows.filter((r) => !r.partial);
      return {
        months: rows,
        average_spending: full.length ? money(Math.round(full.reduce((s, r) => s + cents(r.spending), 0) / full.length)) : null,
        note: "Consumo pela regra do app (sem transferências, reservas, faturas e ajustes). O mês atual vai até hoje.",
      };
    }
    case "get_net_worth": {
      only(args, []);
      let cash = 0, cards = 0;
      const others: Record<string, number> = {};
      // A dollar account at the rate the app saved with the dollar stocks,
      // so the two never disagree; without one it stays apart.
      const rates: Record<string, number> = {};
      for (const a of l.accounts) {
        let b = balanceCents(l, text(a.id));
        const c = text(a.currency) || "?";
        if (c !== l.mainCurrency && a.type !== "gold" && l.mainCurrency === "BRL") {
          const r = rates[c] ?? lastRate(l.investments, c);
          if (r) {
            rates[c] = r;
            b = ratio(b, r, FX_SCALE);
          }
        }
        if ((c !== l.mainCurrency && !rates[c]) || a.type === "gold") {
          others[c] = (others[c] ?? 0) + balanceCents(l, text(a.id));
          continue;
        }
        if (a.type === "credit") cards += b;
        else cash += b;
      }
      const invest = callTool("get_investment_summary", {}, l, today) as { reference_total: number };
      const assets = (l.assets ?? []).filter((x) => !x.currency || x.currency === l.mainCurrency).reduce((s, x) => s + cents(num(x.value)), 0);
      let loans = 0;
      for (const x of (l.loans ?? []).filter((x) => x.is_settled !== 1)) {
        const paid = (l.loanPayments ?? []).filter((p) => p.loan_id === x.id).reduce((s, p) => s + cents(num(p.amount)), 0);
        loans += Math.max(cents(num(x.principal)) - paid, 0);
      }
      let lent = 0, borrowed = 0;
      for (const x of (l.lended ?? []).filter((x) => x.is_settled !== 1)) {
        if (x.type === "borrowed") borrowed += cents(num(x.amount));
        else lent += cents(num(x.amount));
      }
      // A goal takes the money out of the account: it is still the person's.
      // Without an account the reserve was only bookkeeping.
      let goals = 0;
      for (const c of (l.contributions ?? []).filter((c) => text(c.account_id))) {
        goals += (c.type === "withdrawal" ? -1 : 1) * cents(num(c.amount));
      }
      const investments = cents(invest.reference_total);
      const total = cash + cards + investments + assets + goals - loans + lent - borrowed;
      return {
        currency: l.mainCurrency,
        accounts: money(cash), card_debt: money(cards), investments: money(investments), goals: money(goals), assets: money(assets),
        loans_outstanding: money(-loans), lent_to_others: money(lent), borrowed_from_others: money(-borrowed),
        net_worth: money(total),
        not_converted: Object.keys(others).length ? Object.fromEntries(Object.entries(others).map(([c, v]) => [c, money(v)])) : undefined,
        rates_used: Object.keys(rates).length ? Object.fromEntries(Object.entries(rates).map(([c, r]) => [c, r / FX_SCALE])) : undefined,
        note: "Empréstimos pelo valor principal menos o que já foi pago (sem juros futuros). Investimentos pela última cotação. Contas marcadas como fora do saldo total entram no patrimônio, como na tela Patrimônio do app. Bens que repetem uma conta ou investimento contam duas vezes: confira.",
      };
    }
    case "get_cash_projection": {
      only(args, ["until", "daily_spending"]);
      const until = dateArg(args.until, "until");
      if (until <= today) throw new ToolInputError("until deve ser depois de hoje.");
      if (until > addDays(today, 400)) throw new ToolInputError("Projete no máximo 400 dias.");
      const asked = args.daily_spending;
      if (asked !== undefined && asked !== "average" &&
        (typeof asked !== "number" || !Number.isFinite(asked) || asked < 0 || asked > 1_000_000)) {
        throw new ToolInputError('daily_spending deve ser "average" ou um valor por dia em reais.');
      }
      const daily = asked === undefined ? null
        : asked === "average" ? dailyAverage(l, today) : { cash: cents(asked), cards: new Map<string, number>() };
      const { start, items, leftOut } = projection(l, today, until, daily);
      const { timeline, end: running, lowest, lowestDate, safePerDay, estimatedTotal } = walk(start, items, today, until, daily?.cash ?? 0);
      return {
        from: today, until, starting_cash: money(start), ending_cash: money(running),
        lowest_point: { balance: money(lowest), date: lowestDate },
        safe_per_day: money(safePerDay),
        daily_spending: daily ? {
          basis: asked === "average" ? "média diária das últimas 4 semanas, sem recorrentes, parcelas, gastos pontuais e neutros" : "valor informado",
          account_per_day: money(daily.cash),
          cards_per_day: daily.cards.size ? [...daily.cards].map(([id, v]) => ({ card_id: id, per_day: money(v) })) : undefined,
          estimated_total: money(estimatedTotal),
        } : undefined,
        timeline: timeline.slice(0, 120), truncated: timeline.length > 120 ? timeline.length : undefined,
        left_out: leftOut.length ? leftOut : undefined,
        note: `Estimativa: contas em reais que entram no total, sem cartões e ouro. Cada fatura que vence até a data entra no vencimento, com as parcelas já lançadas e as recorrentes do cartão no ciclo certo. ${daily ? "O gasto do dia a dia é estimado: sai da conta todo dia a partir de amanhã, e o do cartão entra na fatura do ciclo (não aparece item a item na lista)." : "Gastos variáveis do dia a dia não estão incluídos (peça daily_spending)."} safe_per_day é quanto dá para gastar por dia, a partir de amanhã, sem o saldo ficar negativo em nenhum dia até a data.`,
      };
    }
    case "simulate_cash": {
      only(args, ["until", "daily_spending", "events"]);
      const until = dateArg(args.until, "until");
      if (until <= today) throw new ToolInputError("until deve ser depois de hoje.");
      if (until > addDays(today, 400)) throw new ToolInputError("Simule no máximo 400 dias.");
      const asked = args.daily_spending;
      if (asked !== undefined && asked !== "average" &&
        (typeof asked !== "number" || !Number.isFinite(asked) || asked < 0 || asked > 1_000_000)) {
        throw new ToolInputError('daily_spending deve ser "average" ou um valor por dia em reais.');
      }
      const daily = asked === undefined ? null
        : asked === "average" ? dailyAverage(l, today) : { cash: cents(asked), cards: new Map<string, number>() };
      if (!Array.isArray(args.events) || args.events.length === 0 || args.events.length > 20) {
        throw new ToolInputError("events deve ter de 1 a 20 eventos.");
      }
      const kinds = ["income", "expense", "sell_asset", "sell_investment", "partial_invoice"];
      const events: SimEvent[] = args.events.map((raw, i) => {
        if (!raw || typeof raw !== "object" || Array.isArray(raw)) throw new ToolInputError(`events[${i}] deve ser um objeto.`);
        const e = raw as Args;
        only(e, ["kind", "date", "amount", "label", "investment_id", "card_id"]);
        if (!kinds.includes(e.kind as string)) throw new ToolInputError(`events[${i}].kind deve ser ${kinds.join(", ")}.`);
        if (typeof e.amount !== "number" || !Number.isFinite(e.amount) || e.amount <= 0 || e.amount > 1_000_000_000) {
          throw new ToolInputError(`events[${i}].amount deve ser um valor positivo em reais.`);
        }
        if (e.label !== undefined && (typeof e.label !== "string" || e.label.length > 80)) throw new ToolInputError(`events[${i}].label: texto até 80 letras.`);
        const out: SimEvent = { kind: e.kind as SimEvent["kind"], amount: cents(e.amount),
          date: e.date === undefined ? undefined : dateArg(e.date, `events[${i}].date`), label: e.label as string | undefined };
        if (out.kind === "sell_investment") {
          const inv = find(l.investments, e.investment_id);
          if (!inv) throw new ToolInputError(`events[${i}].investment_id: investimento não encontrado (get_investments).`);
          out.assetClass = text(inv.asset_class);
          out.label = out.label || `Venda de ${text(inv.name)}`;
        } else if (e.investment_id !== undefined) throw new ToolInputError(`events[${i}].investment_id só vale em sell_investment.`);
        if (out.kind === "partial_invoice") {
          const card = find(l.accounts, e.card_id);
          if (!card || card.type !== "credit") throw new ToolInputError(`events[${i}].card_id: cartão de crédito não encontrado.`);
          out.cardId = text(card.id);
        } else if (e.card_id !== undefined) throw new ToolInputError(`events[${i}].card_id só vale em partial_invoice.`);
        return out;
      });
      const cards = new Map(l.accounts.filter((a) => a.type === "credit").map((a) => [text(a.id), {
        name: text(a.name), closing: typeof a.statement_day === "number" ? a.statement_day : null,
        due: typeof a.due_day === "number" ? a.due_day : null,
        interest: typeof a.interest_monthly_percent === "number" ? a.interest_monthly_percent : null,
      }]));
      const base = projection(l, today, until, daily);
      const before = walk(base.start, base.items, today, until, daily?.cash ?? 0);
      const sim = simulate(base.items, events, today, until, cards);
      const after = walk(base.start, sim.items, today, until, daily?.cash ?? 0);
      return {
        from: today, until, starting_cash: money(base.start),
        without_events: { ending_cash: money(before.end), lowest_point: { balance: money(before.lowest), date: before.lowestDate } },
        with_events: { ending_cash: money(after.end), lowest_point: { balance: money(after.lowest), date: after.lowestDate },
          missing: money(Math.max(0, -after.lowest)) },
        difference_at_end: money(after.end - before.end),
        events_applied: sim.added.map((i) => ({ date: i.date, what: i.what, amount: money(i.amount),
          estimated: i.estimate ? money(-i.estimate) : undefined })),
        warnings: sim.warnings.length ? sim.warnings : undefined,
        timeline: after.timeline.slice(0, 120), truncated: after.timeline.length > 120 ? after.timeline.length : undefined,
        note: "Simulação: nada foi gravado. missing é quanto faltaria no dia mais baixo. A venda de investimento cai no dia da liquidação (ações, FIIs e ETFs em D+2 úteis; renda fixa no mesmo dia útil). No pagamento parcial, o resto vai para a fatura seguinte com um mês de juros do rotativo pela taxa do cartão: estimativa, sem IOF e encargos; pela Lei 14.690/2023, juros e encargos do rotativo não passam do valor original da dívida.",
      };
    }
    case "get_spending_breakdown": {
      only(args, ["from", "to", "by"]);
      const from = dateArg(args.from, "from"), to = dateArg(args.to, "to");
      if (from > to) throw new ToolInputError("from deve ser anterior a to.");
      const by = args.by;
      const weekdays = ["domingo", "segunda", "terça", "quarta", "quinta", "sexta", "sábado"];
      const metas = metadataIndex(l);
      const groups = new Map<string, { amount: number; count: number }>();
      let total = 0;
      for (const t of l.transactions) {
        const d = day(text(t.date));
        if (t.type !== "expense" || d < from || d > to) continue;
        const m = meta(metas.get(text(t.id)));
        if (m.status === "pending" || isNeutral(t, m) || currencyOf(l, t) !== l.mainCurrency) continue;
        const c = find(l.categories, t.category_id);
        const key = by === "category" ? text(c?.name) || "Sem categoria"
          : by === "account" ? text(find(l.accounts, t.account_id)?.name) || "Conta removida"
          : by === "subcategory" ? m.subcategory || "Sem subcategoria"
          : by === "weekday" ? weekdays[new Date(`${d}T12:00:00Z`).getUTCDay()]
          : by === "spending_type" ? envelopeById(c?.envelope)?.name ?? "Sem tipo"
          : by === "merchant" ? text(t.description).trim().toLowerCase().replace(/\s+/g, " ") || "(sem descrição)"
          : (() => { throw new ToolInputError("by inválido."); })();
        const g = groups.get(key) ?? { amount: 0, count: 0 };
        g.amount += cents(num(t.amount));
        g.count++;
        groups.set(key, g);
        total += cents(num(t.amount));
      }
      return {
        from, to, by, total: money(total),
        groups: [...groups.entries()].sort((a, b) => b[1].amount - a[1].amount).slice(0, 60)
          .map(([k, g]) => ({ group: k, amount: money(g.amount), count: g.count, percent: total ? Math.round(g.amount / total * 1000) / 10 : 0 })),
        note: "Consumo realizado (sem pendentes, transferências, reservas, faturas e ajustes), em reais.",
      };
    }
    default:
      return null;
  }
}

/// Extended edits for tools that existed before: they keep their old
/// request kind when only old fields are used (older apps understand it) and
/// use the newer kind otherwise.
export function extendedTransactionEdit(l: Ledger, args: Args): Args | null {
  const extended = ["type", "subcategory", "status", "due_date", "kind", "recurring_income_id"];
  if (!extended.some((k) => args[k] !== undefined)) return null;
  const tx = find(l.transactions, args.id);
  if (!tx) throw new ToolInputError("Lançamento não encontrado. Use list_transactions para ver os ids.");
  const body: Args = { id: text(tx.id) };
  // Empty only for an entry still being created: the app checks it, in order.
  const type = args.type ?? tx.type;
  if (type !== "" && type !== "expense" && type !== "income") throw new ToolInputError("type deve ser expense ou income.");
  if (args.type !== undefined) body.type = type;
  if (args.amount !== undefined) body.amount_cents = reais(args.amount, "amount");
  if (args.description !== undefined) body.description = str(args, "description", 80);
  if (args.account_id !== undefined) body.account_id = text(account(l, args.account_id).id);
  if (args.category_id !== undefined || args.type !== undefined) {
    const c = category(l, args.category_id ?? tx.category_id);
    if (type !== "" && (text(c.type) || "expense") !== type) {
      throw new ToolInputError(`A categoria ${text(c.name)} é de ${text(c.type) === "income" ? "receita" : "despesa"}; mande category_id do tipo certo.`);
    }
    body.category_id = text(c.id);
  }
  if (args.date !== undefined) body.date = dateArg(args.date, "date");
  if (args.note !== undefined) body.note = typeof args.note === "string" ? args.note.slice(0, 200) : "";
  if (args.subcategory !== undefined) {
    if (typeof args.subcategory !== "string" || args.subcategory.length > 60) throw new ToolInputError("subcategory até 60 letras.");
    body.subcategory = args.subcategory;
  }
  if (args.status !== undefined) {
    if (args.status !== "paid" && args.status !== "pending") throw new ToolInputError("status deve ser paid ou pending.");
    body.status = args.status;
  }
  if (args.due_date !== undefined) body.due_date = args.due_date === null ? null : dateArg(args.due_date, "due_date");
  if (args.kind !== undefined) {
    if (args.kind !== "normal" && args.kind !== "extraordinary") throw new ToolInputError("kind deve ser normal ou extraordinary.");
    body.expense_class = args.kind;
  }
  if (args.recurring_income_id !== undefined) {
    const r = find(l.recurring, args.recurring_income_id);
    if (!r || r.payment_type !== "income") throw new ToolInputError("recurring_income_id deve ser uma receita recorrente (get_recurring).");
    if (tx.type !== "" && tx.type !== "income") throw new ToolInputError("Só uma receita pode contar como a renda do mês.");
    body.recurring_income_id = text(r.id);
  }
  return body;
}
