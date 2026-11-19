// Tests for the Pluggy client and normalizer: `node tool/test_pluggy.mjs`.
// Synthetic objects shaped by api.pluggy.ai/oas3.json; no network, no keys.
import assert from 'node:assert/strict';
import { isSkip, latestMovementAt, itemHealth, merge, toAccountSnapshot, toBillSnapshot, toSuggestion } from '../supabase/functions/pluggy-sync/normalize.ts';
import { PluggyClient, PluggyError } from '../supabase/functions/pluggy-sync/pluggy.ts';

let passed = 0;
async function test(name, action) {
  await action();
  passed++;
  console.log(`PASS ${name}`);
}

const bank = { id: 'acc-bank', type: 'BANK', subtype: 'CHECKING_ACCOUNT', name: 'Conta fictícia', currencyCode: 'BRL', itemId: 'item-1' };
const card = { id: 'acc-card', type: 'CREDIT', subtype: 'CREDIT_CARD', name: 'Cartão fictício', currencyCode: 'BRL', itemId: 'item-1' };
const tx = (over = {}) => ({
  id: 'tx-1', description: 'Mercado Fictício', currencyCode: 'BRL', amount: -32.9,
  date: '2026-10-19T15:30:00.000Z', type: 'DEBIT', status: 'POSTED', category: 'Groceries',
  accountId: 'acc-bank', updatedAt: '2026-10-19T16:00:00.000Z', ...over,
});

await test('debit becomes an expense suggestion keyed by the Pluggy id', () => {
  const s = toSuggestion(tx(), bank);
  assert.equal(isSkip(s), false);
  assert.equal(s.external_id, 'pluggy:tx-1');
  assert.equal(s.amount_cents, 3290);
  assert.equal(s.kind, 'expense');
  assert.equal(s.medium, 'bank');
  assert.equal(s.settled, true);
});

await test('direction comes from type, never from the amount sign', () => {
  assert.equal(toSuggestion(tx({ amount: 32.9 }), bank).kind, 'expense');
  assert.equal(toSuggestion(tx({ type: 'CREDIT', amount: -5000, description: 'Salário' }), bank).kind, 'income');
});

await test('card purchase, refund, bill payment and installments', () => {
  const purchase = toSuggestion(tx({ accountId: 'acc-card', creditCardMetadata: { installmentNumber: 2, totalInstallments: 6 } }), card);
  assert.equal(purchase.kind, 'expense');
  assert.equal(purchase.medium, 'credit');
  assert.equal(purchase.installment, '2/6');
  assert.equal(toSuggestion(tx({ accountId: 'acc-card', type: 'CREDIT', description: 'Estorno loja' }), card).kind, 'refund');
  assert.equal(toSuggestion(tx({ accountId: 'acc-card', type: 'CREDIT', description: 'Pagamento de fatura' }), card).kind, 'transfer');
});

await test('only clear own-account moves become transfers', () => {
  assert.equal(toSuggestion(tx({ description: 'Transferência entre contas' }), bank).kind, 'transfer');
  assert.equal(toSuggestion(tx({ description: 'Aplicação CDB' }), bank).kind, 'transfer');
  assert.equal(toSuggestion(tx({ description: 'Resgate poupança', type: 'CREDIT' }), bank).kind, 'transfer');
  // A Pix to a store or a salary by TED must not disappear from reports.
  assert.equal(toSuggestion(tx({ description: 'Pix enviado Padaria', operationType: 'PIX' }), bank).kind, 'expense');
  assert.equal(toSuggestion(tx({ description: 'TED recebida Empresa', type: 'CREDIT', operationType: 'TED' }), bank).kind, 'income');
});

await test('pending stays marked unsettled', () => {
  assert.equal(toSuggestion(tx({ status: 'PENDING' }), bank).settled, false);
});

await test('foreign currency uses account amount or is skipped', () => {
  const converted = toSuggestion(tx({ currencyCode: 'USD', amount: -10, amountInAccountCurrency: -54.37 }), bank);
  assert.equal(converted.amount_cents, 5437);
  assert.equal(toSuggestion(tx({ currencyCode: 'USD', amount: -10 }), bank).reason, 'unsupported_currency');
  assert.equal(toSuggestion(tx(), { ...bank, currencyCode: 'USD' }).reason, 'unsupported_currency');
});

