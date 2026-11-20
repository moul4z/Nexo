// Bank movements (Open Finance suggestions) against the ledger, with the
// same rules as lib/services/reconciliation.dart. Both run the cases in
// test/fixtures/reconcile_cases.json; a difference fails a test.
//
// Decides what each pending movement is before anyone looks at it: the
// same entry already in the Nexo, money between the person's own accounts,
// a card bill paid from the bank, a payment and its refund, a yield, the
// IOF of an international purchase, or something new. Never creates money:
// it only says what to do, and the app does it with its own rules.

export type Direction = "in" | "out";

export interface Movement {
  id: string;
  amountCents: number;
  kind: string; // expense | income | refund | transfer
  medium: string; // bank | credit
  description: string;
  occurredAt: number; // epoch ms
  direction: Direction | null;
  accountId: string | null; // bank account at Pluggy
  nexoAccountId: string | null; // the Nexo account it is linked to
  operationRef: string | null;
  paymentRef: string | null;
  sameOwner: boolean | null;
  counterparty: string | null;
  /// Pending at the bank and no longer returned by it (cancelled, or back
  /// later under another id).
  vanished?: boolean;
}

export interface Entry {
  id: string;
  type: string; // income | expense
  cents: number;
  description: string;
  accountId: string;
  day: string; // YYYY-MM-DD
  source: string;
  categoryId: string;
}

/// A card bill payment already in the Nexo: the two legs of the transfer.
export interface PaymentLegs {
  debitId: string; // leaves the bank account
  creditId: string; // arrives on the card
  cents: number;
  day: string;
  fromAccountId: string;
  cardId: string;
}

export interface Rule {
  id: string;
  pattern: string;
  type: string; // expense | income | transfer | internal
  categoryId: string;
  auto: boolean;
  targetAccountId: string | null;
}

export type Resolution =
  | "linked" | "maybe" | "internal" | "ownTransfer" | "ownName" | "invoicePayment"
  | "reversal" | "reserve" | "yield" | "iof" | "rule" | "recurring" | "receivable" | "newEntry";

/// What someone owes the person and pays back by Pix (OpenReceivable in
/// reconciliation.dart): the person's name and the name their Pix showed.
export interface OpenReceivable {
  id: string;
  personId: string;
  names: string[];
  cents: number;
  day: string; // YYYY-MM-DD
}

/// How long after the bill a Pix may still be someone paying their part.
export const RECEIVABLE_DAYS = 40;

/// Open parts a Pix may settle: lent, no account, not settled.
export function openReceivables(lended: Record<string, unknown>[], people: Record<string, unknown>[]): OpenReceivable[] {
  const byId = new Map(people.map((p) => [String(p.id), p]));
  return lended
    .filter((l) => (l.type ?? "lent") === "lent" && !Number(l.is_settled) && !l.account_id && byId.has(String(l.person_id)))
    .map((l) => {
      const p = byId.get(String(l.person_id))!;
      return {
        id: String(l.id), personId: String(l.person_id),
        names: [String(p.name ?? ""), ...(p.pix_name ? [String(p.pix_name)] : [])],
        cents: Math.round(Number(l.amount) * 100), day: String(l.date).slice(0, 10),
      };
    });
}

/// Whether [text] names one of [names]: name and surname, whole words.
export function namesPerson(text: string, names: string[]): boolean {
  const n = normalizeMerchant(text);
  if (!n) return false;
  return names.map(normalizeMerchant).some((name) =>
    name.split(" ").length >= 2 && (` ${n} `.includes(` ${name} `) || textSimilarity(n, name) >= 0.99));
}

/// The next occurrence of a recurring payment: what the bank should show if
/// it was paid (recurringDue in reconciliation.dart).
export interface RecurringDue {
  id: string;
  name: string;
  accountId: string;
  type: string; // expense | income
  cents: number;
  day: string; // YYYY-MM-DD
}

/// How far the bank may be from the recurring: the amount within 7.5% (or
/// R$ 1), the day from 3 before to 5 after.
export function recurringFits(r: RecurringDue, cents: number, dayDiff: number): boolean {
  const tolerance = Math.round(r.cents * 0.075);
  return Math.abs(cents - r.cents) <= Math.max(tolerance, 100) && dayDiff >= -3 && dayDiff <= 5;
}

