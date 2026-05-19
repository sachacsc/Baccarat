-- Refonte du modèle de "leave" pour le rendre soft-delete + asymétrique.
--
-- Quand un user fait "Remove" sur une game, on veut :
--   * Ne PAS supprimer la game de la DB.
--   * Que MON solde aggregé soit recalculé comme si je n'avais pas joué.
--   * Que les AUTRES joueurs continuent à voir leur dette avec moi
--     (Bob doit toujours pouvoir cocher "Sacha m'a payé" plus tard).
--   * Que la game disparaisse de MES listes (historique + dettes).
--
-- Avant : leave_game appelait _apply_transfer (bilatéral), donc le côté
-- de Bob était aussi reverté → Bob ne voyait plus sa dette. Et l'owner
-- partant orphanait le game.
--
-- Maintenant :
--   * Nouvelle table user_hidden_games(user_id, game_id) — flag de
--     visibilité, requêté par SessionsService et DebtsService.
--   * Nouveau helper _apply_transfer_unilateral qui ne touche QU'UNE
--     ligne de la paire (mon côté).
--   * _revert_my_balances_in_manche utilise l'unilatéral.
--   * leave_game : revert MON solde + insert hidden row + GARDE
--     settlements + N'ORPHANE PLUS la game.
--   * record_online_adjustment : relaxé (n'importe quel participant peut
--     appeler) avec contrainte que tous les transferts impliquent le
--     caller (sinon je pourrais ajuster les dettes d'autres joueurs).

-- =================================================================
-- 1) Table user_hidden_games
-- =================================================================

create table if not exists public.user_hidden_games (
  user_id   uuid not null references auth.users(id) on delete cascade,
  game_id   uuid not null references public.games(id)  on delete cascade,
  hidden_at timestamptz not null default now(),
  primary key (user_id, game_id)
);

alter table public.user_hidden_games enable row level security;

drop policy if exists "users see their own hidden rows"  on public.user_hidden_games;
drop policy if exists "users hide own"                   on public.user_hidden_games;
drop policy if exists "users unhide own"                 on public.user_hidden_games;

create policy "users see their own hidden rows"
  on public.user_hidden_games for select
  to authenticated
  using (user_id = auth.uid());

create policy "users hide own"
  on public.user_hidden_games for insert
  to authenticated
  with check (user_id = auth.uid());

create policy "users unhide own"
  on public.user_hidden_games for delete
  to authenticated
  using (user_id = auth.uid());

-- =================================================================
-- 2) _apply_transfer_unilateral : ne modifie QU'UNE direction
-- =================================================================

create or replace function public._apply_transfer_unilateral(
  p_user uuid, p_other uuid, p_delta numeric
)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if p_user is null or p_other is null or p_user = p_other or p_delta = 0 then return; end if;

  insert into public.balances (user_id, other_user_id, amount)
  values (p_user, p_other, p_delta)
  on conflict (user_id, other_user_id) do update
    set amount = public.balances.amount + p_delta,
        updated_at = now();
end;
$$;

revoke all on function public._apply_transfer_unilateral from public;

-- =================================================================
-- 3) _revert_my_balances_in_manche : passe en asymétrique
-- =================================================================
-- Remplace les appels à _apply_transfer (bilateral) par
-- _apply_transfer_unilateral pour ne toucher QUE mon côté du ledger.
--
-- Pour chaque transfert (payer, payee, amount) m'impliquant :
--   * Si j'étais payer : ma balance avec payee remonte (mon -amount à
--     l'origine devient +amount maintenant).
--   * Si j'étais payee : ma balance avec payer baisse (mon +amount
--     devient -amount).

create or replace function public._revert_my_balances_in_manche(
  p_manche_id uuid,
  p_user_id   uuid
)
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

  -- ===== Branche ADJUSTMENT =====
  if v_manche.kind = 'adjustment' then
    for v_transfer in select * from jsonb_array_elements(coalesce(v_manche.transfers_json, '[]'::jsonb))
    loop
      v_from_seat := (v_transfer->>'from_seat')::int;
      v_to_seat   := (v_transfer->>'to_seat')::int;
      v_amount    := (v_transfer->>'amount')::numeric;
      v_from_user := nullif(v_seat_to_user->>v_from_seat::text, '')::uuid;
      v_to_user   := nullif(v_seat_to_user->>v_to_seat::text, '')::uuid;
      if v_amount <= 0 then continue; end if;

      -- À la création, _apply_transfer fait :
      --   balances[from][to] -= amount
      --   balances[to][from] += amount
      -- Pour annuler MON côté seulement :
      if v_from_user = p_user_id then
        -- J'étais payer → mon balances[me][to] doit remonter de +amount
        perform public._apply_transfer_unilateral(p_user_id, v_to_user, v_amount);
      elsif v_to_user = p_user_id then
        -- J'étais payee → mon balances[me][from] doit baisser de -amount
        perform public._apply_transfer_unilateral(p_user_id, v_from_user, -v_amount);
      end if;
    end loop;
    return;
  end if;

  -- ===== Branche NORMAL =====
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

      -- À la création, _apply_transfer(loser, winner, payment) fait :
      --   balances[loser][winner] -= payment
      --   balances[winner][loser] += payment
      -- Annuler MON côté :
      if v_loser_user = p_user_id then
        -- J'étais loser → balances[me][winner] += payment
        perform public._apply_transfer_unilateral(p_user_id, v_winner_user, v_payment);
      elsif v_winner_user = p_user_id then
        -- J'étais winner → balances[me][loser] -= payment
        perform public._apply_transfer_unilateral(p_user_id, v_loser_user, -v_payment);
      end if;
    end loop;
  end loop;

  -- Full board bonus : symétrique à _apply_balances_for_manche
  v_fb_seat := v_manche.full_board_seat;
  if v_fb_seat is not null then
    v_fb_user := nullif(v_seat_to_user->>v_fb_seat::text, '')::uuid;
    if v_fb_user is not null then
      for v_loser_seat in select (k::text)::int from jsonb_object_keys(v_seat_to_user) k
      loop
        if v_loser_seat = v_fb_seat then continue; end if;
        v_loser_user := nullif(v_seat_to_user->>v_loser_seat::text, '')::uuid;
        if v_loser_user is null then continue; end if;
        if v_loser_user = p_user_id then
          perform public._apply_transfer_unilateral(p_user_id, v_fb_user, v_price);
        elsif v_fb_user = p_user_id then
          perform public._apply_transfer_unilateral(p_user_id, v_loser_user, -v_price);
        end if;
      end loop;
    end if;
  end if;