await test('invalid, zero or mismatched rows are skipped, not guessed', () => {
  assert.equal(toSuggestion(tx({ amount: 0 }), bank).reason, 'zero');
  assert.equal(toSuggestion(tx({ date: 'ontem' }), bank).reason, 'invalid');
  assert.equal(toSuggestion(tx({ type: 'OTHER' }), bank).reason, 'invalid');
  assert.equal(toSuggestion(tx({ accountId: 'acc-card' }), bank).reason, 'invalid');
  assert.equal(toSuggestion(tx({ amount: NaN }), bank).reason, 'invalid');
});

await test('refreshes update pending suggestions; decisions are never rewritten', () => {
  const first = toSuggestion(tx(), bank);
  assert.equal(merge(undefined, first).action, 'insert');
  const corrected = toSuggestion(tx({ amount: -35, updatedAt: '2026-10-20T10:00:00.000Z' }), bank);
  assert.equal(merge({ ...first, review: 'pending' }, corrected).action, 'update');
  assert.equal(merge({ ...first, review: 'confirmed' }, corrected).action, 'flag_changed');
  const cosmetic = toSuggestion(tx({ description: 'MERCADO FICTICIO LTDA', updatedAt: '2026-10-20T10:00:00.000Z' }), bank);
  assert.equal(merge({ ...first, review: 'ignored' }, cosmetic).action, 'keep');
  assert.equal(merge({ ...corrected, review: 'pending' }, first).action, 'keep', 'older data never wins');
});

await test('item health: expired consent, errors and early warning', () => {
  const now = new Date('2026-10-20T12:00:00Z');
  assert.equal(itemHealth({ status: 'LOGIN_ERROR', error: { code: 'USER_AUTHORIZATION_EXPIRED' } }, now).state, 'reconnect');
  assert.equal(itemHealth({ status: 'UPDATED', consentExpiresAt: '2026-10-30T00:00:00Z' }, now).state, 'expiring');
  assert.equal(itemHealth({ status: 'UPDATED', consentExpiresAt: '2027-10-01T00:00:00Z' }, now).state, 'ok');
  assert.equal(itemHealth({ status: 'OUTDATED' }, now).state, 'error');
});

// ── Client ───────────────────────────────────────────────────────────────
function fakeApi(handler) {
  const calls = [];
  const fetcher = async (url, init = {}) => {
    calls.push({ url, init });
    return handler(url, init, calls);
  };
  return { calls, fetcher };
}
const json = (body, status = 200) => new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json' } });

await test('authenticates once and sends the key only to Pluggy', async () => {
  const api = fakeApi((url) => url.endsWith('/auth') ? json({ apiKey: 'k1' }) : json({ results: [bank] }));
  const client = new PluggyClient('id', 'secret', api.fetcher, 'https://api.example');
  await client.accounts('item-1');
  await client.accounts('item-1');
  assert.equal(api.calls.filter(c => c.url.endsWith('/auth')).length, 1);
  assert.equal(api.calls[1].init.headers['X-API-KEY'], 'k1');
  assert.equal(api.calls[1].url, 'https://api.example/accounts?itemId=item-1');
  assert(api.calls.every(c => c.init.redirect === 'error'));
});

await test('expired key re-authenticates once, then fails clearly', async () => {
  let keys = 0;
  const api = fakeApi((url, init) => {
    if (url.endsWith('/auth')) return json({ apiKey: `k${++keys}` });
    return init.headers['X-API-KEY'] === 'k1' ? new Response('', { status: 401 }) : json({ results: [] });
  });
  const client = new PluggyClient('id', 'secret', api.fetcher, 'https://api.example');
  assert.deepEqual(await client.accounts('item-1'), []);
  assert.equal(keys, 2);
  const denied = new PluggyClient('id', 'bad', fakeApi(() => new Response('', { status: 401 })).fetcher, 'https://api.example');
  await assert.rejects(denied.accounts('item-1'), e => e instanceof PluggyError && e.status === 401 && !e.retryable);
});

