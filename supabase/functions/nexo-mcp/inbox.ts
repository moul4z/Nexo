// "Para revisar" as the assistant sees it: the app's own rule (reconcile.ts,
// the mirror of lib/services/reconciliation.dart) over the bank movements
// still pending and the synced ledger. Read-only: what the app settles by
// itself is only described here, the app does it.
import { cents, day, type Ledger, meta, metadataIndex, money, num, type Row, text } from "./finance.ts";
import { type Entry, type Match, type Movement, paymentLegs, reconcile, resolutionLabel, type Rule } from "./reconcile.ts";
import { sharedSettings } from "./settings.ts";

type Raw = Record<string, unknown>;
const str = (v: unknown) => (typeof v === "string" && v !== "" ? v : null);

/// The day of a bank movement as the person reads it: Brasília (UTC−3, no
/// daylight saving), the same day reconcile.ts compares (movementDay). One
/// place, so the list, the previews and the duplicate checks never disagree.
export const movementDate = (ms: number): string =>
  Number.isFinite(ms) && Math.abs(ms) < 8.64e15 ? new Date(ms - 3 * 3600000).toISOString().slice(0, 10) : "";

export function toMovement(s: Raw): Movement {
  return {
    id: String(s.id),
    amountCents: Number(s.amount_cents),
    kind: String(s.kind),
    medium: String(s.medium ?? "bank"),
    description: String(s.description ?? ""),
    occurredAt: Number(s.occurred_at),
    direction: s.direction === "in" || s.direction === "out" ? s.direction : null,
    accountId: str(s.account_id),
    nexoAccountId: str(s.nexo_account_id),
    operationRef: str(s.operation_ref),
    paymentRef: str(s.payment_ref),
    sameOwner: typeof s.same_owner === "boolean" ? s.same_owner : null,
    counterparty: str(s.counterparty),
  };
}

export function ledgerEntries(l: Ledger): Entry[] {
  const metas = metadataIndex(l);
  return l.transactions.map((t) => ({
    id: text(t.id),
    type: text(t.type),
    cents: cents(num(t.amount)),
    description: text(t.description),
    accountId: text(t.account_id),
    day: day(text(t.date)),
    source: meta(metas.get(text(t.id))).source,
    categoryId: text(t.category_id),
  }));
}

const rules = (l: Ledger): Rule[] =>
  (l.importRules ?? []).map((r: Row) => ({
    id: text(r.id),
    pattern: text(r.pattern),
    type: text(r.type) || "expense",
    categoryId: text(r.category_id),
    auto: r.auto === 1 || r.auto === true,
    targetAccountId: str(r.target_account_id),
  }));

/// [pending]: the movements waiting for review. [decided]: the ones already
/// decided around the same days, so an entry linked to one of them does not
/// answer for another, and an IOF finds its purchase.
export function classify(l: Ledger, pending: Raw[], decided: Raw[], now: number): Match[] {
  const credit = new Set(l.accounts.filter((a) => a.type === "credit").map((a) => text(a.id)));
  const known = new Set(l.accounts.map((a) => text(a.id)));
  // A link to an account that no longer exists is no link.
  const movement = (s: Raw): Movement => {
    const m = toMovement(s);
    return m.nexoAccountId && !known.has(m.nexoAccountId) ? { ...m, nexoAccountId: null } : m;
  };
  const entries = ledgerEntries(l);
  const exists = new Set(entries.map((e) => e.id));
  const confirmed = decided.filter((d) => d.review === "confirmed" && typeof d.transaction_id === "string" &&
    exists.has(d.transaction_id));
  const name = String(sharedSettings(l).userName ?? "").trim();
  return reconcile(pending.map(movement), entries, {
    linkedIds: new Set(confirmed.map((d) => String(d.transaction_id))),
    ownerNames: name.includes(" ") ? [name] : [],
    creditAccounts: credit,
    payments: paymentLegs(entries, credit),
    settled: confirmed.filter((d) => Number(d.amount_cents) > 0)
      .map((d) => ({ movement: movement(d), transactionId: String(d.transaction_id) })),
    rules: rules(l),
    now,
  });
}

