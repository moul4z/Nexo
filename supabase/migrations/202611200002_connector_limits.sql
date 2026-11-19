-- Nexo 1.19: the assistant's address has a validity and a limit per minute
-- (SEC-01, minimal version), and a request is read only by a connector of
-- its own dataset (SEC-12).
--
-- * expires_at: an address works for 90 days and is renewed in the app
--   (the same address keeps working; no need to paste it again in Claude).
--   Addresses made before this file get 90 days from today.
-- * window_start / window_calls: calls in the current minute. Above 120 the
--   server answers "wait a little" instead of reading the data.
-- * nexo_mcp_command: a connector of a test dataset no longer reads, by its
--   id, a request of the real dataset of the same person (and vice versa).
--
-- Only adds columns and replaces functions. No request, decision or amount
-- is changed; a revoked address stays revoked.
begin;

alter table nexo_mcp_private.connectors
  add column if not exists expires_at timestamptz,
  add column if not exists window_start timestamptz,
  add column if not exists window_calls integer not null default 0;

update nexo_mcp_private.connectors set expires_at = now() + interval '90 days'
  where expires_at is null and revoked_at is null;

-- Called for every call to the assistant's address.
create or replace function public.nexo_mcp_authenticate(p_token_hash text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_row nexo_mcp_private.connectors%rowtype;
begin
  if p_token_hash is null or p_token_hash !~ '^[0-9a-f]{64}$' then return null; end if;
  -- Every expression on the right reads the row as it was before.
  update nexo_mcp_private.connectors set last_used_at = now(),
      window_calls = case when window_start is null or window_start <= now() - interval '1 minute'
        then 1 else window_calls + 1 end,
      window_start = case when window_start is null or window_start <= now() - interval '1 minute'
        then now() else window_start end
    where token_hash = p_token_hash and revoked_at is null
      and (expires_at is null or expires_at > now())
    returning * into v_row;
  if not found then return null; end if;
  return jsonb_build_object('id', v_row.id, 'owner_id', v_row.owner_id,
    'dataset_id', v_row.dataset_id, 'scope', v_row.scope,
    'expires_at', v_row.expires_at, 'limited', v_row.window_calls > 120);
end;
$$;

-- Why a token does not authenticate: 'revoked' (with when), 'expired'
-- (with when) or 'unknown'. Says nothing about whose it was.
create or replace function public.nexo_mcp_token_state(p_token_hash text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_revoked timestamptz;
  v_expires timestamptz;
begin
  if p_token_hash is null or p_token_hash !~ '^[0-9a-f]{64}$' then
    return jsonb_build_object('state', 'unknown');
  end if;
  select revoked_at, expires_at into v_revoked, v_expires from nexo_mcp_private.connectors
    where token_hash = p_token_hash;
  if not found then return jsonb_build_object('state', 'unknown'); end if;
  if v_revoked is not null then
    return jsonb_build_object('state', 'revoked', 'revoked_at', v_revoked);
  end if;
  if v_expires is not null and v_expires <= now() then
    return jsonb_build_object('state', 'expired', 'expires_at', v_expires);
  end if;
  return jsonb_build_object('state', 'active');
end;
$$;

-- As before, valid for 90 days.
create or replace function public.nexo_mcp_create_connector(p_dataset_id uuid, p_label text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_user uuid := auth.uid();
  v_token text;
  v_id uuid;
  v_expires timestamptz := now() + interval '90 days';
begin
  if v_user is null then
    raise exception using errcode = '42501', message = 'authentication_required';
  end if;
  if p_label is null or length(trim(p_label)) not between 1 and 60 then
    raise exception using errcode = '22023', message = 'invalid_label';
  end if;
  if not exists (select 1 from nexo_sync_lab_private.datasets
      where id = p_dataset_id and owner_id = v_user) then
    raise exception using errcode = '42501', message = 'dataset_unavailable';
  end if;
  if (select count(*) from nexo_mcp_private.connectors
      where owner_id = v_user and revoked_at is null) >= 5 then
    raise exception using errcode = '22023', message = 'too_many_connectors';
  end if;
  v_token := 'nexo_mcp_' || replace(gen_random_uuid()::text, '-', '')
    || replace(gen_random_uuid()::text, '-', '');
  insert into nexo_mcp_private.connectors(owner_id, dataset_id, token_hash, label, scope, expires_at)
    values (v_user, p_dataset_id, encode(sha256(convert_to(v_token, 'UTF8')), 'hex'),
      trim(p_label), 'write', v_expires)
    returning id into v_id;
  return jsonb_build_object('id', v_id, 'label', trim(p_label), 'token', v_token,
    'expires_at', v_expires);
end;
$$;

-- The person extends an address for 90 days from now, expired or not. The
-- address stays the same. A revoked one cannot come back.
create or replace function public.nexo_mcp_renew_connector(p_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_user uuid := auth.uid();
  v_expires timestamptz;
begin
  if v_user is null then
    raise exception using errcode = '42501', message = 'authentication_required';
  end if;
  update nexo_mcp_private.connectors set expires_at = now() + interval '90 days'
    where id = p_id and owner_id = v_user and revoked_at is null
    returning expires_at into v_expires;
  if not found then
    raise exception using errcode = '42501', message = 'connector_unavailable';
  end if;
  return jsonb_build_object('id', p_id, 'expires_at', v_expires);
end;
$$;

-- The app's list, plus the validity.
create or replace function public.nexo_mcp_connector_status()
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_user uuid := auth.uid();
begin
  if v_user is null then
    raise exception using errcode = '42501', message = 'authentication_required';
  end if;
  return coalesce((select jsonb_agg(jsonb_build_object(
      'id', k.id, 'label', k.label, 'dataset_id', k.dataset_id, 'scope', k.scope,
      'created_at', k.created_at, 'last_used_at', k.last_used_at, 'revoked_at', k.revoked_at,
      'expires_at', k.expires_at,
      'requests', (select count(*) from nexo_mcp_private.commands c where c.connector_id = k.id),
      'requests_7d', (select count(*) from nexo_mcp_private.commands c
        where c.connector_id = k.id and c.created_at > now() - interval '7 days'),
      'last_request_at', (select max(created_at) from nexo_mcp_private.commands c
        where c.connector_id = k.id))
      order by k.created_at desc)
    from nexo_mcp_private.connectors k where k.owner_id = v_user), '[]'::jsonb);
end;
$$;

-- SEC-12: a request is read only by a connector of its dataset.
create or replace function public.nexo_mcp_command(p_connector_id uuid, p_id uuid)
returns jsonb language sql security definer set search_path = '' as $$
  select jsonb_build_object('id', c.id, 'kind', c.kind, 'status', c.status,
    'result', c.result, 'created_at', c.created_at, 'finished_at', c.finished_at)
  from nexo_mcp_private.commands c join nexo_mcp_private.connectors k
    on k.id = p_connector_id and k.revoked_at is null and k.owner_id = c.owner_id
      and k.dataset_id = c.dataset_id
  where c.id = p_id;
$$;

revoke all on function public.nexo_mcp_authenticate(text) from public, anon, authenticated;
grant execute on function public.nexo_mcp_authenticate(text) to service_role;
revoke all on function public.nexo_mcp_token_state(text) from public, anon, authenticated;
grant execute on function public.nexo_mcp_token_state(text) to service_role;
revoke all on function public.nexo_mcp_create_connector(uuid, text) from public, anon;
grant execute on function public.nexo_mcp_create_connector(uuid, text) to authenticated;
revoke all on function public.nexo_mcp_renew_connector(uuid) from public, anon;
grant execute on function public.nexo_mcp_renew_connector(uuid) to authenticated;
revoke all on function public.nexo_mcp_connector_status() from public, anon;
grant execute on function public.nexo_mcp_connector_status() to authenticated;
revoke all on function public.nexo_mcp_command(uuid, uuid) from public, anon, authenticated;
grant execute on function public.nexo_mcp_command(uuid, uuid) to service_role;

notify pgrst, 'reload schema';

commit;