export interface Match {
  id: string;
  resolution: Resolution;
  /// Applied without asking (on the device that writes, for new entries).
  automatic: boolean;
  transactionId?: string;
  pairId?: string;
  score?: number;
  categoryId?: string;
  ruleId?: string;
  wrongAccount?: boolean;
  /// Transfer between two Nexo accounts.
  fromAccountId?: string;
  toAccountId?: string;
  /// The other side may still arrive (banks report a day apart).
  waiting?: boolean;
  /// Linked together with the IOF charged the next day.
  withIof?: string;
  /// For "recurring": the recurring payment it pays.
  recurringId?: string;
  /// For "receivable": the "a receber" it settles.
  receivableId?: string;
}

export interface Options {
  linkedIds?: Set<string>;
  ownerNames?: string[];
  dismissedPairs?: Set<string>;
  creditAccounts?: Set<string>;
  payments?: PaymentLegs[];
  /// Movements already linked to an entry (decided on an earlier day): the
  /// purchase an IOF belongs to is usually one of them.
  settled?: { movement: Movement; transactionId: string }[];
  rules?: Rule[];
  /// The open occurrence of each recurring payment.
  recurring?: RecurringDue[];
  /// Parts people still owe (split bills).
  receivables?: OpenReceivable[];
  learnedCategory?: (m: Movement) => string | null;
  now?: number;
}

// ── Text ──────────────────────────────────────────────────────────────────

const NOISE = /^(ifd\*|ifd |mp \*|mp\*|pg \*|pg\*|pag\*|pp\*|ec \*|dl\*|ebn\*)/i;
const MOVEMENT_WORDS =
  /\b(pix|ted|doc|transf\w*|enviad[oa]|recebid[oa]|pagamento|pagto|pgto|com|de|para|do|da|por|compra|no|na|em|cartao|debito|credito|qr|code|ltda|me|eireli|sa)\b/g;
const ACCENTS: Record<string, string> = {
  "á": "a", "à": "a", "â": "a", "ã": "a", "é": "e", "ê": "e", "í": "i",
  "ó": "o", "ô": "o", "õ": "o", "ú": "u", "ü": "u", "ç": "c",
};

/// Merchant or counterparty without card prefixes, numbers, accents and
/// movement words: "Pix enviado - Vorex Ltda" → "vorex".
export function normalizeMerchant(text: string): string {
  let s = text.trim().toLowerCase().replace(NOISE, "");
  s = [...s].map((c) => ACCENTS[c] ?? c).join("");
  s = s.replace(/[0-9]/g, " ").replace(/[^a-z ]/g, " ").replace(MOVEMENT_WORDS, " ");
  return s.replace(/\s+/g, " ").trim();
}

/// token_set_ratio-like similarity, 0..1.
export function textSimilarity(a: string, b: string): number {
  const ta = new Set(normalizeMerchant(a).split(" ").filter((t) => t.length > 1));
  const tb = new Set(normalizeMerchant(b).split(" ").filter((t) => t.length > 1));
  if (!ta.size || !tb.size) return 0;
  let common = 0;
  for (const t of ta) if (tb.has(t)) common++;
  if (common === 0) {
    for (const x of ta) {
      for (const y of tb) {
        if (x.length >= 4 && y.length >= 4 && (x.includes(y) || y.includes(x))) return 0.8;
      }
    }
    return 0;
  }
  return common / Math.min(ta.size, tb.size);
}

const RESERVE = /reserva por gasto|dinheiro retirado|reserva autom/i;
const YIELD = /rendimento|remunera[cç][aã]o|juros sobre saldo/i;
const REFUND_WORDS = /estorno|devolu|devolvid|cancelad|reembolso/i;
// On the accent-free name: the whole refund word, whatever its ending.
const REFUND_STRIP = /\b(estorn|devolu|devolvid|cancelad|reembols)\w*/g;
// Salary and benefits also say "remuneração": never a yield.
const NOT_YIELD = /sal[aá]rio|folha|pr[oó].?labore|f[eé]rias|benef[ií]cio|pagamento/i;
/// Above this a yield is asked about instead of registered by itself.
export const YIELD_AUTO_CENTS = 10000;
const RECEIVED = /recebid|pix|ted|transfer/i;
const CARD_BILL = /nu pagamentos|pagamento de fatura|pagamento da fatura|pagto fatura|pgto fatura|fatura do cart|pagamento cart[aã]o/i;
const IOF = /\biof\b/i;

// ── Dates: days in Brasília (UTC−3, no daylight saving since 2019) ────────

