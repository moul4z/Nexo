// Quotes of US stocks and ETFs for the Nexo app, from Finnhub's /quote.
// Pure logic, testable without network: `node tool/test_market_quotes.mjs`.

export type Quote = { symbol: string; price: number; currency: "USD"; time: string };

export type Fetcher = (url: string) => Promise<{ status: number; json(): Promise<unknown> }>;

const TICKER = /^[A-Z0-9][A-Z0-9.\-]{0,11}$/;
export const MAX_SYMBOLS = 20;

/// Accepts only a short list of plain tickers, de-duplicated.
export function symbols(body: unknown): string[] {
  const list = body && typeof body === "object" ? (body as { symbols?: unknown }).symbols : undefined;
  if (!Array.isArray(list) || list.length === 0 || list.length > MAX_SYMBOLS) throw new Error("bad_symbols");
  const out = new Set<string>();
  for (const s of list) {
    if (typeof s !== "string" || !TICKER.test(s)) throw new Error("bad_symbols");
    out.add(s);
  }
  return [...out];
}

/// A successful Finnhub answer: `c` is the current price and `t` the time of
/// the last trade in seconds. An unknown ticker comes back with c = 0.
export function parse(symbol: string, data: unknown, nowMs: number): Quote | null {
  if (!data || typeof data !== "object") return null;
  const { c, t } = data as { c?: unknown; t?: unknown };
  if (typeof c !== "number" || !Number.isFinite(c) || c <= 0 || c > 1_000_000) return null;
  if (typeof t !== "number" || !Number.isFinite(t) || t <= 0) return null;
  const ms = t * 1000;
  if (ms > nowMs + 5 * 60_000) return null;
  return { symbol, price: c, currency: "USD", time: new Date(ms).toISOString() };
}

/// Recent answers are reused for a minute: a second device or a second tap
/// costs nothing against the provider's limit.
const cache = new Map<string, { at: number; quote: Quote | null }>();
export const CACHE_MS = 60_000;

export class RateLimited extends Error {
  constructor() {
    super("rate_limited");
  }
}

/// What a round could not finish: the provider's limit came in the middle.
export type Round = { limited?: boolean };

/// The provider's limit in the middle of the list does not throw away what
/// already came: those quotes are returned (and [round] says the list is
/// incomplete), the provider is not asked again in this round, and what is
/// still in the cache is used. Only a round with nothing at all is refused.
export async function quotes(list: string[], key: string, fetcher: Fetcher, nowMs: number,
  round: Round = {}): Promise<Quote[]> {
  const out: Quote[] = [];
  for (const symbol of list) {
    const hit = cache.get(symbol);
    if (hit && nowMs - hit.at < CACHE_MS) {
      if (hit.quote) out.push(hit.quote);
      continue;
    }
    if (round.limited) continue;
    const url = `https://finnhub.io/api/v1/quote?symbol=${encodeURIComponent(symbol)}&token=${encodeURIComponent(key)}`;
    const response = await fetcher(url);
    if (response.status === 429) {
      round.limited = true;
      continue;
    }
    if (response.status !== 200) continue;
    const quote = parse(symbol, await response.json(), nowMs);
    cache.set(symbol, { at: nowMs, quote });
    if (quote) out.push(quote);
  }
  if (round.limited && out.length === 0) throw new RateLimited();
  return out;
}

export function clearCache() {
  cache.clear();
}
