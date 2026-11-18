-- Nexo: two findings of the audit of 18/11/2026, on the server side.
--
-- * Bank data belongs to the person's real dataset. The connector functions
--   that read or change it joined by owner only, so a connector created for
--   a synthetic (test) dataset saw the real bank movements, balances and
--   invoices of its owner, and could ignore suggestions or change a link.
--   They now require the connector's dataset to be the real one
--   (datasets.synthetic_only = false, as nexo_sync_open keeps it). A test
--   connector gets an empty answer and changes nothing.
-- * nexo_sync_delete_dataset failed for a dataset with assistant requests
--   (commands point at its connectors, without cascade) and left the
--   device reports and push tokens of the dataset behind. It now removes
--   everything that names the dataset, in an order the constraints accept.
--
-- Only replaces functions (same names, arguments and results) and restates
-- their grants. No table, constraint or row is changed by this file; it can
-- be applied again.
begin;

-- ── Bank data: only for the connector of the real dataset ───────────────

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
    where s.review = 'pending'
    order by s.occurred_at desc
    limit greatest(1, least(coalesce(p_limit, 30), 200))) page;
$$;

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
      'same_owner', s.same_owner, 'counterparty', s.counterparty) as item
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

create or replace function public.nexo_mcp_bank_status(p_connector_id uuid)
returns jsonb language sql security definer set search_path = '' as $$
  select coalesce(jsonb_agg(jsonb_build_object(
      'bank', i.label, 'state', i.health->>'state', 'message', i.health->>'message',
      'bank_updated_at', i.bank_updated_at, 'read_at', i.last_fetch_at) order by i.created_at), '[]'::jsonb)
  from nexo_pluggy_private.items i
  join nexo_mcp_private.connectors k
    on k.id = p_connector_id and k.revoked_at is null and k.owner_id = i.owner_id
  join nexo_sync_lab_private.datasets d
    on d.id = k.dataset_id and d.owner_id = k.owner_id and not d.synthetic_only;
$$;

create or replace function public.nexo_mcp_bank_accounts(p_connector_id uuid)
returns jsonb language sql security definer set search_path = '' as $$
  select coalesce(jsonb_agg(jsonb_build_object(
      'account_id', a.account_id, 'bank', i.label, 'type', a.type, 'subtype', a.subtype,
      'name', a.name, 'currency', a.currency, 'balance_cents', a.balance_cents,
      'credit_limit_cents', a.credit_limit_cents, 'available_cents', a.available_cents,
      'minimum_payment_cents', a.minimum_payment_cents, 'close_date', a.close_date,
      'due_date', a.due_date, 'nexo_account_id', a.nexo_account_id,
      'bank_updated_at', i.bank_updated_at,
      'bills', coalesce((select jsonb_agg(jsonb_build_object('due_date', b.due_date,
          'close_date', b.close_date, 'total_cents', b.total_cents,
          'minimum_cents', b.minimum_cents, 'paid_cents', b.paid_cents) order by b.due_date desc)
        from nexo_pluggy_private.bills b
        where b.owner_id = a.owner_id and b.account_id = a.account_id), '[]'::jsonb))
    order by i.created_at, a.type, a.name), '[]'::jsonb)
  from nexo_pluggy_private.accounts a
  join nexo_pluggy_private.items i on i.owner_id = a.owner_id and i.item_id = a.item_id
  join nexo_mcp_private.connectors k
    on k.id = p_connector_id and k.revoked_at is null and k.owner_id = a.owner_id
  join nexo_sync_lab_private.datasets d
    on d.id = k.dataset_id and d.owner_id = k.owner_id and not d.synthetic_only;
$$;

-- Ignoring moves no money, so it is applied here; devices drop the
-- suggestion from their inbox on the next refresh.
create or replace function public.nexo_mcp_ignore_suggestions(
  p_connector_id uuid, p_ids text[], p_before_ms bigint
) returns integer language plpgsql security definer set search_path = '' as $$
declare
  v_row nexo_mcp_private.connectors%rowtype;
  v_count integer;
begin
  select * into v_row from nexo_mcp_private.connectors
    where id = p_connector_id and revoked_at is null;
  if not found or v_row.scope <> 'write' then
    raise exception using errcode = '42501', message = 'read_only_connector';
  end if;
  if (p_ids is null or cardinality(p_ids) = 0) and p_before_ms is null then
    raise exception using errcode = '22023', message = 'invalid_selection';
  end if;
  -- A connector of a test dataset has no bank suggestions of its own.
  if not exists (select 1 from nexo_sync_lab_private.datasets
      where id = v_row.dataset_id and owner_id = v_row.owner_id and not synthetic_only) then
    return 0;
  end if;
  update nexo_pluggy_private.suggestions set review = 'ignored', updated_at = now()
    where owner_id = v_row.owner_id and review = 'pending'
      and ((p_ids is not null and external_id = any(p_ids))
        or (p_before_ms is not null and occurred_at < p_before_ms));
  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

