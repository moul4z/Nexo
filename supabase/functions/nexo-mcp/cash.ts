// Cash projection and "what if" simulation, with the app's rules
// (lib/services/cash_forecast.dart, daily_spending.dart and
// cash_simulation.dart). Both sides run the cases in
// test/fixtures/forecast_cases.json. Nothing here records anything.
import { cents, currencyOf, day, isNeutral, type Ledger, meta, metadataIndex, money, num, recurringCents, type Row, text } from "./finance.ts";
import { cardInvoices, cycleFor, occurrences } from "./invoices.ts";
import { availableOn } from "./settlement.ts";

const pad = (n: number) => String(n).padStart(2, "0");
export const addDays = (s: string, n: number) => {
  const d = new Date(`${s}T00:00:00Z`);
  d.setUTCDate(d.getUTCDate() + n);
  return `${d.getUTCFullYear()}-${pad(d.getUTCMonth() + 1)}-${pad(d.getUTCDate())}`;
};
const find = (rows: Row[] | undefined, id: unknown) => (rows ?? []).find((r) => text(r.id) === id);
const balanceCents = (l: Ledger, id: string) => Math.round((l.balances[id] ?? 0) / 10000);

export interface CashItem {
  date: string;
  what: string;
  /// Signed, in cents.
  amount: number;
  /// The part of amount that is an estimate (signed, cents).
  estimate?: number;
  kind: "recurring" | "pending" | "invoice" | "simulated";
  cardId?: string;
  closing?: string;
}

export interface Daily { cash: number; cards: Map<string, number> }

/// Day-to-day spending per day, in cents: the last 28 days before today,
/// apart for the accounts and each card. Real spending only (no neutral,
/// recurring, installments, one-off or pending). Same rule as the app's
/// DailySpending.average.
export function dailyAverage(l: Ledger, today: string): Daily {
  const from = addDays(today, -28);
  const metas = metadataIndex(l);
  let cash = 0;
  const cards = new Map<string, number>();
  for (const t of l.transactions) {
    if (t.type !== "expense") continue;
    const d = day(text(t.date));
    if (d < from || d >= today) continue;
    const a = find(l.accounts, t.account_id);
    if (!a || a.exclude_from_total === 1 || a.type === "gold" || currencyOf(l, t) !== l.mainCurrency) continue;
    const m = meta(metas.get(text(t.id)));
    if (m.status === "pending" || m.expenseClass === "extraordinary" || m.source === "recurring" ||
      m.source === "installment" || m.installmentTotal != null) continue;
    if (text(t.id).startsWith("recurring:") || isNeutral(t, m)) continue;
    if (a.type === "credit") cards.set(text(a.id), (cards.get(text(a.id)) ?? 0) + cents(num(t.amount)));
    else cash += cents(num(t.amount));
  }
  return {
    cash: Math.round(cash / 28),
    cards: new Map([...cards].map(([id, v]) => [id, Math.round(v / 28)] as [string, number]).filter(([, v]) => v > 0)),
  };
}

