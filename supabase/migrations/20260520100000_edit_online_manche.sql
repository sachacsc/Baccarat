-- Edit any online manche + record manual adjustment for an online game.
--
-- Architecture :
--   * manches gets a `kind text` ('normal' | 'adjustment') + `transfers_json`
--     for the pairwise transfers of adjustment manches (empty for normal).
--   * _revert_balances_for_manche : applique l'inverse des transferts qui ont
--     été appliqués à la création / au dernier edit. Pour normal : itère
--     board_results en swappant payer/payee. Pour adjustment : itère
--     transfers_json inversé.
--   * update_online_manche : owner only. Revert → update record → apply.
--   * record_online_adjustment : owner only. Insère une manche kind=adjustment
--     avec transfers + per-seat deltas, applique les transferts.
--
-- Notes :
--   * Pour rester compatible avec _apply_balances_for_manche existant (qui
--     itère board_results), on garde ce comportement pour kind=normal et
--     on ajoute une branche kind=adjustment qui itère transfers_json.
--   * record_manche (legacy normal) reste inchangé : insère kind='normal' par
--     défaut grâce à la default value de la colonne.

-- =================================================================
-- 1) Schema additions
-- =================================================================

alter table public.manches
  add column if not exists kind text not null default 'normal',
  add column if not exists transfers_json jsonb not null default '[]'::jsonb;

-- Le manche_number doit rester unique par game mais on permet des nombres
-- négatifs pour les adjustments (-1, -2, …). La contrainte UNIQUE existante
-- couvre déjà ça (uniqueness sur game_id + manche_number).

create index if not exists manches_kind_idx on public.manches(game_id, kind);

-- =================================================================
-- 2) _apply_balances_for_manche : ajoute la branche kind=adjustment
-- =================================================================

create or replace function public._apply_balances_for_manche(p_manche_id uuid)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_manche       record;
  v_price        numeric;
  v_seat_to_user jsonb;
  v_board        jsonb;
  v_transfer     jsonb;
  v_winner_seat  int;
  v_winner_user  uuid;
  v_multi        numeric;
  v_final_multi  numeric;
  v_is_split     boolean;
  v_splitter_seats jsonb;
  v_loser_seat   int;
  v_loser_user   uuid;
  v_is_splitter  boolean;
  v_payment      numeric;
  v_fb_seat      int;
  v_fb_user      uuid;
  v_from_seat    int;
  v_to_seat      int;
  v_from_user    uuid;
  v_to_user      uuid;
  v_amount       numeric;
begin
  select * into v_manche from public.manches where id = p_manche_id;
  if not found then return; end if;

  select coalesce(jsonb_object_agg(gp.seat_index, gp.user_id), '{}'::jsonb)
    into v_seat_to_user
    from public.game_participants gp
    where gp.game_id = v_manche.game_id and gp.user_id is not null;

  if jsonb_path_exists(v_seat_to_user, '$.*') is not true then return; end if;
  if (select count(*) from jsonb_object_keys(v_seat_to_user)) < 2 then return; end if;

  -- ===== Branche ADJUSTMENT : itère transfers_json directement =====
  if v_manche.kind = 'adjustment' then
    for v_transfer in select * from jsonb_array_elements(coalesce(v_manche.transfers_json, '[]'::jsonb))
    loop
      v_from_seat := (v_transfer->>'from_seat')::int;
      v_to_seat   := (v_transfer->>'to_seat')::int;
      v_amount    := (v_transfer->>'amount')::numeric;
      v_from_user := nullif(v_seat_to_user->>v_from_seat::text, '')::uuid;
      v_to_user   := nullif(v_seat_to_user->>v_to_seat::text, '')::uuid;
      if v_from_user is null or v_to_user is null or v_amount <= 0 then continue; end if;
      perform public._apply_transfer(v_from_user, v_to_user, v_amount);
    end loop;
    return;
  end if;

  -- ===== Branche NORMAL : logique d'origine =====
  v_price := v_manche.line_price;
  for v_board in select * from jsonb_array_elements(v_manche.board_results)
  loop
    v_winner_seat := nullif(v_board->>'final_winner_seat', '')::int;
    if v_winner_seat is null then continue; end if;
    v_winner_user := nullif(v_seat_to_user->>v_winner_seat::text, '')::uuid;
    if v_winner_user is null then continue; end if;

    v_multi := coalesce((v_board->>'multi')::numeric, 1);
    v_final_multi := coalesce((v_board->>'final_multi')::numeric, v_multi);
    v_is_split := coalesce((v_board->>'is_split')::boolean, false);
    v_splitter_seats := coalesce(v_board->'splitter_seats', '[]'::jsonb);

    for v_loser_seat in select (k::text)::int from jsonb_object_keys(v_seat_to_user) k
    loop
      if v_loser_seat = v_winner_seat then continue; end if;
      v_loser_user := nullif(v_seat_to_user->>v_loser_seat::text, '')::uuid;
      if v_loser_user is null then continue; end if;

      if v_is_split then
        v_is_splitter := v_splitter_seats @> to_jsonb(v_loser_seat);
        v_payment := v_price * (case when v_is_splitter then v_final_multi else 1 end);
      else
        v_payment := v_price * v_multi;
      end if;

      perform public._apply_transfer(v_loser_user, v_winner_user, v_payment);
    end loop;
  end loop;

  -- Full board bonus
  v_fb_seat := v_manche.full_board_seat;
  if v_fb_seat is not null then
    v_fb_user := nullif(v_seat_to_user->>v_fb_seat::text, '')::uuid;
    if v_fb_user is not null then
      for v_loser_seat in select (k::text)::int from jsonb_object_keys(v_seat_to_user) k
      loop
        if v_loser_seat = v_fb_seat then continue; end if;
        v_loser_user := nullif(v_seat_to_user->>v_loser_seat::text, '')::uuid;
        if v_loser_user is null then continue; end if;
        perform public._apply_transfer(v_loser_user, v_fb_user, v_price);
      end loop;
    end if;
  end if;