const DAY = 86400000;
export const movementDay = (ms: number) => Math.floor((ms - 3 * 3600000) / DAY);
export const entryDay = (iso: string) => {
  const [y, m, d] = iso.slice(0, 10).split("-").map(Number);
  return Math.floor(Date.UTC(y, m - 1, d) / DAY);
};

export function direction(m: Movement): Direction {
  if (m.direction) return m.direction;
  if (m.kind === "expense") return "out";
  if (m.kind === "income" || m.kind === "refund") return "in";
  if (m.medium === "credit") return "in";
  return /rendimento|remunera|resgate|recebid/i.test(m.description) ? "in" : "out";
}

const words = (m: Movement) => `${m.description} ${m.counterparty ?? ""}`;

// ── The rules ─────────────────────────────────────────────────────────────

/// Card bill payments in the Nexo, from the transfer legs.
export function paymentLegs(entries: Entry[], credit: Set<string>): PaymentLegs[] {
  const bySource = new Map<string, Entry[]>();
  for (const e of entries) {
    if (!(e.source ?? "").startsWith("transfer:")) continue;
    bySource.set(e.source, [...(bySource.get(e.source) ?? []), e]);
  }
  const legs: PaymentLegs[] = [];
  for (const pair of bySource.values()) {
    if (pair.length !== 2) continue;
    for (const [debit, into] of [[pair[0], pair[1]], [pair[1], pair[0]]]) {
      if (debit.type === "expense" && into.type === "income" && credit.has(into.accountId) && !credit.has(debit.accountId)) {
        legs.push({ debitId: debit.id, creditId: into.id, cents: into.cents, day: into.day,
          fromAccountId: debit.accountId, cardId: into.accountId });
      }
    }
  }
  return legs;
}

