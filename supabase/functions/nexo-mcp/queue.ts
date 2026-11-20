// Rules of the assistant's queue that the Edge Function applies before a
// request reaches the devices.

/// First build that records dollar fields (1.16.0+58). An older app would
/// apply the request as if it were in reais, so it must not take it.
export const DOLLAR_BUILD = 58;

/// First build with the shared reconciliation (1.18.0+60): rules that
/// register by themselves, transfer and internal rules. An older app would
/// save them as a plain category rule.
export const RECONCILE_BUILD = 60;

/// First build that pays a recurring from a bank movement, or ties it to an
/// entry already in the Nexo (1.19.0+61). An older app does not know these
/// requests and leaves them for another device.
export const RECURRING_BANK_BUILD = 61;

/// The minimum app build a request needs, or null when any version can.
export function minBuildFor(kind: string, args: Record<string, unknown>): number | null {
  if (kind === "suggestion.recurring" || kind === "recurring.link") return RECURRING_BANK_BUILD;
  // An older app would save the recurring without its IOF.
  if ((kind === "recurring.add" || kind === "recurring.edit") && "iof_percent" in args) return RECURRING_BANK_BUILD;
  // An older app would save the recurring without its split.
  if ((kind === "recurring.add" || kind === "recurring.edit") && "split_with" in args) return RECURRING_BANK_BUILD;
  // An older app would change the card and drop its revolving interest.
  if (kind === "account.edit" && "interest_monthly_percent" in args) return RECURRING_BANK_BUILD;
  // An older app would count the broker's cash as available to spend.
  if (kind === "account.add" && args.type === "broker") return RECURRING_BANK_BUILD;
  // An older database refuses the kind (schema 31 widened it).
  if (kind === "investment.event") return RECURRING_BANK_BUILD;
  // An older app would make it a budget of the whole category.
  if (kind === "budget.save" && typeof args.subcategory === "string" && args.subcategory) return RECURRING_BANK_BUILD;
  if (kind === "rule.save" && (args.auto === true || args.type === "transfer" || args.type === "internal")) {
    return RECONCILE_BUILD;
  }
  const currency = typeof args.currency === "string" ? args.currency : undefined;
  const foreign = (currency !== undefined && currency !== "BRL") ||
    args.brl_cents != null || args.fx_micros != null || args.received_cents != null ||
    (typeof args.tax_cents === "number" && args.tax_cents > 0);
  if (foreign && (kind.startsWith("investment.") || kind === "transfer.add")) return DOLLAR_BUILD;
  return null;
}

const day = (iso: string) => {
  const d = new Date(iso);
  return Number.isNaN(d.getTime()) ? null :
    `${String(d.getUTCDate()).padStart(2, "0")}/${String(d.getUTCMonth() + 1).padStart(2, "0")}/${d.getUTCFullYear()}`;
};

/// What a client (and the person reading it) learns from a refused token.
export function unauthorizedMessage(state: { state: string; revoked_at?: string; expires_at?: string } | null): string {
  const where = "Gere outro no app: Mais › Sincronizar dispositivos › Claude (IA) › Conectar ao Claude, " +
    "e troque o endereço do conector (o histórico de pedidos fica).";
  if (state?.state === "expired") {
    const when = state.expires_at ? day(state.expires_at) : null;
    return `Este endereço do Nexo venceu${when ? ` em ${when}` : ""}. Renove no app: Mais › Sincronizar dispositivos › ` +
      "Claude (IA) › Renovar. O mesmo endereço volta a funcionar por mais 90 dias; não precisa trocar no Claude.";
  }
  if (state?.state === "revoked") {
    const when = state.revoked_at ? day(state.revoked_at) : null;
    return `Este endereço do Nexo foi desconectado no app${when ? ` em ${when}` : ""}. ${where}`;
  }
  return `Endereço do Nexo inválido ou incompleto (confira se foi colado inteiro, até o fim). ${where}`;
}
