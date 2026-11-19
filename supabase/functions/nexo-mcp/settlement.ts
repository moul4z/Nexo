// When money from a sale reaches the account, with the same rule as the app
// (lib/services/liquidity.dart): business days of the Brazilian market,
// equities in D+2, fixed income the same day before 13h, reserves at once.
const pad = (n: number) => String(n).padStart(2, "0");
const iso = (d: Date) => `${d.getUTCFullYear()}-${pad(d.getUTCMonth() + 1)}-${pad(d.getUTCDate())}`;
const at = (s: string) => new Date(`${s}T00:00:00Z`);
const plus = (s: string, n: number) => {
  const d = at(s);
  d.setUTCDate(d.getUTCDate() + n);
  return iso(d);
};

/// Easter Sunday (Meeus/Jones/Butcher).
function easter(year: number): string {
  const a = year % 19, b = Math.floor(year / 100), c = year % 100;
  const d = Math.floor(b / 4), e = b % 4, f = Math.floor((b + 8) / 25), g = Math.floor((b - f + 1) / 3);
  const h = (19 * a + b - d - g + 15) % 30;
  const i = Math.floor(c / 4), k = c % 4;
  const l = (32 + 2 * e + 2 * i - h - k) % 7;
  const m = Math.floor((a + 11 * h + 22 * l) / 451);
  const month = Math.floor((h + l - 7 * m + 114) / 31);
  const day = (h + l - 7 * m + 114) % 31 + 1;
  return `${year}-${pad(month)}-${pad(day)}`;
}

const holidayCache = new Map<number, Set<string>>();
function holidays(year: number): Set<string> {
  const known = holidayCache.get(year);
  if (known) return known;
  const e = easter(year);
  const out = new Set([
    ...[[1, 1], [4, 21], [5, 1], [9, 7], [10, 12], [11, 2], [11, 15], [11, 20], [12, 24], [12, 25], [12, 31]]
      .map(([m, d]) => `${year}-${pad(m)}-${pad(d)}`),
    plus(e, -48), plus(e, -47), plus(e, -2), plus(e, 60),
  ]);
  holidayCache.set(year, out);
  return out;
}

export function isBusinessDay(s: string): boolean {
  const wd = at(s).getUTCDay();
  return wd !== 0 && wd !== 6 && !holidays(Number(s.slice(0, 4))).has(s);
}

function nextBusinessDay(s: string): string {
  let x = s;
  while (!isBusinessDay(x)) x = plus(x, 1);
  return x;
}

function addBusinessDays(s: string, n: number): string {
  let x = s;
  for (let left = n; left > 0;) {
    x = plus(x, 1);
    if (isBusinessDay(x)) left--;
  }
  return x;
}

/// The day the money is in the account for an order placed on [day] in the
/// morning; null for a kind the app does not know (no guess).
export function availableOn(assetClass: string, day: string): string | null {
  switch (assetClass) {
    case "Ações":
    case "FIIs":
    case "ETFs":
      return addBusinessDays(isBusinessDay(day) ? day : nextBusinessDay(day), 2);
    case "Renda fixa":
      return isBusinessDay(day) ? day : addBusinessDays(day, 1);
    case "reserva":
      return day;
    default:
      return null;
  }
}