/// What the assistant should do about one movement, in a sentence.
function advice(m: Match, canWrite: boolean): string {
  switch (m.resolution) {
    case "linked":
      return "Já está lançado: o app liga sozinho. Não confirme (criaria outro lançamento).";
    case "maybe":
      return "Parece o mesmo lançamento. Se for, use link_suggestion; se forem gastos diferentes, confirm_suggestion com allow_duplicate.";
    case "internal":
      return "Dinheiro entre contas suas que somam na mesma conta do Nexo: o app tira da fila sem lançar.";
    case "ownTransfer":
      return m.waiting
        ? "Transferência sua; o outro lado ainda pode chegar do outro banco. Espere um dia."
        : canWrite && m.automatic
        ? "Transferência entre contas suas: o app registra sozinho no celular."
        : "Transferência entre contas suas: confirm_suggestion_as_transfer.";
    case "ownName":
      return m.waiting
        ? "Para o seu próprio nome; o outro lado ainda pode chegar. Espere um dia."
        : "Para o seu próprio nome em um lugar que o Nexo não vê: confirm_suggestion_as_transfer, ou ignore se não quer registrar.";
    case "invoicePayment":
      return "Pagamento de fatura: pay_card_invoice (não é gasto). O outro lado do par sai junto.";
    case "reversal":
      return "Pagamento e estorno que se anulam: o app tira os dois da fila.";
    case "reserve":
      return "Movimento de reserva do banco: não é gasto; o app tira da fila.";
    case "yield":
      return m.automatic
        ? "Rendimento: o app lança sozinho como receita (ou ignora, conforme a escolha no app)."
        : "Rendimento acima do que o app lança sozinho: confirm_suggestion como receita.";
    case "iof":
      return m.automatic
        ? "IOF da compra internacional: o app soma à compra."
        : "IOF de compra internacional: link_suggestion com add_amount na compra, ou confirm_suggestion separado.";
    case "rule":
      return m.automatic
        ? "Uma regra com 'lançar sozinho' cobre este movimento: o app registra no celular."
        : "Uma regra sugere a categoria: confirm_suggestion.";
    default:
      return "Novo: confirm_suggestion se for real, ignore_suggestions se não for.";
  }
}

/// The list the assistant reads: what still needs a decision, and what the
/// app settles by itself (so nobody confirms it twice).
export function describe(l: Ledger, pending: Raw[], matches: Match[], limit: number) {
  const byId = new Map(l.transactions.map((t) => [text(t.id), t]));
  const names = new Map(l.accounts.map((a) => [text(a.id), text(a.name)]));
  const categories = new Map(l.categories.map((c) => [text(c.id), text(c.name)]));
  const match = new Map(matches.map((m) => [m.id, m]));
  const entry = (id?: string) => {
    const t = id ? byId.get(id) : undefined;
    return t
      ? { id: text(t.id), description: text(t.description), date: day(text(t.date)), account: names.get(text(t.account_id)) }
      : undefined;
  };
  const row = (s: Raw) => {
    const m = match.get(String(s.id))!;
    return {
      id: s.id, bank: s.bank, date: movementDate(Number(s.occurred_at)),
      amount: money(Number(s.amount_cents)), kind: s.kind, medium: s.medium === "credit" ? "cartão" : "conta",
      direction: s.direction === "in" ? "entrada" : s.direction === "out" ? "saída" : undefined,
      description: s.description, counterparty: str(s.counterparty) ?? undefined,
      settled: s.settled, installment: s.installment ?? undefined,
      nexo_account: str(s.nexo_account_id) ? names.get(String(s.nexo_account_id)) : undefined,
      status: resolutionLabel[m.resolution], resolution: m.resolution,
      already_recorded: m.resolution === "linked"
        ? { ...entry(m.transactionId), account_mismatch: m.wrongAccount === true || undefined }
        : undefined,
      maybe_recorded: m.resolution === "maybe" ? { ...entry(m.transactionId), account_mismatch: m.wrongAccount === true || undefined } : undefined,
      purchase: m.resolution === "iof" ? entry(m.transactionId) : undefined,
      pair_id: m.pairId, waiting_other_side: m.waiting === true || undefined,
      from_account: m.fromAccountId ? names.get(m.fromAccountId) : undefined,
      to_account: m.toAccountId ? names.get(m.toAccountId) : undefined,
      suggested_category: m.categoryId ? { id: m.categoryId, name: categories.get(m.categoryId) } : undefined,
      what_to_do: advice(m, true),
    };
  };
  const open = pending.filter((s) => !match.get(String(s.id))!.automatic);
  const auto = pending.filter((s) => match.get(String(s.id))!.automatic);
  const reasons: Record<string, number> = {};
  for (const s of auto) {
    const label = resolutionLabel[match.get(String(s.id))!.resolution];
    reasons[label] = (reasons[label] ?? 0) + 1;
  }
  return {
    suggestions: open.slice(0, limit).map(row),
    more: open.length > limit ? open.length - limit : undefined,
    settled_by_app: auto.length
      ? { count: auto.length, by_reason: reasons, items: auto.slice(0, Math.min(limit, 20)).map(row) }
      : undefined,
  };
}
