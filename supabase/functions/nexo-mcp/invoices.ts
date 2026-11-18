// Credit card invoices from the synced ledger, with the app's rule
// (lib/services/billing_cycle.dart): a purchase made on the closing day
// ("melhor dia de compra") already belongs to the next invoice; payments are
// keyed by the closing date.
import { cents, day, isNeutral, type Ledger, meta, metadataIndex, money, num, type Row, text } from "./finance.ts";

const pad = (n: number) => String(n).padStart(2, "0");
const iso = (y: number, m: number, d: number) => {
  const base = new Date(Date.UTC(y, m - 1, 1));
  const last = new Date(Date.UTC(base.getUTCFullYear(), base.getUTCMonth() + 1, 0)).getUTCDate();
  return `${base.getUTCFullYear()}-${pad(base.getUTCMonth() + 1)}-${pad(Math.min(Math.max(d, 1), last))}`;
};
const parts = (s: string) => s.split("-").map(Number) as [number, number, number];
const addDays = (s: string, n: number) => {
  const [y, m, d] = parts(s);
  return new Date(Date.UTC(y, m - 1, d + n)).toISOString().slice(0, 10);
};

const addMonths = (s: string, n: number, dayOfMonth: number) => {
  const [y, m] = parts(s);
  return iso(y, m + n, dayOfMonth);
};

/// Occurrences of a recurring item from its next date up to [until].
export function occurrences(r: Row, until: string): string[] {
  const out: string[] = [];
  const unit = text(r.freq_unit) || "months";
  const every = Math.max(1, num(r.freq_val) || 1);
  const end = r.end_date ? day(text(r.end_date)) : null;
  let d = day(text(r.next_date));
  const anchor = Number(d.slice(8, 10));
  for (let i = 0; i < 400 && d <= until && (!end || d <= end); i++) {
    out.push(d);
    d = unit === "days" ? addDays(d, every) : unit === "weeks" ? addDays(d, 7 * every)
      : unit === "years" ? addMonths(d, 12 * every, anchor) : addMonths(d, every, anchor);
  }
  return out;
}

export interface Cycle { start: string; end: string; due: string | null }

export function cycleFor(date: string, closingDay: number | null, dueDay: number | null): Cycle {
  const [y, m] = parts(date);
  const dueAfter = (end: string) => {
    if (dueDay == null) return null;
    const [ey, em] = parts(end);
    const due = iso(ey, em, dueDay);
    return due > end ? due : iso(ey, em + 1, dueDay);
  };
  if (closingDay == null) {
    const end = iso(y, m, 31);
    return { start: iso(y, m, 1), end, due: dueAfter(end) };
  }
  let end = iso(y, m, closingDay);
  if (date >= end) end = iso(y, m + 1, closingDay);
  const [ey, em] = parts(end);
  return { start: iso(ey, em - 1, closingDay), end, due: dueAfter(end) };
}

export interface InvoiceOptions {
  /// How many invoices after the open one to list (the nearest ones).
  future?: number;
  /// Recurring charges of the card are planned up to this day.
  planUntil?: string;
}