end;
$$;

-- =================================================================
-- 3) _revert_balances_for_manche : applique l'inverse
-- =================================================================

create or replace function public._revert_balances_for_manche(p_manche_id uuid)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_manche       record;
  v_price        numeric;
  v_seat_to_user jsonb;
  v_board        jsonb;
  v_transfer     jsonb;
  v_winner_seat  int;
  v_winner_user  uuid;
  v_multi        numeric;
  v_final_multi  numeric;
  v_is_split     boolean;
  v_splitter_seats jsonb;
  v_loser_seat   int;
  v_loser_user   uuid;
  v_is_splitter  boolean;
  v_payment      numeric;
  v_fb_seat      int;
  v_fb_user      uuid;
  v_from_seat    int;
  v_to_seat      int;
  v_from_user    uuid;
  v_to_user      uuid;
  v_amount       numeric;
begin
  select * into v_manche from public.manches where id = p_manche_id;
  if not found then return; end if;

  select coalesce(jsonb_object_agg(gp.seat_index, gp.user_id), '{}'::jsonb)
    into v_seat_to_user
    from public.game_participants gp
    where gp.game_id = v_manche.game_id and gp.user_id is not null;

  if jsonb_path_exists(v_seat_to_user, '$.*') is not true then return; end if;

  if v_manche.kind = 'adjustment' then
    for v_transfer in select * from jsonb_array_elements(coalesce(v_manche.transfers_json, '[]'::jsonb))
    loop
      v_from_seat := (v_transfer->>'from_seat')::int;
      v_to_seat   := (v_transfer->>'to_seat')::int;
      v_amount    := (v_transfer->>'amount')::numeric;
      v_from_user := nullif(v_seat_to_user->>v_from_seat::text, '')::uuid;
      v_to_user   := nullif(v_seat_to_user->>v_to_seat::text, '')::uuid;
      if v_from_user is null or v_to_user is null or v_amount <= 0 then continue; end if;
      -- INVERSE : payeur ↔ payee
      perform public._apply_transfer(v_to_user, v_from_user, v_amount);
    end loop;
    return;
  end if;

  v_price := v_manche.line_price;
  for v_board in select * from jsonb_array_elements(v_manche.board_results)
  loop
    v_winner_seat := nullif(v_board->>'final_winner_seat', '')::int;
    if v_winner_seat is null then continue; end if;
    v_winner_user := nullif(v_seat_to_user->>v_winner_seat::text, '')::uuid;
    if v_winner_user is null then continue; end if;

    v_multi := coalesce((v_board->>'multi')::numeric, 1);
    v_final_multi := coalesce((v_board->>'final_multi')::numeric, v_multi);
    v_is_split := coalesce((v_board->>'is_split')::boolean, false);
    v_splitter_seats := coalesce(v_board->'splitter_seats', '[]'::jsonb);

    for v_loser_seat in select (k::text)::int from jsonb_object_keys(v_seat_to_user) k
    loop
      if v_loser_seat = v_winner_seat then continue; end if;
      v_loser_user := nullif(v_seat_to_user->>v_loser_seat::text, '')::uuid;
      if v_loser_user is null then continue; end if;

      if v_is_split then
        v_is_splitter := v_splitter_seats @> to_jsonb(v_loser_seat);
        v_payment := v_price * (case when v_is_splitter then v_final_multi else 1 end);
      else
        v_payment := v_price * v_multi;
      end if;

      -- INVERSE : winner devient payeur du loser
      perform public._apply_transfer(v_winner_user, v_loser_user, v_payment);
    end loop;
  end loop;

  v_fb_seat := v_manche.full_board_seat;
  if v_fb_seat is not null then
    v_fb_user := nullif(v_seat_to_user->>v_fb_seat::text, '')::uuid;
    if v_fb_user is not null then
      for v_loser_seat in select (k::text)::int from jsonb_object_keys(v_seat_to_user) k
      loop
        if v_loser_seat = v_fb_seat then continue; end if;
        v_loser_user := nullif(v_seat_to_user->>v_loser_seat::text, '')::uuid;
        if v_loser_user is null then continue; end if;
        perform public._apply_transfer(v_fb_user, v_loser_user, v_price);
      end loop;
    end if;
  end if;