-- Links a bank account to a Nexo account (the screen's "vincular"); moves no
-- money, so it is applied here, like ignoring suggestions.
create or replace function public.nexo_mcp_link_bank_account(
  p_connector_id uuid, p_account_id text, p_nexo_account_id text)
returns integer language plpgsql security definer set search_path = '' as $$
declare
  v_row nexo_mcp_private.connectors%rowtype;
  v_count integer;
begin
  select * into v_row from nexo_mcp_private.connectors
    where id = p_connector_id and revoked_at is null;
  if not found or v_row.scope <> 'write' then
    raise exception using errcode = '42501', message = 'read_only_connector';
  end if;
  if p_nexo_account_id is not null and length(p_nexo_account_id) not between 1 and 128 then
    raise exception using errcode = '22023', message = 'invalid_account';
  end if;
  -- The link names an account of the real dataset: not for a test connector.
  if not exists (select 1 from nexo_sync_lab_private.datasets
      where id = v_row.dataset_id and owner_id = v_row.owner_id and not synthetic_only) then
    return 0;
  end if;
  update nexo_pluggy_private.accounts set nexo_account_id = p_nexo_account_id
    where owner_id = v_row.owner_id and account_id = p_account_id;
  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

-- ── Deleting a dataset removes everything that names it ─────────────────
-- Removes the server copy of one dataset of the caller. Devices keep their
-- local data; they stop syncing because the dataset no longer exists.
create or replace function public.nexo_sync_delete_dataset(p_dataset_id uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare v_user uuid := auth.uid();
begin
  if v_user is null then
    raise exception using errcode = '42501', message = 'authentication_required';
  end if;
  perform 1 from nexo_sync_lab_private.datasets
    where id = p_dataset_id and owner_id = v_user for update;
  if not found then
    raise exception using errcode = '42501', message = 'dataset_unavailable';
  end if;
  -- The assistant's side first. Requests point at connectors, so they go
  -- before them; device reports and push tokens only name the dataset.
  if to_regclass('nexo_mcp_private.commands') is not null then
    execute 'delete from nexo_mcp_private.commands where dataset_id = $1
      or connector_id in (select id from nexo_mcp_private.connectors where dataset_id = $1)'
      using p_dataset_id;
  end if;
  if to_regclass('nexo_mcp_private.capabilities') is not null then
    execute 'delete from nexo_mcp_private.capabilities where dataset_id = $1' using p_dataset_id;
  end if;
  if to_regclass('nexo_mcp_private.push_tokens') is not null then
    execute 'delete from nexo_mcp_private.push_tokens where dataset_id = $1' using p_dataset_id;
  end if;
  if to_regclass('nexo_mcp_private.connectors') is not null then
    execute 'delete from nexo_mcp_private.audit where connector_id in
      (select id from nexo_mcp_private.connectors where dataset_id = $1)'
      using p_dataset_id;
    execute 'delete from nexo_mcp_private.connectors where dataset_id = $1'
      using p_dataset_id;
  end if;
  delete from nexo_sync_lab_private.balances where dataset_id = p_dataset_id;
  delete from nexo_sync_lab_private.requests where dataset_id = p_dataset_id;
  delete from nexo_sync_lab_private.entities where dataset_id = p_dataset_id;
  delete from nexo_sync_lab_private.devices where dataset_id = p_dataset_id;
  delete from nexo_sync_lab_private.datasets where id = p_dataset_id;
end;
$$;

-- Replacing a function keeps its grants; restated so this file stands alone.
revoke all on function public.nexo_mcp_suggestions(uuid, integer) from public, anon, authenticated;
revoke all on function public.nexo_mcp_bank_movements(uuid, bigint, bigint) from public, anon, authenticated;
revoke all on function public.nexo_mcp_bank_status(uuid) from public, anon, authenticated;
revoke all on function public.nexo_mcp_bank_accounts(uuid) from public, anon, authenticated;
revoke all on function public.nexo_mcp_ignore_suggestions(uuid, text[], bigint) from public, anon, authenticated;
revoke all on function public.nexo_mcp_link_bank_account(uuid, text, text) from public, anon, authenticated;
revoke all on function public.nexo_sync_delete_dataset(uuid) from public, anon, authenticated;
grant execute on function public.nexo_mcp_suggestions(uuid, integer) to service_role;
grant execute on function public.nexo_mcp_bank_movements(uuid, bigint, bigint) to service_role;
grant execute on function public.nexo_mcp_bank_status(uuid) to service_role;
grant execute on function public.nexo_mcp_bank_accounts(uuid) to service_role;
grant execute on function public.nexo_mcp_ignore_suggestions(uuid, text[], bigint) to service_role;
grant execute on function public.nexo_mcp_link_bank_account(uuid, text, text) to service_role;
grant execute on function public.nexo_sync_delete_dataset(uuid) to authenticated;

notify pgrst, 'reload schema';
commit;