await test('transactions follow the v2 cursor until next is null', async () => {
  const pages = {
    '?accountId=acc-bank&dateFrom=2026-09-20': { results: [tx({ id: 'a' })], next: '?accountId=acc-bank&after=c1' },
    '?accountId=acc-bank&after=c1': { results: [tx({ id: 'b' })], next: null },
  };
  const api = fakeApi((url) => url.endsWith('/auth') ? json({ apiKey: 'k' })
    : json(pages[url.slice(url.indexOf('?'))]));
  const client = new PluggyClient('id', 'secret', api.fetcher, 'https://api.example');
  const all = await client.transactions('acc-bank', '2026-09-20');
  assert.deepEqual(all.map(t => t.id), ['a', 'b']);
  assert(api.calls.slice(1).every(c => c.url.startsWith('https://api.example/v2/transactions?')));
});

await test('rate limit is retryable; malformed cursor is refused', async () => {
  const limited = new PluggyClient('id', 's', fakeApi((url) => url.endsWith('/auth') ? json({ apiKey: 'k' }) : new Response('', { status: 429 })).fetcher, 'https://api.example');
  await assert.rejects(limited.transactions('acc-bank', '2026-10-01'), e => e.retryable === true);
  const evil = new PluggyClient('id', 's', fakeApi((url) => url.endsWith('/auth') ? json({ apiKey: 'k' })
    : json({ results: [], next: 'https://attacker.example/steal' })).fetcher, 'https://api.example');
  await assert.rejects(evil.transactions('acc-bank', '2026-10-01'), e => e instanceof PluggyError);
});

await test('bills reads GET /bills of the card, one page', async () => {
  const api = fakeApi((url) => url.endsWith('/auth') ? json({ apiKey: 'k' })
    : json({ total: 2, results: [{ id: 'b1', totalAmount: 420.92 }, { id: 'b2', totalAmount: 213.59 }] }));
  const client = new PluggyClient('id', 'secret', api.fetcher, 'https://api.example');
  assert.deepEqual((await client.bills('acc card')).map(b => b.id), ['b1', 'b2']);
  assert.equal(api.calls[1].url, 'https://api.example/bills?accountId=acc%20card&pageSize=24');
});

// ── syncOwner: one refresh with fake Pluggy and fake store ─────────────
const { syncOwner } = await import('../supabase/functions/pluggy-sync/sync.ts');
function fakeStore(items) {
  const rows = new Map();
  const healths = [];
  return {
    rows, healths,
    items: async () => items,
    stored: async (_o, ids) => ids.filter(id => rows.has(id)).map(id => rows.get(id)),
    store: async (_o, itemId, health, incoming) => {
      healths.push([itemId, health.state]);
      let n = 0;
      for (const r of incoming) {
        const old = rows.get(r.external_id);
        if (r.action === 'insert' && !old) { rows.set(r.external_id, { ...r, review: 'pending' }); n++; }
        if (r.action === 'update' && old?.review === 'pending') { rows.set(r.external_id, { ...r, review: 'pending' }); n++; }
        if (r.action === 'flag_changed' && old && old.review !== 'pending') { old.changed = true; old.source_updated_at = r.source_updated_at; n++; }
        // Like the SQL: only the newer fields, a null never erases.
        if (r.action === 'annotate' && old) {
          for (const f of ['direction', 'operation_ref', 'payment_ref', 'same_owner', 'counterparty']) {
            if (r[f] !== null && r[f] !== undefined) old[f] = r[f];
          }
          n++;
        }
      }
      return n;
    },
  };
}
const source = (txs, item = { status: 'UPDATED' }) => ({
  item: async () => item,
  accounts: async () => [bank],
  transactions: async () => txs,
});
const now = new Date('2026-10-20T12:00:00.000Z');