/// The invoices of each credit card, newest first: the ones still to come
/// (installments already entered and recurring charges of the card), the
/// open one and the last closed ones.
export function cardInvoices(l: Ledger, today: string, cardId?: string, withItems = false,
  options: InvoiceOptions = {}) {
  const metas = metadataIndex(l);
  const future = options.future ?? 3;
  const planUntil = options.planUntil ?? addDays(today, 31 * (future + 1));
  const entered = new Set(l.transactions.map((t) => text(t.id)));
  const out = [];
  type Item = { id: string; date: string; kind: string; description: string; amount: number; installment?: string };
  for (const card of l.accounts.filter((a) => a.type === "credit" && (!cardId || a.id === cardId))) {
    const closing = typeof card.statement_day === "number" ? card.statement_day : null;
    const dueDay = typeof card.due_day === "number" ? card.due_day : null;
    const byEnd = new Map<string, { cycle: Cycle; total: number; paid: number; planned: number; items: Item[] }>();
    const slot = (c: Cycle) =>
      byEnd.get(c.end) ?? byEnd.set(c.end, { cycle: c, total: 0, paid: 0, planned: 0, items: [] }).get(c.end)!;
    for (const tx of l.transactions) {
      if (tx.account_id !== card.id) continue;
      const m = meta(metas.get(text(tx.id)));
      // A credit still forecast has not happened: it lowers nothing yet.
      if (tx.type === "income" && m.status === "pending") continue;
      if (isNeutral(tx, m) && m.source !== "opening_balance" && !m.source.startsWith("shared_bill:")) continue;
      const s = slot(cycleFor(day(text(tx.date)), closing, dueDay));
      s.total += (tx.type === "income" ? -1 : 1) * cents(num(tx.amount));
      if (withItems) {
        s.items.push({
          id: text(tx.id), date: day(text(tx.date)),
          kind: m.source === "opening_balance" ? "ajuste" : tx.type === "income" ? "estorno" : "compra",
          description: text(tx.description), amount: money(cents(num(tx.amount))),
          installment: m.installmentCurrent && m.installmentTotal ? `${m.installmentCurrent}/${m.installmentTotal}` : undefined,
        });
      }
    }
    for (const p of (l.invoicePayments ?? []) as Row[]) {
      if (p.card_id !== card.id) continue;
      const end = text(p.cycle_end).slice(0, 10);
      const s = byEnd.get(end) ?? slot({ ...cycleFor(addDays(end, -1), closing, dueDay) });
      s.paid += cents(num(p.amount));
      if (withItems) {
        s.items.push({ id: text(p.id), date: day(text(p.paid_at)), kind: "pagamento", description: "Pagamento da fatura",
          amount: money(cents(num(p.amount))) });
      }
    }
    // Recurring charges of the card that are not entries yet go to the
    // invoice of their own cycle, like the app's forecast.
    for (const r of l.recurring) {
      if (r.account_id !== card.id) continue;
      const first = text(r.next_date);
      for (const d of occurrences(r, planUntil)) {
        if (d === day(first) && entered.has(`recurring:${text(r.id)}:${first}`)) continue;
        slot(cycleFor(d, closing, dueDay)).planned += (r.payment_type === "income" ? -1 : 1) * cents(num(r.amount));
      }
    }
    const current = cycleFor(today, closing, dueDay);
    slot(current);
    const recent = [...byEnd.values()]
      .filter((s) => s.cycle.end >= addDays(today, -100))
      .sort((a, b) => b.cycle.end.localeCompare(a.cycle.end));
    // With installments there are many invoices ahead: the nearest ones, and
    // never at the cost of the open and the closed ones.
    const ahead = recent.filter((s) => s.cycle.end > current.end && (s.total !== 0 || s.planned !== 0));
    const invoices = [...ahead.slice(Math.max(ahead.length - future, 0)), ...recent.filter((s) => s.cycle.end <= current.end).slice(0, 4)]
      .map(({ cycle, total, paid, planned, items }) => {
        const remaining = Math.max(total - paid, 0);
        const closed = today >= cycle.end;
        const status = cycle.end > current.end ? "futura"
          : !closed ? "aberta"
          : remaining === 0 ? "paga"
          : cycle.due && today > cycle.due ? "atrasada" : "fechada";
        return {
          closing_date: cycle.end, due_date: cycle.due ?? undefined,
          purchases_from: cycle.start, purchases_until: addDays(cycle.end, -1),
          total: money(total), paid: money(paid), remaining: money(remaining), status,
          expected_recurring: planned !== 0 ? money(planned) : undefined,
          expected_remaining: planned !== 0 ? money(Math.max(total + planned - paid, 0)) : undefined,
          transactions: withItems ? items.sort((a, b) => a.date.localeCompare(b.date)) : undefined,
        };
      });
    const limit = typeof card.credit_limit === "number" ? cents(card.credit_limit) : null;
    // Every installment already entered takes limit, listed here or not.
    const owed = recent.reduce((s, i) => s + Math.max(i.total - i.paid, 0), 0);
    out.push({
      card_id: text(card.id), card: text(card.name),
      closing_day: closing ?? undefined, due_day: dueDay ?? undefined,
      credit_limit: limit == null ? undefined : money(limit),
      limit_used_percent: limit ? Math.round((owed / limit) * 100) : undefined,
      invoices,
    });
  }
  return {
    cards: out,
    note: "Compras feitas no dia do fechamento entram na fatura seguinte. total é o que já está lançado; expected_recurring são as recorrentes do cartão que ainda vão entrar naquela fatura, e expected_remaining a soma. Faturas futuras trazem parcelas já lançadas e recorrentes. limit_used_percent conta todas as parcelas lançadas. Pagar fatura: pay_card_invoice (invoice closed = a fechada mais recente).",
  };
}