/// What enters and leaves the cash up to [until]: recurring items, pending
/// bills and every card invoice (with the card's day-to-day estimate when
/// [daily] is given). Late items count today.
export function projection(l: Ledger, today: string, until: string, daily: Daily | null) {
  const credit = new Set(l.accounts.filter((a) => a.type === "credit").map((a) => text(a.id)));
  const main = l.accounts.filter((a) => a.type !== "credit" && a.type !== "gold" && a.exclude_from_total !== 1 &&
    text(a.currency) === l.mainCurrency);
  const start = main.reduce((s, a) => s + balanceCents(l, text(a.id)), 0);
  const items: CashItem[] = [];
  for (const r of l.recurring) {
    if (credit.has(text(r.account_id))) continue; // card bills arrive through the invoice
    if (!main.some((a) => a.id === r.account_id)) continue;
    for (const d of occurrences(r, until)) {
      items.push({ date: d < today ? today : d, what: `${text(r.name)} (recorrente${d < today ? `, atrasada desde ${d}` : ""})`,
        amount: (r.payment_type === "income" ? 1 : -1) * recurringCents(r), kind: "recurring" });
    }
  }
  const metas = metadataIndex(l);
  for (const t of l.transactions) {
    const m = meta(metas.get(text(t.id)));
    if (m.status !== "pending" || credit.has(text(t.account_id)) || !main.some((a) => a.id === t.account_id)) continue;
    if (text(t.id).startsWith("recurring:")) continue;
    const due = day(m.dueDate ?? text(t.date));
    if (due > until) continue;
    items.push({ date: due < today ? today : due, what: `${text(t.description)} (pendente${due < today ? `, venceu em ${due}` : ""})`,
      amount: (t.type === "income" ? 1 : -1) * cents(num(t.amount)), kind: "pending" });
  }
  // Every invoice up to the day asked: what is entered (installments
  // included) plus the recurring charges of the card, in their cycle.
  const leftOut: string[] = [];
  for (const card of cardInvoices(l, today, undefined, false, { future: 14, planUntil: until }).cards) {
    const account = find(l.accounts, card.card_id);
    if (account?.exclude_from_total === 1) continue;
    // Paid from an account kept out of the available balance: like the
    // app, it does not leave the cash.
    const payer = find(l.accounts, account?.linked_account_id);
    if (payer && (payer.type === "credit" || payer.type === "gold" || payer.exclude_from_total === 1)) {
      leftOut.push(`Fatura ${card.card}: paga por conta fora do saldo disponível.`);
      continue;
    }
    // The card's day-to-day average, from tomorrow, in the invoice of each
    // day's cycle.
    const estimated = new Map<string, { due: string | null; cents: number }>();
    const perDay = daily?.cards.get(card.card_id) ?? 0;
    for (let d = addDays(today, 1); perDay > 0 && d <= until; d = addDays(d, 1)) {
      const c = cycleFor(d, card.closing_day ?? null, card.due_day ?? null);
      const e = estimated.get(c.end) ?? estimated.set(c.end, { due: c.due, cents: 0 }).get(c.end)!;
      e.cents += perDay;
    }
    const invoiceItem = (closing: string, due: string, entered: number, extra: number, recurring?: number) => {
      const owed = Math.max(entered + extra, 0);
      if (due > until || owed <= 0) return;
      const late = due < today;
      items.push({
        date: late ? today : due,
        what: `Fatura ${card.card} (${late ? "venceu em" : "vence"} ${due}${recurring ? `, com ${money(recurring)} de recorrentes previstas` : ""}${extra ? `, com ${money(Math.min(extra, owed))} de gasto do dia a dia estimado` : ""})`,
        amount: -owed,
        estimate: extra ? -Math.min(extra, owed) : undefined,
        kind: "invoice", cardId: card.card_id, closing,
      });
    };
    for (const inv of card.invoices) {
      const extra = estimated.get(inv.closing_date)?.cents ?? 0;
      estimated.delete(inv.closing_date);
      if (!inv.due_date) continue;
      const planned = inv.expected_recurring ? cents(inv.expected_recurring) : 0;
      invoiceItem(inv.closing_date, inv.due_date, cents(inv.total) + planned - cents(inv.paid), extra, planned || undefined);
    }
    for (const [closing, e] of estimated) if (e.due) invoiceItem(closing, e.due, 0, e.cents);
  }
  items.sort((a, b) => a.date.localeCompare(b.date));
  return { start, items, leftOut };
}

/// Day by day from today: the account's day-to-day spending leaves from
/// tomorrow; the lowest balance is the end of a day; the safe amount per
/// day uses the balance without any estimate.
export function walk(start: number, items: CashItem[], today: string, until: string, cashPerDay: number) {
  const sorted = [...items].sort((a, b) => a.date.localeCompare(b.date));
  let running = start, base = start, lowest = start, lowestDate = today, next = 0, n = 0, estimatedTotal = 0;
  let safe: number | null = null;
  const timeline: Record<string, unknown>[] = [];
  for (let d = today; d <= until; d = addDays(d, 1)) {
    if (d > today) { running -= cashPerDay; estimatedTotal += cashPerDay; n++; }
    for (; next < sorted.length && sorted[next].date <= d; next++) {
      const i = sorted[next];
      running += i.amount;
      base += i.amount - (i.estimate ?? 0);
      estimatedTotal -= i.estimate ?? 0;
      timeline.push({ date: i.date, what: i.what, amount: money(i.amount), balance_after: money(running),
        estimated: i.estimate ? money(-i.estimate) : undefined, simulated: i.kind === "simulated" || undefined });
    }
    if (running < lowest) { lowest = running; lowestDate = d; }
    if (n > 0 && (safe === null || base / n < safe)) safe = base / n;
  }
  return { timeline, end: running, lowest, lowestDate, safePerDay: safe === null || safe <= 0 ? 0 : Math.floor(safe + 1e-6),
    estimatedTotal };
}