await test('what the reconciliation needs: direction, operation ids, same owner and who was on the other side', () => {
  const cpf = { type: 'CPF', value: '123.456.789-09' };
  const out = toSuggestion(tx({ description: 'Pix enviado', providerId: 'E2E.000/1:a-b', paymentData: {
    payer: { name: 'ANA TESTE', documentNumber: cpf },
    receiver: { name: '  Ana   Teste ', documentNumber: { type: 'CPF', value: '12345678909' } },
    referenceNumber: 'REF-9' } }), bank);
  assert.deepEqual([out.direction, out.same_owner, out.counterparty, out.payment_ref],
    ['out', true, 'Ana Teste', 'REF-9']);
  assert.equal(out.description, 'Pix enviado - Ana Teste', 'a bare "Pix enviado" says who received');
  assert.equal(out.operation_ref, 'E2E.000/1:a-b');
  // An id with anything else in it is dropped, never stored half-clean.
  assert.equal(toSuggestion(tx({ providerId: 'tem espaço; drop' }), bank).operation_ref, null);
  // The tax number itself is never kept: only the comparison.
  assert.ok(!JSON.stringify(out).includes('12345678909'));
  const other = toSuggestion(tx({ type: 'CREDIT', description: 'Pix recebido', paymentData: {
    payer: { name: 'Loja Exemplo LTDA', documentNumber: { type: 'CNPJ', value: '11.222.333/0001-81' } },
    receiver: { name: 'Ana Teste', documentNumber: cpf } } }), bank);
  assert.deepEqual([other.direction, other.same_owner, other.counterparty], ['in', false, 'Loja Exemplo LTDA']);
  // Without both documents nobody guesses the owner.
  const unknown = toSuggestion(tx({ description: 'Mercado Fictício', paymentData: { receiver: { name: 'Mercado' } } }), bank);
  assert.equal(unknown.same_owner, null);
  assert.equal(unknown.description, 'Mercado Fictício', 'a real description is kept as the bank wrote it');
  const plain = toSuggestion(tx(), bank);
  assert.deepEqual([plain.direction, plain.operation_ref, plain.payment_ref, plain.same_owner, plain.counterparty],
    ['out', null, null, null, null]);
  // A yield arrives as money in, even when the kind is "transfer".
  assert.equal(toSuggestion(tx({ type: 'CREDIT', description: 'Rendimentos' }), bank).direction, 'in');
});

await test('rows stored before 1.18 get the new fields without touching amounts or decisions', async () => {
  const old = { ...toSuggestion(tx(), bank), direction: null, counterparty: null, review: 'confirmed' };
  const fresh = toSuggestion(tx({ paymentData: { receiver: { name: 'Mercado Exemplo' } }, merchant: { name: 'Mercado Exemplo' } }), bank);
  assert.equal(merge(old, fresh).action, 'annotate');
  assert.equal(merge({ ...fresh, review: 'confirmed' }, fresh).action, 'keep', 'nothing new: nothing written');
  // A material change of a decided row still only flags it.
  const changed = toSuggestion(tx({ amount: -40, updatedAt: '2026-10-21T10:00:00.000Z' }), bank);
  assert.equal(merge(old, changed).action, 'flag_changed');
  const store = fakeStore([{ item_id: 'item-1', label: 'Banco', last_fetch_at: null }]);
  store.rows.set('pluggy:tx-1', { ...old });
  await syncOwner('owner', source([tx({ merchant: { name: 'Mercado Exemplo' } })]), store, { now });
  const row = store.rows.get('pluggy:tx-1');
  assert.deepEqual([row.review, row.amount_cents, row.direction, row.counterparty], ['confirmed', 3290, 'out', 'Mercado Exemplo']);
});

await test('sync: new transactions become pending suggestions, skips counted', async () => {
  const store = fakeStore([{ item_id: 'item-1', label: 'Banco', last_fetch_at: null }]);
  const [r] = await syncOwner('owner', source([tx({ id: 'a' }), tx({ id: 'b', amount: 0 })]), store, { now });
  assert.equal(r.fetched, true);
  assert.equal(r.written, 1);
  assert.equal(r.skipped, 1);
  assert.equal(store.rows.get('pluggy:a').review, 'pending');
  assert.deepEqual(store.healths, [['item-1', 'ok']]);
});

await test('sync: refresh updates pending and flags a decided change', async () => {
  const store = fakeStore([{ item_id: 'item-1', label: 'Banco', last_fetch_at: null }]);
  await syncOwner('owner', source([tx({ id: 'a' }), tx({ id: 'b' })]), store, { now });
  store.rows.get('pluggy:a').review = 'confirmed';
  const later = { updatedAt: '2026-10-20T10:00:00.000Z', amount: -40 };
  await syncOwner('owner', source([tx({ id: 'a', ...later }), tx({ id: 'b', ...later })]), store,
    { now: new Date(now.getTime() + 2 * 3600000) });
  assert.equal(store.rows.get('pluggy:a').amount_cents, 3290, 'decision kept');
  assert.equal(store.rows.get('pluggy:a').changed, true);
  assert.equal(store.rows.get('pluggy:b').amount_cents, 4000);
});