export function reconcile(movements: Movement[], entries: Entry[], options: Options = {}): Match[] {
  const out = new Map<string, Match>();
  const used = new Set(options.linkedIds ?? []);
  const dismissed = options.dismissedPairs ?? new Set<string>();
  const credit = options.creditAccounts ?? new Set<string>();
  const now = options.now ?? Date.now();
  // A first name alone would match any namesake: name and surname only.
  const owners = (options.ownerNames ?? []).map(normalizeMerchant).filter((n) => n.split(" ").length >= 2);
  const dir = new Map(movements.map((m) => [m.id, direction(m)]));
  // Ties are broken by position, so the Dart and TypeScript sorts agree.
  const at = new Map(movements.map((m, i) => [m.id, i]));
  const pos = (m: Movement) => at.get(m.id)!;
  const isOut = (m: Movement) => dir.get(m.id) === "out";
  const mday = (m: Movement) => movementDay(m.occurredAt);
  const open = () => movements.filter((m) => !out.has(m.id));
  const set = (m: Movement, match: Omit<Match, "id">) => out.set(m.id, { id: m.id, ...match });
  const mentionsOwner = (m: Movement) => {
    if (m.sameOwner === true) return true;
    const n = normalizeMerchant(words(m));
    // Whole words: "ana teste" is not inside "mariana testerman".
    return owners.some((o) => ` ${n} `.includes(` ${o} `) || textSimilarity(n, o) >= 0.99);
  };
  const thirdParty = (m: Movement) => normalizeMerchant(words(m)) !== "" && !mentionsOwner(m);
  const waiting = (m: Movement) => now - m.occurredAt < 2 * DAY;

  // 1. Reserve moves and yields: never spending. A yield already typed by
  // hand is linked, never registered again; a large one is asked about.
  for (const m of movements) {
    if (RESERVE.test(m.description)) {
      set(m, { resolution: "reserve", automatic: true });
    } else if (!isOut(m) && YIELD.test(m.description) && !NOT_YIELD.test(m.description)) {
      const twin = entries
        .map((e, i) => ({ e, i, days: Math.abs(entryDay(e.day) - mday(m)) }))
        .filter(({ e, days }) => e.type === "income" && e.cents === m.amountCents && !used.has(e.id) && days <= 3 &&
          !(e.source ?? "").startsWith("transfer:") && (e.source ?? "") !== "opening_balance" &&
          (!m.nexoAccountId || e.accountId === m.nexoAccountId))
        .sort((a, b) => a.days - b.days || a.i - b.i)[0];
      if (twin) {
        used.add(twin.e.id);
        set(m, { resolution: "linked", automatic: true, transactionId: twin.e.id, score: 100 });
      } else {
        set(m, { resolution: "yield", automatic: m.amountCents <= YIELD_AUTO_CENTS });
      }
    }
  }

  // 1b. The same movement back under another id: the bank stopped returning
  // a pending one already linked to an entry and returns it again, renamed.
  // Same bank account, direction and amount, close in time and in words:
  // the same entry, never a second one.
  const settled = options.settled ?? [];
  const reborn = new Set<string>();
  for (const m of open()) {
    const gone = settled.map((s, i) => ({ s, i }))
      .filter(({ s }) =>
        s.movement.vanished === true && !reborn.has(s.transactionId) &&
        entries.some((e) => e.id === s.transactionId) &&
        s.movement.accountId !== null && s.movement.accountId === m.accountId &&
        direction(s.movement) === dir.get(m.id) && s.movement.amountCents === m.amountCents &&
        Math.abs(mday(m) - mday(s.movement)) <= 3 &&
        textSimilarity(s.movement.description, m.description) >= 0.6)
      .sort((a, b) =>
        (Math.abs(mday(m) - mday(a.s.movement)) - Math.abs(mday(m) - mday(b.s.movement))) || a.i - b.i);
    if (!gone.length) continue;
    const { s } = gone[0];
    reborn.add(s.transactionId);
    set(m, { resolution: "linked", automatic: true, transactionId: s.transactionId, pairId: s.movement.id, score: 100 });
  }

  // 2. A payment and its refund: the bank's operation id, or refund words
  // from the same merchant within 30 days, or the same merchant giving the
  // money back the same day.
  for (const paid of open().filter(isOut)) {
    if (out.has(paid.id)) continue;
    const backs = open().filter((b) => !isOut(b) && !out.has(b.id) && b.amountCents === paid.amountCents &&
      (b.accountId ?? "") === (paid.accountId ?? "") && mday(b) >= mday(paid) && mday(b) - mday(paid) <= 30)
      .sort((a, b) => a.occurredAt - b.occurredAt || pos(a) - pos(b));
    const byRef = backs.find((b) =>
      (paid.operationRef && b.operationRef === paid.operationRef) || (paid.paymentRef && b.paymentRef === paid.paymentRef));
    const byWords = backs.find((b) => {
      if (!(b.kind === "refund" || REFUND_WORDS.test(b.description))) return false;
      const rest = normalizeMerchant(b.description).replace(REFUND_STRIP, " ").replace(/\s+/g, " ").trim();
      if (rest === "" || rest === "dinheiro" || rest === "valor") {
        // "Reembolso" alone: only close in time and with nothing else alike.
        return mday(b) - mday(paid) <= 7 && open().filter((p) => p.id !== paid.id && isOut(p) &&
          p.amountCents === paid.amountCents && Math.abs(mday(p) - mday(b)) <= 7).length === 0;
      }
      return textSimilarity(paid.description, b.description) >= 0.6;
    });
    const sameDay = backs.find((b) => mday(b) === mday(paid) &&
      textSimilarity(paid.description, b.description) >= 0.6 && !RECEIVED.test(b.description) && !mentionsOwner(b));
    const back = byRef ?? byWords ?? sameDay;
    if (back) {
      set(paid, { resolution: "reversal", automatic: true, pairId: back.id });
      set(back, { resolution: "reversal", automatic: true, pairId: paid.id });
    }
  }

  // 3. The IOF of an international purchase, charged up to 3 days later:
  // remembered with the purchase, decided with it below.
  const iofOf = new Map<string, Movement>();
  const iofTaken = new Set(settled.filter((s) => IOF.test(s.movement.description)).map((s) => s.transactionId));
  const near = (ratio: number) => Math.abs(ratio - 0.035);
  for (const iof of open().filter((m) => m.medium === "credit" && isOut(m) && IOF.test(m.description))) {
    const purchase = open()
      .filter((p) => p.id !== iof.id && p.medium === "credit" && isOut(p) && !IOF.test(p.description) &&
        !iofOf.has(p.id) && (p.accountId ?? "") === (iof.accountId ?? "") &&
        mday(iof) - mday(p) >= 0 && mday(iof) - mday(p) <= 3 &&
        iof.amountCents / p.amountCents >= 0.025 && iof.amountCents / p.amountCents <= 0.07)
      .sort((a, b) => Math.abs(iof.amountCents / a.amountCents - 0.035) - Math.abs(iof.amountCents / b.amountCents - 0.035) ||
        pos(a) - pos(b))[0];
    if (purchase) {
      iofOf.set(purchase.id, iof);
      continue;
    }
    // The purchase was decided on an earlier day: the IOF goes into its
    // entry, unless the entry already has it.
    const done = settled
      .map((s, i) => ({ ...s, i, ratio: iof.amountCents / s.movement.amountCents }))
      .filter((s) => s.movement.medium === "credit" && direction(s.movement) === "out" &&
        !IOF.test(s.movement.description) && !iofTaken.has(s.transactionId) &&
        (s.movement.accountId ?? "") === (iof.accountId ?? "") &&
        mday(iof) - mday(s.movement) >= 0 && mday(iof) - mday(s.movement) <= 3 &&
        s.ratio >= 0.025 && s.ratio <= 0.07)
      .sort((a, b) => near(a.ratio) - near(b.ratio) || a.i - b.i)[0];
    const entry = done && entries.find((e) => e.id === done.transactionId);
    if (done && entry && entry.type === "expense") {
      iofTaken.add(entry.id);
      const included = Math.abs(entry.cents - (done.movement.amountCents + iof.amountCents)) <= 1;
      set(iof, included
        ? { resolution: "linked", automatic: true, transactionId: entry.id, pairId: done.movement.id, score: 100 }
        : {
          resolution: "iof",
          automatic: entry.cents === done.movement.amountCents,
          transactionId: entry.id,
          pairId: done.movement.id,
        });
    }
  }
  const iofs = new Set([...iofOf.values()].map((m) => m.id));

  // 4. A card bill paid from the bank: the bank side ("Pagamento com Pix NU
  // PAGAMENTOS") and the card side ("Pagamento recebido"), tied to the
  // payment already in the Nexo when there is one.
  const cardSides = open().filter((m) => m.medium === "credit" && !isOut(m) && m.kind !== "refund" &&
    !REFUND_WORDS.test(m.description) && (m.kind === "transfer" || /pagamento/i.test(m.description)));
  const bankSides = open().filter((m) => m.medium !== "credit" && isOut(m) && CARD_BILL.test(words(m)));
  const payments = [...(options.payments ?? paymentLegs(entries, credit))];
  const usedPayments = new Set<string>();
  const pairs: [Movement | null, Movement | null][] = [];
  const takenCard = new Set<string>();
  for (const b of bankSides) {
    const c = cardSides.filter((x) => !takenCard.has(x.id) && x.amountCents === b.amountCents &&
      Math.abs(mday(x) - mday(b)) <= 3)
      .sort((x, y) => Math.abs(mday(x) - mday(b)) - Math.abs(mday(y) - mday(b)) || pos(x) - pos(y))[0];
    if (c) takenCard.add(c.id);
    pairs.push([b, c ?? null]);
  }
  for (const c of cardSides) if (!takenCard.has(c.id)) pairs.push([null, c]);
  for (const [bank, card] of pairs) {
    const any = (bank ?? card)!;
    const leg = payments.filter((p) => !usedPayments.has(p.debitId) && !used.has(p.debitId) && !used.has(p.creditId) &&
      p.cents === any.amountCents && Math.abs(entryDay(p.day) - mday(any)) <= 3 &&
      (!card?.nexoAccountId || p.cardId === card.nexoAccountId) &&
      (!bank?.nexoAccountId || p.fromAccountId === bank.nexoAccountId))
      .sort((p, q) => Math.abs(entryDay(p.day) - mday(any)) - Math.abs(entryDay(q.day) - mday(any)) ||
        payments.indexOf(p) - payments.indexOf(q))[0];
    if (leg) {
      usedPayments.add(leg.debitId);
      used.add(leg.debitId);
      used.add(leg.creditId);
      if (bank) set(bank, { resolution: "linked", automatic: true, transactionId: leg.debitId, pairId: card?.id, score: 100 });
      if (card) set(card, { resolution: "linked", automatic: true, transactionId: leg.creditId, pairId: bank?.id, score: 100 });
    } else {
      const cardId = card?.nexoAccountId ?? (credit.size === 1 ? [...credit][0] : undefined);
      const match = {
        resolution: "invoicePayment" as const, automatic: false, toAccountId: cardId,
        fromAccountId: bank?.nexoAccountId ?? undefined, waiting: !(bank && card) && waiting(any),
      };
      if (bank) set(bank, { ...match, pairId: card?.id });
      if (card) set(card, { ...match, pairId: bank?.id });
    }
  }

  // 4b. Transfers already in the Nexo (made by hand or by the assistant):
  // the bank's sides are their legs. Before pairing, so nothing is
  // registered twice.
  for (const m of open()) {
    if (iofs.has(m.id)) continue;
    if (!(mentionsOwner(m) || (m.kind === "transfer" && !thirdParty(m)))) continue;
    const leg = entries
      .map((e, i) => ({ e, i, days: Math.abs(entryDay(e.day) - mday(m)) }))
      .filter(({ e, days }) => (e.source ?? "").startsWith("transfer:") && !used.has(e.id) &&
        e.type === (isOut(m) ? "expense" : "income") && e.cents === m.amountCents && days <= 3 &&
        (!m.nexoAccountId || e.accountId === m.nexoAccountId))
      .sort((a, b) => a.days - b.days || a.i - b.i)[0];
    if (!leg) continue;
    used.add(leg.e.id);
    set(m, m.nexoAccountId
      ? { resolution: "linked", automatic: true, transactionId: leg.e.id, score: 100 }
      : { resolution: "maybe", automatic: false, transactionId: leg.e.id, score: 90 });
  }

  // 5. Money between the person's own accounts: same amount, opposite
  // directions, the same day or the next, with evidence that both sides
  // are the person (same tax number, the person's name, or two accounts
  // linked to the same Nexo account with nobody else named).
  for (const o of open().filter(isOut)) {
    if (out.has(o.id) || iofs.has(o.id)) continue;
    const candidates = open()
      .filter((i) => !isOut(i) && !out.has(i.id) && i.kind !== "refund" && i.amountCents === o.amountCents &&
        Math.abs(mday(i) - mday(o)) <= 1)
      .sort((a, b) => Math.abs(a.occurredAt - o.occurredAt) - Math.abs(b.occurredAt - o.occurredAt) || pos(a) - pos(b));
    for (const i of candidates) {
      const sameNexo = !!o.nexoAccountId && o.nexoAccountId === i.nexoAccountId;
      // Two bank accounts, or at least one unknown (older rows, phone
      // notifications): the same known account is not a move between two.
      const apart = !o.accountId || !i.accountId || o.accountId !== i.accountId;
      const owner = o.sameOwner === true || i.sameOwner === true || (mentionsOwner(o) && mentionsOwner(i));
      const sameName = normalizeMerchant(words(o)) !== "" && textSimilarity(words(o), words(i)) >= 0.99;
      const nameless = sameNexo && apart && !thirdParty(o) && !thirdParty(i);
      if (!(owner && (apart || sameNexo)) && !(sameName && apart) && !nameless) continue;
      const known = !!o.nexoAccountId && !!i.nexoAccountId;
      const ownProof = owner || nameless;
      const match: Omit<Match, "id" | "pairId"> = sameNexo && ownProof
        ? { resolution: "internal", automatic: true }
        : known && ownProof
        ? { resolution: "ownTransfer", automatic: true, fromAccountId: o.nexoAccountId!, toAccountId: i.nexoAccountId! }
        : { resolution: "ownTransfer", automatic: false };
      set(o, { ...match, pairId: i.id });
      set(i, { ...match, pairId: o.id });
      break;
    }
  }

  // 6. Entries already in the Nexo: one movement, one entry, same kind,
  // close in time, best pairs first. Money to or from the person's own name
  // is never spending, so it never stands for an entry.
  const candidates = entries.filter((e) => !used.has(e.id) && !e.id.startsWith("notification:") &&
    !(e.source ?? "").startsWith("transfer:") && e.source !== "opening_balance");
  const rest = open().filter((m) => !iofs.has(m.id) && m.kind !== "transfer" && !mentionsOwner(m));
  type Option = {
    m: Movement; e: Entry; score: number; days: number; exact: boolean; withIof?: Movement; wrong: boolean; ei: number;
  };
  const options_: Option[] = [];
  const learned = (m: Movement) => options.learnedCategory?.(m) ?? null;
  for (const m of rest) {
    const category = learned(m);
    const iof = iofOf.get(m.id);
    for (const [ei, e] of candidates.entries()) {
      if ((isOut(m) ? "expense" : "income") !== e.type) continue;
      const wrong = credit.size > 0 && (m.medium === "credit") !== credit.has(e.accountId);
      // Another account of the same kind is another account.
      if (m.nexoAccountId && e.accountId !== m.nexoAccountId && !wrong) continue;
      for (const target of iof ? [m.amountCents + iof.amountCents, m.amountCents] : [m.amountCents]) {
        const rel = Math.abs(e.cents - target) / (target > 0 ? target : 1);
        const days = Math.abs(entryDay(e.day) - mday(m));
        if (rel > 0.3 || days > 7) continue;
        let s = 50 * (1 - rel / 0.3) + 35 * textSimilarity(m.description, e.description) + 15 * (1 - days / 7);
        if (category && category === e.categoryId) s += 25;
        const score = Math.max(0, Math.min(100, Math.round(s)));
        if (score > 0) {
          options_.push({ m, e, score, days, exact: e.cents === target, wrong, ei,
            withIof: iof && target !== m.amountCents ? iof : undefined });
        }
      }
    }
  }
  options_.sort((a, b) => b.score - a.score || a.days - b.days || (a.withIof ? 0 : 1) - (b.withIof ? 0 : 1) ||
    pos(a.m) - pos(b.m) || a.ei - b.ei);
  const unique = (o: Option) =>
    options_.filter((x) => x.m.id === o.m.id && x.exact && x.days <= 1).length === 1 &&
    rest.filter((x) => x.id !== o.m.id && x.amountCents === o.m.amountCents && isOut(x) === isOut(o.m) &&
      Math.abs(mday(x) - mday(o.m)) <= 1).length === 0;
  for (const o of options_) {
    if (out.has(o.m.id) || used.has(o.e.id) || dismissed.has(`${o.m.id}|${o.e.id}`)) continue;
    const similar = textSimilarity(o.m.description, o.e.description) >= 0.6;
    if (o.wrong || !o.exact || o.days > 3 || !(similar || (o.days <= 1 && unique(o)))) continue;
    used.add(o.e.id);
    set(o.m, { resolution: "linked", automatic: true, transactionId: o.e.id, score: Math.max(o.score, 85),
      withIof: o.withIof?.id });
    if (o.withIof) set(o.withIof, { resolution: "linked", automatic: true, transactionId: o.e.id, pairId: o.m.id, score: 85 });
  }

  // 6b. The open occurrence of a recurring payment: same direction and
  // account, a similar name, an amount and a day close to what was
  // expected. Never over an entry that may be the same (that is a question
  // below), and never by itself: the person confirms, and the recurring
  // advances instead of staying open next to a loose entry.
  const maybeTwin = (o: Option) =>
    !used.has(o.e.id) && !dismissed.has(`${o.m.id}|${o.e.id}`) &&
    (o.wrong ? o.exact && o.days <= 3
      : o.score >= 45 && (o.days <= 3 || textSimilarity(o.m.description, o.e.description) >= 0.6));
  const dues: { m: Movement; gap: number; r: RecurringDue; days: number; ri: number }[] = [];
  for (const m of rest) {
    if (out.has(m.id) || options_.some((o) => o.m.id === m.id && maybeTwin(o))) continue;
    for (const [ri, r] of (options.recurring ?? []).entries()) {
      if (r.type !== (isOut(m) ? "expense" : "income")) continue;
      if (m.nexoAccountId
        ? r.accountId !== m.nexoAccountId
        : credit.size > 0 && (m.medium === "credit") !== credit.has(r.accountId)) continue;
      const diff = mday(m) - entryDay(r.day);
      if (!recurringFits(r, m.amountCents, diff) || textSimilarity(words(m), r.name) < 0.6) continue;
      dues.push({ m, gap: Math.abs(m.amountCents - r.cents), r, days: Math.abs(diff), ri });
    }
  }
  dues.sort((a, b) => a.gap - b.gap || a.days - b.days || pos(a.m) - pos(b.m) || a.ri - b.ri);
  const paidNow = new Set<string>();
  for (const { m, r } of dues) {
    if (out.has(m.id) || paidNow.has(r.id)) continue;
    paidNow.add(r.id);
    set(m, { resolution: "recurring", automatic: false, recurringId: r.id });
  }

  // 6c. Someone paying back their part: money in, naming the person, the
  // exact amount, up to 40 days after the bill; by itself only when a
  // single person fits, the oldest of their parts first.
  const paidBack = new Set<string>();
  for (const m of rest) {
    if (out.has(m.id) || isOut(m) || options_.some((o) => o.m.id === m.id && maybeTwin(o))) continue;
    const fits = (options.receivables ?? []).filter((r) => {
      const days = mday(m) - entryDay(r.day);
      return !paidBack.has(r.id) && r.cents === m.amountCents && days >= 0 && days <= RECEIVABLE_DAYS &&
        namesPerson(words(m), r.names);
    });
    if (!fits.length || new Set(fits.map((r) => r.personId)).size !== 1) continue;
    fits.sort((a, b) => entryDay(a.day) - entryDay(b.day) || (a.id < b.id ? -1 : a.id > b.id ? 1 : 0));
    paidBack.add(fits[0].id);
    set(m, { resolution: "receivable", automatic: !!m.nexoAccountId, receivableId: fits[0].id });
  }

  // 7. Rules the person marked "lançar sozinho". Never over a likely
  // duplicate: a close entry with the same amount makes it a question.
  for (const m of open()) {
    if (iofs.has(m.id)) continue;
    const text = normalizeMerchant(m.description) || m.description.toLowerCase();
    const rule = (options.rules ?? []).find((r) => r.auto && r.pattern.trim().length >= 3 &&
      (m.description.toLowerCase().includes(r.pattern.trim().toLowerCase()) || text.includes(r.pattern.trim().toLowerCase())) &&
      (r.type === "expense" ? isOut(m) : r.type === "income" ? !isOut(m) : true) &&
      (r.type !== "transfer" || !!r.targetAccountId));
    if (!rule) continue;
    const twin = options_.some((o) => o.m.id === m.id && o.exact && o.days <= 3 && !used.has(o.e.id));
    if (twin) continue;
    if (rule.type === "internal") {
      set(m, { resolution: "internal", automatic: true, ruleId: rule.id });
    } else if (rule.type === "transfer") {
      // Naming the person, the other side may still arrive from another of
      // their banks: the rule waits for it.
      const wait = mentionsOwner(m) && waiting(m);
      set(m, { resolution: "rule", automatic: !!m.nexoAccountId && !wait, waiting: wait, ruleId: rule.id,
        fromAccountId: isOut(m) ? m.nexoAccountId ?? undefined : rule.targetAccountId!,
        toAccountId: isOut(m) ? rule.targetAccountId! : m.nexoAccountId ?? undefined });
    } else if (!mentionsOwner(m)) {
      set(m, { resolution: "rule", automatic: !!m.nexoAccountId, ruleId: rule.id, categoryId: rule.categoryId });
    }
  }

  // Only one side seen, naming the person: money leaving to (or coming
  // from) a place that is not connected, such as a broker. Never spending;
  // the person says where it went (or a transfer rule does).
  for (const m of open()) {
    if (iofs.has(m.id)) continue;
    if (mentionsOwner(m)) set(m, { resolution: "ownName", automatic: false, waiting: waiting(m) });
  }

  // 8. Possibly already there (the person decides), or new.
  for (const o of options_) {
    if (out.has(o.m.id) || used.has(o.e.id) || dismissed.has(`${o.m.id}|${o.e.id}`)) continue;
    const similar = textSimilarity(o.m.description, o.e.description) >= 0.6;
    if (o.wrong ? !(o.exact && o.days <= 3) : !(o.score >= 45 && (o.days <= 3 || similar))) continue;
    used.add(o.e.id);
    set(o.m, { resolution: "maybe", automatic: false, transactionId: o.e.id, score: o.score, wrongAccount: o.wrong || undefined });
  }
  for (const m of open()) {
    if (iofs.has(m.id)) continue;
    set(m, { resolution: "newEntry", automatic: false, categoryId: learned(m) ?? undefined });
  }

  // The IOF follows its purchase: into the same entry when the purchase is
  // already there; with the purchase when it is new.
  for (const [purchaseId, iof] of iofOf) {
    if (out.has(iof.id)) continue;
    const p = out.get(purchaseId)!;
    if (p.resolution === "linked" || p.resolution === "maybe") {
      set(iof, { resolution: "iof", automatic: p.resolution === "linked", transactionId: p.transactionId, pairId: purchaseId });
    } else {
      set(iof, { resolution: "iof", automatic: false, pairId: purchaseId });
    }
  }
  return movements.map((m) => out.get(m.id)!);
}

/// Portuguese label of each outcome, for the assistant and the screens.
export const resolutionLabel: Record<Resolution, string> = {
  linked: "Já está lançado",
  maybe: "Talvez já esteja lançado",
  internal: "Entre contas suas na mesma conta do Nexo",
  ownTransfer: "Transferência entre suas contas",
  ownName: "Para o seu nome em outro lugar",
  invoicePayment: "Pagamento de fatura",
  reversal: "Pagamento e estorno",
  reserve: "Movimento de reserva",
  yield: "Rendimento",
  iof: "IOF da compra internacional",
  rule: "Regra de importação",
  recurring: "Recorrente prevista",
  receivable: "Parte de alguém paga de volta",
  newEntry: "Nova",
};
