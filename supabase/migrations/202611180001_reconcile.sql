-- Nexo 1.18: what the reconciliation needs from each bank movement.
--
-- * direction: a "transfer" from the bank lost whether money came in or went
--   out, so yields and card payments were read as outgoing.
-- * operation_ref / payment_ref: the bank's id of the operation, so a
--   payment and its refund can be paired even days apart.
-- * same_owner: payer and receiver have the same tax number. The number
--   itself is never stored, only the comparison.
-- * counterparty: who paid or received, when the description is just "Pix".
-- * manual: the person undid what the app had decided by itself; no device
--   decides it by itself again.
--
-- Only adds columns and replaces functions with versions that return more
-- fields. No row is deleted and no decision or amount is rewritten.
begin;

alter table nexo_pluggy_private.suggestions
  add column if not exists direction text
    check (direction is null or direction in ('in', 'out')),
  add column if not exists operation_ref text
    check (operation_ref is null or operation_ref ~ '^[0-9A-Za-z._:/-]{1,80}$'),
  add column if not exists payment_ref text
    check (payment_ref is null or payment_ref ~ '^[0-9A-Za-z._:/-]{1,80}$'),
  add column if not exists same_owner boolean,
  add column if not exists counterparty text
    check (counterparty is null or length(counterparty) between 1 and 60),
  add column if not exists manual boolean not null default false;

-- Rows stored before 1.18. Income, expense and refund already say where the
-- money went; a transfer on a card is a payment received by the card; a
-- bank transfer that reads like a yield or a redemption came in. The next
-- bank read replaces this guess with the bank's own value ('annotate').
update nexo_pluggy_private.suggestions set direction = case
    when kind = 'expense' then 'out'
    when kind in ('income', 'refund') then 'in'
    when medium = 'credit' then 'in'
    when description ~* '(rendimento|remunera|resgate|recebid)' then 'in'
    else 'out' end
  where direction is null;

-- What pluggy-sync needs to decide insert / update / annotate / keep.
create or replace function public.nexo_pluggy_stored(p_owner uuid, p_ids text[])
returns jsonb language sql security definer set search_path = '' as $$
  select coalesce(jsonb_agg(jsonb_build_object(
    'external_id', external_id, 'account_external_id', account_external_id,
    'item_id', item_id, 'amount_cents', amount_cents, 'kind', kind,
    'medium', medium, 'description', description, 'occurred_at', occurred_at,
    'settled', settled, 'installment', installment,
    'source_updated_at', source_updated_at, 'review', review,
    'direction', direction, 'operation_ref', operation_ref,
    'payment_ref', payment_ref, 'same_owner', same_owner,
    'counterparty', counterparty)), '[]'::jsonb)
  from nexo_pluggy_private.suggestions
  where owner_id = p_owner and external_id = any(p_ids);
$$;

-- Same rules as before, plus the new fields. 'annotate' fills only the new
-- fields of a row the bank did not change: never amounts, dates, kinds or
-- the person's decision.
create or replace function public.nexo_pluggy_store(
  p_owner uuid, p_item_id text, p_health jsonb, p_rows jsonb
) returns integer language plpgsql security definer set search_path = '' as $$
declare
  v_row jsonb;
  v_written integer := 0;
  v_count integer;
begin
  if not exists(select 1 from nexo_pluggy_private.items
      where owner_id = p_owner and item_id = p_item_id) then
    raise exception using errcode = '42501', message = 'item_unavailable';
  end if;
  update nexo_pluggy_private.items set health = p_health, last_fetch_at = now()
    where owner_id = p_owner and item_id = p_item_id;
  for v_row in select * from jsonb_array_elements(coalesce(p_rows, '[]'::jsonb)) loop
    if v_row->>'action' = 'insert' then
      insert into nexo_pluggy_private.suggestions(owner_id, external_id, item_id,
          account_external_id, amount_cents, kind, medium, description,
          occurred_at, settled, installment, source_updated_at,
          direction, operation_ref, payment_ref, same_owner, counterparty)
        values (p_owner, v_row->>'external_id', p_item_id,
          v_row->>'account_external_id', (v_row->>'amount_cents')::bigint,
          v_row->>'kind', v_row->>'medium', v_row->>'description',
          (v_row->>'occurred_at')::bigint, (v_row->>'settled')::boolean,
          v_row->>'installment', v_row->>'source_updated_at',
          v_row->>'direction', v_row->>'operation_ref', v_row->>'payment_ref',
          (v_row->>'same_owner')::boolean, v_row->>'counterparty')
        on conflict (owner_id, external_id) do nothing;
    elsif v_row->>'action' = 'update' then
      update nexo_pluggy_private.suggestions set
          amount_cents = (v_row->>'amount_cents')::bigint, kind = v_row->>'kind',
          medium = v_row->>'medium', description = v_row->>'description',
          occurred_at = (v_row->>'occurred_at')::bigint,
          settled = (v_row->>'settled')::boolean, installment = v_row->>'installment',
          source_updated_at = v_row->>'source_updated_at',
          direction = coalesce(v_row->>'direction', direction),
          operation_ref = coalesce(v_row->>'operation_ref', operation_ref),
          payment_ref = coalesce(v_row->>'payment_ref', payment_ref),
          same_owner = coalesce((v_row->>'same_owner')::boolean, same_owner),
          counterparty = coalesce(v_row->>'counterparty', counterparty),
          updated_at = now()
        where owner_id = p_owner and external_id = v_row->>'external_id'
          and review = 'pending' and source_updated_at < v_row->>'source_updated_at';
    elsif v_row->>'action' = 'flag_changed' then
      update nexo_pluggy_private.suggestions set changed = true,
          source_updated_at = v_row->>'source_updated_at', updated_at = now()
        where owner_id = p_owner and external_id = v_row->>'external_id'
          and review <> 'pending' and source_updated_at < v_row->>'source_updated_at';
    elsif v_row->>'action' = 'annotate' then
      update nexo_pluggy_private.suggestions set
          direction = coalesce(v_row->>'direction', direction),
          operation_ref = coalesce(v_row->>'operation_ref', operation_ref),
          payment_ref = coalesce(v_row->>'payment_ref', payment_ref),
          same_owner = coalesce((v_row->>'same_owner')::boolean, same_owner),
          counterparty = coalesce(v_row->>'counterparty', counterparty),
          updated_at = now()
        where owner_id = p_owner and external_id = v_row->>'external_id'
          and (direction is distinct from coalesce(v_row->>'direction', direction)
            or operation_ref is distinct from coalesce(v_row->>'operation_ref', operation_ref)
            or payment_ref is distinct from coalesce(v_row->>'payment_ref', payment_ref)
            or same_owner is distinct from coalesce((v_row->>'same_owner')::boolean, same_owner)
            or counterparty is distinct from coalesce(v_row->>'counterparty', counterparty));
    else
      raise exception using errcode = '22023', message = 'invalid_action';
    end if;
    get diagnostics v_count = row_count;
    v_written := v_written + v_count;
  end loop;
  return v_written;