await test('sync: reads at most hourly unless forced, and forced waits 5 minutes', async () => {
  const recent = new Date(now.getTime() - 10 * 60000).toISOString();
  const store = fakeStore([{ item_id: 'item-1', label: 'Banco', last_fetch_at: recent }]);
  let reads = 0;
  const counting = { ...source([tx()]), item: async () => { reads++; return { status: 'UPDATED' }; } };
  assert.equal((await syncOwner('owner', counting, store, { now }))[0].fetched, false);
  assert.equal((await syncOwner('owner', counting, store, { now, force: true }))[0].fetched, true);
  assert.equal(reads, 1);
  const veryRecent = fakeStore([{ item_id: 'item-1', label: 'Banco', last_fetch_at: new Date(now.getTime() - 60000).toISOString() }]);
  assert.equal((await syncOwner('owner', counting, veryRecent, { now, force: true }))[0].fetched, false);
});

await test('sync: a Pluggy failure marks the item and keeps stored data', async () => {
  const store = fakeStore([{ item_id: 'item-1', label: 'Banco', last_fetch_at: null }]);
  const failing = { ...source([]), accounts: async () => { throw new PluggyError(404, false); } };
  const [r] = await syncOwner('owner', failing, store, { now });
  assert.equal(r.fetched, false);
  assert.equal(r.health.state, 'reconnect');
  assert.deepEqual(store.healths, [['item-1', 'reconnect']]);
  const expired = source([], { status: 'LOGIN_ERROR', error: { code: 'USER_AUTHORIZATION_EXPIRED' } });
  assert.equal((await syncOwner('owner', expired, fakeStore([{ item_id: 'i', label: 'B', last_fetch_at: null }]), { now }))[0].health.state, 'reconnect');
});

await test('account snapshot: balance and card limits, never number, owner or CPF', () => {
  const snap = toAccountSnapshot({ ...card, number: '1234', owner: 'Pessoa Fictícia', taxNumber: '000.000.000-00',
    balance: 213.59, marketingName: 'Cartão Roxo', creditData: { creditLimit: 650, availableCreditLimit: 15.49,
      minimumPayment: 57.29, balanceCloseDate: '2026-11-19', balanceDueDate: '2026-11-26T00:00:00Z' } });
  assert.deepEqual(snap, { account_id: 'acc-card', type: 'CREDIT', subtype: 'CREDIT_CARD', name: 'Cartão Roxo',
    currency: 'BRL', balance_cents: 21359, credit_limit_cents: 65000, available_cents: 1549,
    minimum_payment_cents: 5729, close_date: '2026-11-19', due_date: '2026-11-26' });
  assert.equal(JSON.stringify(snap).includes('Fictícia'), false);
  const b = toAccountSnapshot({ ...bank, balance: -33 });
  assert.equal(b.balance_cents, -3300);
  assert.equal(b.credit_limit_cents, null);
  assert.equal(toAccountSnapshot({ ...bank, balance: Infinity }).balance_cents, null);
  // The proxy item date is useless; the newest movement record tells.
  assert.equal(latestMovementAt([tx({ updatedAt: '2026-10-21T09:00:00.000Z' }),
    tx({ createdAt: '2026-10-22T06:00:00.000Z', updatedAt: '2026-10-21T10:00:00.000Z' })]), '2026-10-22T06:00:00.000Z');
  assert.equal(latestMovementAt([]), null);
  assert.equal(latestMovementAt([tx({ updatedAt: 'ontem' })]), null);
});

await test('sync: stores balances and the bank time with each read', async () => {
  const store = fakeStore([{ item_id: 'item-1', label: 'Banco', last_fetch_at: null }]);
  const saved = [];
  store.accounts = async (_o, itemId, updatedAt, rows) => saved.push([itemId, updatedAt, rows.map(r => r.account_id)]);
  // lastUpdatedAt of a Meu Pluggy proxy stays at its creation: ignored.
  await syncOwner('owner', source([tx({ id: 'n', updatedAt: '2026-10-20T06:00:00.000Z' })],
    { status: 'UPDATED', lastUpdatedAt: '2026-10-01T00:00:00.000Z' }), store, { now });
  assert.deepEqual(saved, [['item-1', '2026-10-20T06:00:00.000Z', ['acc-bank']]]);
});