export interface SimEvent {
  kind: "income" | "expense" | "sell_asset" | "sell_investment" | "partial_invoice";
  /// Day of the event (late days count today). For a sale, the order day.
  date?: string;
  /// Cents, positive.
  amount: number;
  label?: string;
  /// sell_investment: the kind of asset ("Ações", "Renda fixa"…).
  assetClass?: string;
  /// partial_invoice: the card.
  cardId?: string;
}

/// Hypothetical events over the base projection: what they add, when, and
/// what is estimated. Pure; [cards] gives each card's closing and due days
/// and the monthly interest of the revolving credit.
export function simulate(items: CashItem[], events: SimEvent[], today: string, until: string,
  cards: Map<string, { name: string; closing: number | null; due: number | null; interest: number | null }>) {
  const added: CashItem[] = [];
  const warnings: string[] = [];
  const on = (d?: string) => (!d || d < today ? today : d);
  for (const e of events) {
    const label = e.label?.trim();
    if (e.kind === "income" || e.kind === "expense" || e.kind === "sell_asset") {
      const d = on(e.date);
      if (d > until) { warnings.push(`${label || e.kind}: depois da data da simulação.`); continue; }
      added.push({ date: d, kind: "simulated", amount: e.kind === "expense" ? -e.amount : e.amount,
        what: label || (e.kind === "expense" ? "Saída simulada" : e.kind === "sell_asset" ? "Venda de bem simulada" : "Entrada simulada") });
    } else if (e.kind === "sell_investment") {
      const d = availableOn(e.assetClass ?? "", on(e.date));
      if (!d) { warnings.push(`${label || "Venda"}: tipo de investimento sem regra de liquidação; não entrou.`); continue; }
      if (d > until) { warnings.push(`${label || "Venda"}: o dinheiro só cai em ${d}, depois da data da simulação.`); continue; }
      added.push({ date: d, kind: "simulated", amount: e.amount, what: `${label || "Venda de investimento"} (cai em ${d})` });
    } else {
      const card = cards.get(e.cardId ?? "");
      const bill = items.find((i) => i.kind === "invoice" && i.cardId === e.cardId);
      if (!card || !bill || !bill.closing) { warnings.push("Pagamento parcial: nenhuma fatura deste cartão vence até a data."); continue; }
      const owed = -bill.amount;
      const left = owed - Math.min(e.amount, owed);
      if (left <= 0) { warnings.push(`Fatura ${card.name}: o valor paga a fatura toda.`); continue; }
      added.push({ date: bill.date, kind: "simulated", amount: left,
        what: `Fatura ${card.name}: paga ${money(owed - left)} de ${money(owed)}` });
      // The rest goes to the next invoice with one month of interest (never
      // more than the debt itself: Lei 14.690/2023). An estimate.
      const rate = card.interest ?? 0;
      if (card.interest == null) warnings.push(`${card.name}: sem juros do rotativo cadastrados; a simulação não soma juros.`);
      const interest = Math.min(Math.round(left * rate / 100), left);
      const next = cycleFor(bill.closing, card.closing, card.due).due;
      if (!next || next > until) {
        warnings.push(`Fatura ${card.name}: ${money(left)}${interest ? ` + ${money(interest)} de juros estimados` : ""} ficam para a fatura de ${next ?? "depois"}, fora da simulação.`);
        continue;
      }
      added.push({ date: next, kind: "simulated", amount: -(left + interest), estimate: interest ? -interest : undefined,
        what: `Resto da fatura ${card.name}${interest ? ` com ${money(interest)} de juros estimados (${rate}% ao mês)` : ""}` });
    }
  }
  return { items: [...items, ...added], added, warnings };
}
