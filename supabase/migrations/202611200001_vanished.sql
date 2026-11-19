-- Nexo 1.19: a pending purchase the bank stopped returning.
--
-- Pluggy says a bank may stop returning a pending transaction (cancelled,
-- or for a few days) and later return it under a new id. A row that was
-- pending at the bank, inside the period read, and is missing from a full
-- read of its account gets vanished_at. Nothing is deleted: the row comes
-- back to normal as soon as the bank returns it again, and the app decides
-- what to show (a pending one leaves the review list; one already entered
-- is only pointed out, never removed from the ledger).
--
-- Only adds a column and a function, and replaces three functions with
-- versions that return one more field (the two connector ones keep the
-- real-dataset rule of 202611180002). No amount or decision is rewritten.
begin;

alter table nexo_pluggy_private.suggestions
  add column if not exists vanished_at timestamptz;

-- Called by pluggy-sync after a complete read of an item: the accounts read
-- in full, every id the bank returned (skipped ones too) and the start of
-- the period that counts. Returns how many rows were marked now.
create or replace function public.nexo_pluggy_vanish(
  p_owner uuid, p_item_id text, p_account_ids text[], p_seen text[], p_from_ms bigint
) returns integer language plpgsql security definer set search_path = '' as $$
declare
  v_count integer;
begin
  if p_from_ms is null or p_from_ms < 0 then
    raise exception using errcode = '22023', message = 'invalid_window';
  end if;
  if not exists(select 1 from nexo_pluggy_private.items
      where owner_id = p_owner and item_id = p_item_id) then
    raise exception using errcode = '42501', message = 'item_unavailable';
  end if;
  -- Back in the bank's answer: not gone any more.
  update nexo_pluggy_private.suggestions set vanished_at = null, updated_at = now()
    where owner_id = p_owner and item_id = p_item_id and vanished_at is not null
      and external_id = any(coalesce(p_seen, '{}'::text[]));
  update nexo_pluggy_private.suggestions set vanished_at = now(), updated_at = now()
    where owner_id = p_owner and item_id = p_item_id and vanished_at is null
      and account_external_id = any(coalesce(p_account_ids, '{}'::text[]))
      and not (external_id = any(coalesce(p_seen, '{}'::text[])))
      and settled = false and review in ('pending', 'confirmed')
      and occurred_at >= p_from_ms;
  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

-- The app's inbox, plus "vanished".
create or replace function public.nexo_pluggy_suggestions(p_since_ms bigint)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_user uuid := auth.uid();
begin
  if v_user is null then
    raise exception using errcode = '42501', message = 'authentication_required';
  end if;
  if p_since_ms is null or p_since_ms < 0 then
    raise exception using errcode = '22023', message = 'invalid_page';
  end if;
  return coalesce((select jsonb_agg(jsonb_build_object(
      'id', s.external_id, 'item_id', s.item_id, 'bank', i.label,
      'account_id', s.account_external_id, 'nexo_account_id', a.nexo_account_id,
      'amount_cents', s.amount_cents, 'kind', s.kind, 'medium', s.medium,
      'description', s.description, 'occurred_at', s.occurred_at, 'settled', s.settled,
      'installment', s.installment, 'review', s.review, 'changed', s.changed,
      'transaction_id', s.transaction_id, 'direction', s.direction,
      'operation_ref', s.operation_ref, 'payment_ref', s.payment_ref,
      'same_owner', s.same_owner, 'counterparty', s.counterparty,
      'manual', s.manual, 'vanished', s.vanished_at is not null)
      order by s.occurred_at desc)
    from (select * from nexo_pluggy_private.suggestions
      where owner_id = v_user and occurred_at >= p_since_ms
      order by occurred_at desc limit 2000) s
    join nexo_pluggy_private.items i on i.owner_id = s.owner_id and i.item_id = s.item_id
    left join nexo_pluggy_private.accounts a
      on a.owner_id = s.owner_id and a.account_id = s.account_external_id), '[]'::jsonb);
end;
$$;