end;
$$;

-- =================================================================
-- 4) leave_game : asymétrique + soft-delete (hide row) + keep settlements
-- =================================================================

create or replace function public.leave_game(p_game_id uuid)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_me        uuid := auth.uid();
  v_manche_id uuid;
begin
  if v_me is null then raise exception 'Not authenticated'; end if;

  -- Caller doit être (ou avoir été) participant.
  if not exists (
    select 1 from public.game_participants
    where game_id = p_game_id and user_id = v_me
  ) then
    raise exception 'You are not a participant of this game';
  end if;

  -- 1) Revert MON côté des balances (unilatéral, ne touche pas les
  --    autres). Les autres joueurs continuent à voir leur dette avec
  --    moi → ils peuvent toujours marquer "payé" via settlements.
  for v_manche_id in select id from public.manches where game_id = p_game_id loop
    perform public._revert_my_balances_in_manche(v_manche_id, v_me);
  end loop;

  -- 2) Soft-delete : ajoute une row dans user_hidden_games pour me
  --    cacher la game du Historique + Dettes côté iOS.
  insert into public.user_hidden_games (user_id, game_id)
  values (v_me, p_game_id)
  on conflict do nothing;

  -- 3) GARDE settlements (Bob peut toujours marquer payé de son côté).
  -- 4) GARDE game_participants (mon nom reste dans la liste des autres).
  -- 5) GARDE owner_user_id (plus d'orphan ; si j'étais owner et veux
  --    revenir, je peux unhide ; sinon je peux toujours éditer).
end;
$$;

revoke all on function public.leave_game from public;
grant execute on function public.leave_game to authenticated;

-- =================================================================
-- 5) unhide_game : rétablit la visibilité (utile si partagé via code)
-- =================================================================

create or replace function public.unhide_game(p_game_id uuid)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_me uuid := auth.uid();
begin
  if v_me is null then raise exception 'Not authenticated'; end if;
  delete from public.user_hidden_games
   where user_id = v_me and game_id = p_game_id;
  -- Note : on ne ré-applique pas les balances. Si l'user veut récupérer
  -- ses soldes d'origine, on devra ajouter ça (non MVP).
end;
$$;

revoke all on function public.unhide_game from public;
grant execute on function public.unhide_game to authenticated;

-- =================================================================
-- 6) Relax record_online_adjustment : tout participant + contrainte
--    "transferts m'impliquent forcément"
-- =================================================================
--
-- Permet aux non-owners (cas notamment des vieux comptes où ownership
-- est ambigu) d'ajuster leurs soldes — mais SEULEMENT pour des transferts
-- les impliquant. Un guest ne peut pas modifier la dette de Bob vs Carol.

create or replace function public.record_online_adjustment(
  p_game_id          uuid,
  p_transfers        jsonb,
  p_results_per_seat jsonb
)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_caller     uuid := auth.uid();
  v_manche_id  uuid;
  v_next_num   int;
  v_price      numeric;
  v_num_active int;
  v_my_seat    int;
  v_transfer   jsonb;
  v_from_seat  int;
  v_to_seat    int;
  r            jsonb;
begin
  if v_caller is null then raise exception 'Not authenticated'; end if;

  -- Caller doit être participant (au lieu de owner)
  select seat_index into v_my_seat
    from public.game_participants
   where game_id = p_game_id and user_id = v_caller
   limit 1;
  if v_my_seat is null then
    raise exception 'Only participants of this game can record an adjustment';
  end if;

  -- Tous les transferts doivent impliquer le caller (sinon je modifie
  -- les dettes d'autres joueurs sans leur consentement).
  for v_transfer in select * from jsonb_array_elements(coalesce(p_transfers, '[]'::jsonb))
  loop
    v_from_seat := (v_transfer->>'from_seat')::int;
    v_to_seat   := (v_transfer->>'to_seat')::int;
    if v_from_seat <> v_my_seat and v_to_seat <> v_my_seat then
      raise exception 'Adjustments must involve your own seat';
    end if;
  end loop;

  select line_price into v_price from public.games where id = p_game_id;
  select count(*) into v_num_active from public.game_participants where game_id = p_game_id;

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