end;
$$;

-- The app's inbox: every movement since p_since_ms (pending and decided),
-- with the bank, the bank account and the Nexo account it is linked to.
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
      'manual', s.manual)
      order by s.occurred_at desc)
    from (select * from nexo_pluggy_private.suggestions
      where owner_id = v_user and occurred_at >= p_since_ms
      order by occurred_at desc limit 2000) s
    join nexo_pluggy_private.items i on i.owner_id = s.owner_id and i.item_id = s.item_id
    left join nexo_pluggy_private.accounts a
      on a.owner_id = s.owner_id and a.account_id = s.account_external_id), '[]'::jsonb);
end;
$$;

-- The assistant's view of what is still pending, with the same fields.
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
    left join nexo_pluggy_private.accounts a
      on a.owner_id = s.owner_id and a.account_id = s.account_external_id
    where s.review = 'pending'
    order by s.occurred_at desc
    limit greatest(1, least(coalesce(p_limit, 30), 200))) page;
$$;

-- For reconcile_account: every movement of a period, pending or decided,
-- with the entry it became. Read-only.
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
    left join nexo_pluggy_private.accounts a
      on a.owner_id = s.owner_id and a.account_id = s.account_external_id
    where s.occurred_at >= coalesce(p_from_ms, 0)
      and s.occurred_at < coalesce(p_to_ms, 9007199254740991)
    order by s.occurred_at
    limit 3000) page;
$$;

-- Decisions from a device. New: `"reopen": true` puts a confirmed movement
-- back to pending, for when the entry the app had registered for it was
-- undone (a link stays final otherwise). Anything put back to pending is
-- marked manual: the person decides it.
create or replace function public.nexo_pluggy_decide(p_decisions jsonb)
returns integer language plpgsql security definer set search_path = '' as $$
declare
  v_user uuid := auth.uid();
  v_item jsonb;
  v_changed integer := 0;
  v_count integer;
begin
  if v_user is null then
    raise exception using errcode = '42501', message = 'authentication_required';
  end if;
  if p_decisions is null or jsonb_typeof(p_decisions) <> 'array'
      or jsonb_array_length(p_decisions) > 500 then
    raise exception using errcode = '22023', message = 'invalid_decisions';
  end if;
  for v_item in select * from jsonb_array_elements(p_decisions) loop
    if jsonb_typeof(v_item) <> 'object' or (v_item->>'id') is null
        or (v_item->>'review') not in ('pending', 'confirmed', 'ignored') then
      raise exception using errcode = '22023', message = 'invalid_decisions';
    end if;
    update nexo_pluggy_private.suggestions set
        review = v_item->>'review',
        transaction_id = case when v_item->>'review' = 'confirmed'
          then left(v_item->>'transaction_id', 256) else null end,
        manual = manual or v_item->>'review' = 'pending',
        updated_at = now()
      where owner_id = v_user and external_id = v_item->>'id'
        and review <> v_item->>'review'
        and (review <> 'confirmed'
          or (v_item->>'review' = 'pending' and v_item->'reopen' = 'true'::jsonb))
        and (v_item->>'review' <> 'pending' or review in ('ignored', 'confirmed'));
    get diagnostics v_count = row_count;
    v_changed := v_changed + v_count;
  end loop;
  return v_changed;
end;
$$;

revoke all on function public.nexo_pluggy_decide(jsonb) from public, anon, authenticated;
grant execute on function public.nexo_pluggy_decide(jsonb) to authenticated;
revoke all on function public.nexo_pluggy_stored(uuid, text[]) from public, anon, authenticated;
grant execute on function public.nexo_pluggy_stored(uuid, text[]) to service_role;
revoke all on function public.nexo_pluggy_store(uuid, text, jsonb, jsonb) from public, anon, authenticated;
grant execute on function public.nexo_pluggy_store(uuid, text, jsonb, jsonb) to service_role;
revoke all on function public.nexo_pluggy_suggestions(bigint) from public, anon, authenticated;
grant execute on function public.nexo_pluggy_suggestions(bigint) to authenticated;
revoke all on function public.nexo_mcp_suggestions(uuid, integer) from public, anon, authenticated;
grant execute on function public.nexo_mcp_suggestions(uuid, integer) to service_role;
revoke all on function public.nexo_mcp_bank_movements(uuid, bigint, bigint) from public, anon, authenticated;
grant execute on function public.nexo_mcp_bank_movements(uuid, bigint, bigint) to service_role;

notify pgrst, 'reload schema';
commit;