await test('bill snapshot: totals, dates and sums only', () => {
  const b = toBillSnapshot({ id: 'bill-1', dueDate: '2026-10-26T00:00:00.000Z', billClosingDate: '2026-10-19T00:00:00Z',
    totalAmount: 420.92, totalAmountCurrencyCode: 'BRL', minimumPaymentAmount: 63.14,
    financeCharges: [{ id: 'c', type: 'IOF', amount: 1.5 }, { id: 'd', type: 'OTHER', amount: 2, additionalInfo: 'Tarifa' }],
    payments: [{ id: 'p', valueType: 'FULL_PAYMENT', paymentMode: 'PIX', amount: 100 }] });
  assert.deepEqual(b, { bill_id: 'bill-1', due_date: '2026-10-26', close_date: '2026-10-19', total_cents: 42092,
    minimum_cents: 6314, charges_cents: 350, paid_cents: 10000, currency: 'BRL' });
  assert.equal(JSON.stringify(b).includes('PIX'), false);
  assert.equal(toBillSnapshot({ id: 'x', dueDate: 'logo', totalAmount: 1 }), null);
  assert.equal(toBillSnapshot({ id: 'x/../y', dueDate: '2026-10-26', totalAmount: 1 }), null);
});

await test('sync: stores official invoices of cards after the accounts; a refusal does not stop the read', async () => {
  const store = fakeStore([{ item_id: 'item-1', label: 'Banco', last_fetch_at: null }]);
  const asked = [], order = [];
  store.accounts = async (_o, _i, _u, rows) => order.push(['accounts', rows.length]);
  store.bills = async (_o, accountId, rows) => order.push(['bills', accountId, rows.map(r => r.bill_id)]);
  const withBills = { ...source([tx({ id: 'c' })]), accounts: async () => [bank, card, { ...card, id: 'acc-card2' }],
    bills: async (id) => {
      asked.push(id);
      if (id === 'acc-card2') throw new PluggyError(403, false);
      return [{ id: 'old', dueDate: '2026-09-26', totalAmount: 390.1 }, { id: 'new', dueDate: '2026-10-26', totalAmount: 420.92 },
        { id: 'bad', dueDate: 'x', totalAmount: 1 }];
    } };
  const [r] = await syncOwner('owner', withBills, store, { now });
  assert.deepEqual(asked, ['acc-card', 'acc-card2']);
  assert.deepEqual(r.bills, [2, 'pluggy_403']);
  assert.deepEqual(order, [['accounts', 3], ['bills', 'acc-card', ['new', 'old']]]);
  assert.equal(r.fetched, true);
  const [plain] = await syncOwner('owner', source([]), fakeStore([{ item_id: 'i', label: 'B', last_fetch_at: null }]), { now });
  assert.equal(plain.bills, undefined);
});

// ── Audit of 18/11/2026 ────────────────────────────────────────────────
await test('audit PLG-02: "Pagamento recebido" on a card is the bill being paid, never a refund', async () => {
  const cardIn = (description, over = {}) => toSuggestion(tx({ accountId: 'acc-card', type: 'CREDIT', amount: 350, description, ...over }), card);
  assert.deepEqual([cardIn('Pagamento recebido').kind, cardIn('Pagamento recebido').direction], ['transfer', 'in']);
  assert.equal(cardIn('PAGTO EFETUADO').kind, 'transfer');
  // Money given back stays a refund, whatever else the text says.
  for (const text of ['Estorno de pagamento', 'Pagamento devolvido', 'Reembolso Loja Exemplo', 'Crédito Loja Exemplo']) {
    assert.equal(cardIn(text).kind, 'refund', text);
  }
  // The bank's side keeps its kind: "fatura" also names the light bill, and
  // the reconciliation knows a card bill by its text, whatever the kind.
  assert.equal(toSuggestion(tx({ description: 'Pagamento de fatura' }), bank).kind, 'expense');
  assert.equal(toSuggestion(tx({ description: 'Pagamento fatura de luz' }), bank).kind, 'expense');

  // With the rule of the app: a purchase and, two days later, the bill paid
  // with the same amount from a bank that is not connected.
  const { reconcile } = await import('../supabase/functions/nexo-mcp/reconcile.ts');
  const movement = (s) => ({ id: s.external_id, amountCents: s.amount_cents, kind: s.kind, medium: s.medium,
    description: s.description, occurredAt: s.occurred_at, direction: s.direction, accountId: s.account_external_id,
    nexoAccountId: null, operationRef: s.operation_ref, paymentRef: s.payment_ref, sameOwner: s.same_owner,
    counterparty: s.counterparty });
  const purchase = toSuggestion(tx({ id: 'compra', accountId: 'acc-card', amount: 350, description: 'Loja Exemplo',
    date: '2026-11-14T15:00:00.000Z' }), card);
  const paid = cardIn('Pagamento recebido', { id: 'pago', date: '2026-11-16T15:00:00.000Z' });
  const options = { creditAccounts: new Set(['cartao']), now: Date.parse('2026-11-18T12:00:00Z') };
  const byId = (list) => Object.fromEntries(list.map((m) => [m.id, [m.resolution, m.automatic]]));
  assert.deepEqual(byId(reconcile([purchase, paid].map(movement), [], options)),
    { 'pluggy:compra': ['newEntry', false], 'pluggy:pago': ['invoicePayment', false] });
  // What the old kind did: both left the queue by themselves, and the
  // purchase never became spending.
  assert.deepEqual(byId(reconcile([purchase, { ...paid, kind: 'refund' }].map(movement), [], options)),
    { 'pluggy:compra': ['reversal', true], 'pluggy:pago': ['reversal', true] });
});