-- The assistant's pending list leaves out what the bank no longer shows.
create or replace function public.nexo_mcp_suggestions(p_connector_id uuid, p_limit integer)
returns jsonb language sql security definer set search_path = '' as $$
  select coalesce(jsonb_agg(page.item order by (page.item->>'occurred_at')::bigint desc), '[]'::jsonb)
  from (select jsonb_build_object('id', s.external_id, 'bank', i.label,
      'account_id', s.account_external_id, 'nexo_account_id', a.nexo_account_id,
      'amount_cents', s.amount_cents, 'kind', s.kind, 'medium', s.medium,
      'description', s.description, 'occurred_at', s.occurred_at,
      'settled', s.settled, 'installment', s.installment, 'direction', s.direction,
      'operation_ref', s.operation_ref, 'payment_ref', s.payment_ref,
      'same_owner', s.same_owner, 'counterparty', s.counterparty,
      'manual', s.manual) as item
    from nexo_pluggy_private.suggestions s
    join nexo_pluggy_private.items i on i.owner_id = s.owner_id and i.item_id = s.item_id
    join nexo_mcp_private.connectors k
      on k.id = p_connector_id and k.revoked_at is null and k.owner_id = s.owner_id
    join nexo_sync_lab_private.datasets d
      on d.id = k.dataset_id and d.owner_id = k.owner_id and not d.synthetic_only
    left join nexo_pluggy_private.accounts a
      on a.owner_id = s.owner_id and a.account_id = s.account_external_id
    where s.review = 'pending' and s.vanished_at is null
    order by s.occurred_at desc
    limit greatest(1, least(coalesce(p_limit, 30), 200))) page;
$$;

-- For reconcile_account, plus "vanished".
create or replace function public.nexo_mcp_bank_movements(
  p_connector_id uuid, p_from_ms bigint, p_to_ms bigint
) returns jsonb language sql security definer set search_path = '' as $$
  select coalesce(jsonb_agg(page.item order by (page.item->>'occurred_at')::bigint), '[]'::jsonb)
  from (select jsonb_build_object('id', s.external_id, 'bank', i.label,
      'account_id', s.account_external_id, 'nexo_account_id', a.nexo_account_id,
      'amount_cents', s.amount_cents, 'kind', s.kind, 'medium', s.medium,
      'description', s.description, 'occurred_at', s.occurred_at,
      'settled', s.settled, 'installment', s.installment, 'review', s.review,
      'transaction_id', s.transaction_id, 'direction', s.direction,
      'operation_ref', s.operation_ref, 'payment_ref', s.payment_ref,
      'same_owner', s.same_owner, 'counterparty', s.counterparty,
      'vanished', s.vanished_at is not null) as item
    from nexo_pluggy_private.suggestions s
    join nexo_pluggy_private.items i on i.owner_id = s.owner_id and i.item_id = s.item_id
    join nexo_mcp_private.connectors k
      on k.id = p_connector_id and k.revoked_at is null and k.owner_id = s.owner_id
    join nexo_sync_lab_private.datasets d
      on d.id = k.dataset_id and d.owner_id = k.owner_id and not d.synthetic_only
    left join nexo_pluggy_private.accounts a
      on a.owner_id = s.owner_id and a.account_id = s.account_external_id
    where s.occurred_at >= coalesce(p_from_ms, 0)
      and s.occurred_at < coalesce(p_to_ms, 9007199254740991)
    order by s.occurred_at
    limit 3000) page;
$$;

revoke all on function public.nexo_pluggy_vanish(uuid, text, text[], text[], bigint) from public, anon, authenticated;
grant execute on function public.nexo_pluggy_vanish(uuid, text, text[], text[], bigint) to service_role;
revoke all on function public.nexo_pluggy_suggestions(bigint) from public, anon, authenticated;
grant execute on function public.nexo_pluggy_suggestions(bigint) to authenticated;
revoke all on function public.nexo_mcp_suggestions(uuid, integer) from public, anon, authenticated;
grant execute on function public.nexo_mcp_suggestions(uuid, integer) to service_role;
revoke all on function public.nexo_mcp_bank_movements(uuid, bigint, bigint) from public, anon, authenticated;
grant execute on function public.nexo_mcp_bank_movements(uuid, bigint, bigint) to service_role;

commit;
