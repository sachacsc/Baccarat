-- Lifecycle tracking pour les parties online :
--   - Une partie apparaît dans l'historique dès la création du lobby
--     (pas seulement après la 1re manche terminée).
--   - "En cours" repose sur `last_active_at` (touch sur chaque broadcast/manche),
--     pas sur une heuristique 24h.
--   - Les game_participants sont sync au join, pas au 1er record_manche.

-- ===== Colonne last_active_at =====
alter table public.games
  add column if not exists last_active_at timestamptz not null default now();

create index if not exists games_last_active_idx
  on public.games(last_active_at desc);

-- ===== RPC ensure_game_and_participants =====
-- Crée la game si p_game_id est null, sinon synchronise ses settings.
-- UPSERT les participants par (game_id, seat_index).
-- Touch last_active_at à chaque appel.
--
-- Autorisé pour l'owner OU n'importe quel participant déjà enregistré
-- (couvre les transferts d'hôte).

create or replace function public.ensure_game_and_participants(
  p_game_id uuid,
  p_mode text,
  p_line_price numeric,
  p_currency text,
  p_settings_json jsonb,
  p_participants jsonb
) returns uuid
language plpgsql
security definer
set search_path = public, auth
as $$
declare
  v_game_id uuid;
  v_caller uuid := auth.uid();
  v_participant jsonb;
begin
  if v_caller is null then
    raise exception 'unauthorized';
  end if;

  if p_game_id is null then
    -- Création — le caller devient owner.
    insert into public.games(
      owner_user_id, mode, line_price, currency,
      settings_json, status, last_active_at
    )
    values (
      v_caller, p_mode, p_line_price, p_currency,
      coalesce(p_settings_json, '{}'::jsonb), 'active', now()
    )
    returning id into v_game_id;
  else
    -- Update — caller doit être owner OU participant.
    if not exists (
      select 1 from public.games g
      where g.id = p_game_id
        and (
          g.owner_user_id = v_caller
          or exists (
            select 1 from public.game_participants gp
            where gp.game_id = g.id and gp.user_id = v_caller
          )
        )
    ) then
      raise exception 'forbidden';
    end if;

    update public.games
      set line_price = p_line_price,
          currency = p_currency,
          settings_json = coalesce(p_settings_json, settings_json),
          last_active_at = now()
      where id = p_game_id;
    v_game_id := p_game_id;
  end if;

  -- UPSERT participants. p_participants : [{seat_index, user_id?, guest_name?}, ...]
  if p_participants is not null then
    for v_participant in select * from jsonb_array_elements(p_participants) loop
      insert into public.game_participants(
        game_id, seat_index, user_id, guest_name
      )
      values (
        v_game_id,
        (v_participant->>'seat_index')::int,
        nullif(v_participant->>'user_id', '')::uuid,
        nullif(v_participant->>'guest_name', '')
      )
      on conflict (game_id, seat_index) do update
      set user_id = coalesce(excluded.user_id, public.game_participants.user_id),
          guest_name = coalesce(excluded.guest_name, public.game_participants.guest_name);
    end loop;
  end if;

  return v_game_id;
end;
$$;

revoke all on function public.ensure_game_and_participants(uuid, text, numeric, text, jsonb, jsonb)
  from anon, authenticated;
grant execute on function public.ensure_game_and_participants(uuid, text, numeric, text, jsonb, jsonb)
  to authenticated;

-- ===== RPC touch_game_active =====
-- Bump léger de last_active_at. Appelé périodiquement par les clients pour
-- signaler que le salon est encore vivant. Vérification : caller doit être
-- owner ou participant.

create or replace function public.touch_game_active(p_game_id uuid)
returns void
language plpgsql
security definer
set search_path = public, auth
as $$
declare
  v_caller uuid := auth.uid();
begin
  if v_caller is null then
    raise exception 'unauthorized';
  end if;
  if not exists (
    select 1 from public.games g
    where g.id = p_game_id
      and (
        g.owner_user_id = v_caller
        or exists (
          select 1 from public.game_participants gp
          where gp.game_id = g.id and gp.user_id = v_caller
        )
      )
  ) then
    raise exception 'forbidden';
  end if;

  update public.games
    set last_active_at = now()
    where id = p_game_id;
end;
$$;

revoke all on function public.touch_game_active(uuid) from anon, authenticated;
grant execute on function public.touch_game_active(uuid) to authenticated;