await test('audit PLG-03: a request to Pluggy has a time limit, and no answer is a failure of that read', async () => {
  const { requestTimeoutMs } = await import('../supabase/functions/pluggy-sync/pluggy.ts');
  assert.ok(requestTimeoutMs > 0 && requestTimeoutMs <= 30000);
  const api = fakeApi((url) => url.endsWith('/auth') ? json({ apiKey: 'k' }) : json({ results: [bank] }));
  await new PluggyClient('id', 'secret', api.fetcher, 'https://api.example').accounts('item-1');
  assert.ok(api.calls.every((c) => c.init.signal instanceof AbortSignal), 'auth and reads carry a time limit');
  // A bank that never answers: the signal ends the wait. (The timer of the
  // signal does not keep Node alive by itself; the test's own timer does.)
  const stuck = (_url, init) => new Promise((_resolve, reject) => {
    const alive = setTimeout(() => reject(new Error('the time limit never came')), 5000);
    init.signal.addEventListener('abort', () => { clearTimeout(alive); reject(init.signal.reason); });
  });
  const slow = new PluggyClient('id', 'secret', stuck, 'https://api.example', 20);
  await assert.rejects(slow.accounts('item-1'), (e) => e instanceof PluggyError && e.status === 504 && e.retryable);
  // No connection, or an answer that is not JSON: also a failure of this read.
  const down = new PluggyClient('id', 'secret', async () => { throw new TypeError('fetch failed'); }, 'https://api.example');
  await assert.rejects(down.accounts('item-1'), (e) => e instanceof PluggyError && e.status === 503 && e.retryable);
  const html = new PluggyClient('id', 'secret', fakeApi((url) => url.endsWith('/auth') ? json({ apiKey: 'k' })
    : new Response('<html>', { status: 200 })).fetcher, 'https://api.example');
  await assert.rejects(html.accounts('item-1'), (e) => e instanceof PluggyError && e.status === 502);
});

await test('audit PLG-03: whatever fails in one bank, the others are still read', async () => {
  const items = [{ item_id: 'item-quebrado', label: 'Banco A', last_fetch_at: null },
    { item_id: 'item-1', label: 'Banco B', last_fetch_at: null }];
  const broken = (failure) => ({ ...source([tx({ id: 'ok' })]),
    accounts: async (itemId) => { if (itemId === 'item-quebrado') throw failure; return [bank]; } });
  for (const [failure, code] of [[new TypeError('fetch failed: https://api.example/accounts?itemId=segredo'), 'falha inesperada'],
    [new DOMException('The operation timed out.', 'TimeoutError'), 'tempo esgotado'], [new PluggyError(500, true), 'pluggy_500']]) {
    const store = fakeStore(items);
    const [a, b] = await syncOwner('owner', broken(failure), store, { now });
    assert.deepEqual([a.fetched, a.health.state], [false, 'error']);
    assert.ok(a.health.message.includes(code), a.health.message);
    assert.ok(!a.health.message.includes('segredo'), 'only a code, never the text of the error');
    assert.deepEqual([b.fetched, b.written], [true, 1], 'the next bank is read');
    assert.deepEqual(store.healths, [['item-quebrado', 'error'], ['item-1', 'ok']]);
  }
  // The invoices of a card are a check: an unexpected failure there does not stop the movements.
  const store = fakeStore([items[1]]);
  const withBills = { ...source([tx({ id: 'c' })]), accounts: async () => [bank, card],
    bills: async () => { throw new TypeError('fetch failed'); } };
  const [r] = await syncOwner('owner', withBills, store, { now });
  assert.deepEqual([r.fetched, r.bills], [true, ['falha inesperada']]);
  // Read but not kept (the database refused): the same, for that bank only.
  const picky = fakeStore(items);
  const keep = picky.store;
  picky.store = async (o, itemId, health, rows) => {
    if (itemId === 'item-quebrado') throw new Error('rpc_500');
    return keep(o, itemId, health, rows);
  };
  const [first, second] = await syncOwner('owner', source([tx({ id: 'd' })]), picky, { now });
  assert.deepEqual([first.fetched, first.health.state, second.fetched, second.written], [false, 'error', true, 1]);
  assert.match(first.health.message, /não puderam ser guardados agora \(rpc_500\)/, 'the code of the database call, for whoever looks into it');
});