end;
$$;

revoke all on function public._revert_balances_for_manche from public;

-- =================================================================
-- 4) update_online_manche : owner only, revert + update + apply
-- =================================================================

create or replace function public.update_online_manche(
  p_manche_id        uuid,
  p_board_results    jsonb,
  p_full_board_seat  int,
  p_results_per_seat jsonb
)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_caller  uuid := auth.uid();
  v_game_id uuid;
  r         jsonb;
begin
  if v_caller is null then raise exception 'Not authenticated'; end if;

  select game_id into v_game_id from public.manches where id = p_manche_id;
  if v_game_id is null then raise exception 'Manche not found'; end if;

  -- Owner only
  if not exists (select 1 from public.games where id = v_game_id and owner_user_id = v_caller) then
    raise exception 'Only the game owner can edit a manche';
  end if;

  -- 1) Revert old balances
  perform public._revert_balances_for_manche(p_manche_id);

  -- 2) Update manche record + manche_results
  update public.manches
     set board_results   = p_board_results,
         full_board_seat = p_full_board_seat
   where id = p_manche_id;

  delete from public.manche_results where manche_id = p_manche_id;
  for r in select * from jsonb_array_elements(p_results_per_seat) loop
    insert into public.manche_results (manche_id, seat_index, delta, boards_won_json)
    values (
      p_manche_id,
      (r->>'seat_index')::int,
      (r->>'delta')::numeric,
      coalesce(r->'boards_won_json', '[]'::jsonb)
    );
  end loop;

  -- 3) Apply new balances
  perform public._apply_balances_for_manche(p_manche_id);
end;
$$;

revoke all on function public.update_online_manche from public;
grant execute on function public.update_online_manche to authenticated;

-- =================================================================
-- 5) record_online_adjustment : owner only, insère un manche kind=adjustment
-- =================================================================

create or replace function public.record_online_adjustment(
  p_game_id          uuid,
  p_transfers        jsonb,            -- [{from_seat, to_seat, amount}, ...]
  p_results_per_seat jsonb             -- [{seat_index, delta, boards_won_json}, ...]
)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_caller    uuid := auth.uid();
  v_manche_id uuid;
  v_next_num  int;
  v_price     numeric;
  v_num_active int;
  r           jsonb;
begin
  if v_caller is null then raise exception 'Not authenticated'; end if;

  if not exists (select 1 from public.games where id = p_game_id and owner_user_id = v_caller) then
    raise exception 'Only the game owner can record an adjustment';
  end if;

  -- Récupère line_price + nb participants pour cohérence des colonnes NOT NULL
  select line_price into v_price from public.games where id = p_game_id;
  select count(*) into v_num_active from public.game_participants where game_id = p_game_id;

  -- Numéro négatif unique pour ne pas heurter la séquence des manches normales.
  select coalesce(min(manche_number), 0) - 1 into v_next_num
    from public.manches
   where game_id = p_game_id and kind = 'adjustment';
  if v_next_num >= 0 then v_next_num := -1; end if;

  insert into public.manches (
    game_id, manche_number, dealer_seat, line_price, num_active,
    board_results, full_board_seat, kind, transfers_json
  )
  values (
    p_game_id, v_next_num, 0, v_price, v_num_active,
    '[]'::jsonb, null, 'adjustment', coalesce(p_transfers, '[]'::jsonb)
  )
  returning id into v_manche_id;

  for r in select * from jsonb_array_elements(p_results_per_seat) loop
    insert into public.manche_results (manche_id, seat_index, delta, boards_won_json)
    values (
      v_manche_id,
      (r->>'seat_index')::int,
      (r->>'delta')::numeric,
      coalesce(r->'boards_won_json', '[]'::jsonb)
    );
  end loop;

  perform public._apply_balances_for_manche(v_manche_id);

  return v_manche_id;
end;
$$;

revoke all on function public.record_online_adjustment from public;
grant execute on function public.record_online_adjustment to authenticated;

-- =================================================================
-- 6) delete_online_manche : owner only, revert + delete (et cascade results)
-- =================================================================

create or replace function public.delete_online_manche(p_manche_id uuid)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_caller uuid := auth.uid();
  v_game_id uuid;
begin
  if v_caller is null then raise exception 'Not authenticated'; end if;
  select game_id into v_game_id from public.manches where id = p_manche_id;
  if v_game_id is null then raise exception 'Manche not found'; end if;
  if not exists (select 1 from public.games where id = v_game_id and owner_user_id = v_caller) then
    raise exception 'Only the game owner can delete a manche';
  end if;

  perform public._revert_balances_for_manche(p_manche_id);
  delete from public.manches where id = p_manche_id;
end;
$$;

revoke all on function public.delete_online_manche from public;
grant execute on function public.delete_online_manche to authenticated;