await test('A4: a pending purchase the bank stopped returning is marked, never deleted; back again, unmarked', async () => {
  const store = fakeStore([{ item_id: 'item-1', label: 'Banco', last_fetch_at: null }]);
  const calls = [];
  // Like nexo_pluggy_vanish.
  store.vanish = async (_o, itemId, accountIds, seen, fromMs) => {
    calls.push({ itemId, accountIds, seen: [...seen].sort(), fromMs });
    let n = 0;
    for (const r of store.rows.values()) {
      if (seen.includes(r.external_id)) { r.vanished = false; continue; }
      if (!r.vanished && accountIds.includes(r.account_external_id) && r.settled === false &&
        r.review !== 'ignored' && r.occurred_at >= fromMs) { r.vanished = true; n++; }
    }
    return n;
  };
  const pending = (id, over = {}) => tx({ id, status: 'PENDING', ...over });
  await syncOwner('owner', source([pending('a'), pending('b'), tx({ id: 'c' }), pending('old', { date: '2026-09-15T15:00:00.000Z' })]), store, { now });
  assert.equal(calls.length, 1);
  assert.deepEqual(calls[0].accountIds, ['acc-bank']);
  assert.deepEqual(calls[0].seen, ['pluggy:a', 'pluggy:b', 'pluggy:c', 'pluggy:old']);
  // 35 days back from 20/10 is 15/09; two days of margin, in Brasília.
  assert.equal(calls[0].fromMs, Date.parse('2026-09-17T03:00:00.000Z'));
  // The next read: 'a' is gone (cancelled), 'c' was settled, 'old' is before the period.
  store.rows.get('pluggy:b').review = 'confirmed';
  const later = { now: new Date(now.getTime() + 2 * 3600000) };
  const [r] = await syncOwner('owner', source([pending('b'), tx({ id: 'd', amount: 0 })]), store, later);
  assert.equal(r.vanished, 1);
  assert.deepEqual(['a', 'b', 'c', 'old'].map((id) => store.rows.get(`pluggy:${id}`).vanished ?? false), [true, false, false, false]);
  assert.ok(calls[1].seen.includes('pluggy:d'), 'a skipped movement was returned by the bank too');
  assert.equal(store.rows.size, 4, 'nothing deleted');
  // Back in the bank's answer (it can take a few days): unmarked.
  const [again] = await syncOwner('owner', source([pending('a'), pending('b')]), store, { now: new Date(now.getTime() + 4 * 3600000) });
  assert.equal(store.rows.get('pluggy:a').vanished, false);
  assert.equal(again.vanished, undefined);
  // A read that failed marks nothing: the call is never made.
  const broken = { ...source([]), accounts: async () => { throw new PluggyError(500, true); } };
  await syncOwner('owner', broken, store, { now: new Date(now.getTime() + 6 * 3600000) });
  assert.equal(calls.length, 3);
  // A server without the function keeps working.
  store.vanish = async () => { throw new Error('rpc_404'); };
  const [old] = await syncOwner('owner', source([pending('b')]), store, { now: new Date(now.getTime() + 8 * 3600000) });
  assert.deepEqual([old.fetched, old.vanished], [true, undefined]);
});

console.log(`PLUGGY: ${passed} tests passed; synthetic data only.`);
