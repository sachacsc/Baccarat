-- Quitter une game (online ou compteur partagé) doit IMPACTER UNIQUEMENT
-- le solde du caller, sans toucher les balances entre les autres joueurs.
--
-- Avant cette migration :
--   * leave_game (non-owner) : unlink + delete settlements, mais les
--     balances pairwise restaient en place — l'utilisateur continuait
--     à voir ses dettes avec d'autres comme si rien n'avait changé.
--   * delete_game (owner only) : cascade tout, ce qui supprime le game
--     pour tout le monde — pas du tout ce qu'on veut.
--
-- Après :
--   * Ajoute _revert_my_balances_in_manche(p_manche_id, p_user_id) qui
--     itère les transferts d'une manche mais n'applique l'inverse que
--     pour les paires impliquant p_user_id.
--   * leave_game iter ses manches et appelle ce helper → mes deltas
--     pairwise sont reset à zéro côté manche par manche. Les balances
--     entre les autres joueurs restent intactes.
--   * leave_game accepte maintenant l'owner aussi. Si je suis owner,
--     owner_user_id passe à NULL → personne ne peut plus éditer les
--     manches mais le game reste accessible aux autres pour leur
--     historique et leurs dettes.
--   * delete_game devient un alias de leave_game (même comportement)
--     pour rester compatible avec les anciens appels iOS.

-- =================================================================
-- 1) Helper : revert MY transfers only inside a manche
-- =================================================================

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

  -- Snapshot seats → user_id, en INCLUANT le caller même s'il a été
  -- détaché : on lit l'état actuel de game_participants, mais le caller
  -- a peut-être déjà été nullé. Donc on injecte le caller via les
  -- balances existantes : si _apply_transfer a été appelé pour cette
  -- paire à la création, on retrouve le seat du caller.
  --
  -- Approche plus robuste : faire le revert AVANT d'unlink le caller.
  -- C'est exactement ce que fait leave_game (cf. ci-dessous), donc on
  -- compte sur cet ordre.
  select coalesce(jsonb_object_agg(gp.seat_index, gp.user_id), '{}'::jsonb)
    into v_seat_to_user
    from public.game_participants gp
    where gp.game_id = v_manche.game_id and gp.user_id is not null;

  if jsonb_path_exists(v_seat_to_user, '$.*') is not true then return; end if;

  -- ===== Branche ADJUSTMENT : itère transfers_json =====
  if v_manche.kind = 'adjustment' then
    for v_transfer in select * from jsonb_array_elements(coalesce(v_manche.transfers_json, '[]'::jsonb))
    loop
      v_from_seat := (v_transfer->>'from_seat')::int;
      v_to_seat   := (v_transfer->>'to_seat')::int;
      v_amount    := (v_transfer->>'amount')::numeric;
      v_from_user := nullif(v_seat_to_user->>v_from_seat::text, '')::uuid;
      v_to_user   := nullif(v_seat_to_user->>v_to_seat::text, '')::uuid;
      if v_from_user is null or v_to_user is null or v_amount <= 0 then continue; end if;
      if v_from_user = p_user_id or v_to_user = p_user_id then
        -- Inverse uniquement si je suis dans la paire
        perform public._apply_transfer(v_to_user, v_from_user, v_amount);
      end if;
    end loop;
    return;
  end if;

  -- ===== Branche NORMAL : itère board_results =====
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

      if v_loser_user = p_user_id or v_winner_user = p_user_id then
        -- Inverse uniquement si je suis dans la paire
        perform public._apply_transfer(v_winner_user, v_loser_user, v_payment);
      end if;
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
        if v_loser_user = p_user_id or v_fb_user = p_user_id then
          perform public._apply_transfer(v_fb_user, v_loser_user, v_price);
        end if;
      end loop;
    end if;
  end if;
end;
$$;

revoke all on function public._revert_my_balances_in_manche from public;

-- =================================================================
-- 2) leave_game : owner+non-owner, revert my balances, orphan if owner
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
  v_was_owner boolean := false;
begin
  if v_me is null then raise exception 'Not authenticated'; end if;

  -- Caller doit être participant
  if not exists (
    select 1 from public.game_participants
    where game_id = p_game_id and user_id = v_me
  ) then
    raise exception 'You are not a participant of this game';
  end if;

  -- 1) Revert mes contributions aux balances manche par manche AVANT
  --    d'unlink (le revert utilise game_participants pour mapper seat → user).
  for v_manche_id in select id from public.manches where game_id = p_game_id loop
    perform public._revert_my_balances_in_manche(v_manche_id, v_me);
  end loop;

  -- 2) Détache moi des seats (le seat reste, juste user_id = null)
  update public.game_participants
     set user_id = null
   where game_id = p_game_id and user_id = v_me;

  -- 3) Supprime mes settlements pour ce game
  delete from public.game_pair_settlements
   where game_id = p_game_id
     and (user_a = v_me or user_b = v_me);

  -- 4) Si j'étais owner, orphan le game (owner_user_id = null).
  --    Personne ne peut plus éditer les manches mais le game reste
  --    visible aux autres participants.
  update public.games
     set owner_user_id = null
   where id = p_game_id and owner_user_id = v_me
   returning true into v_was_owner;
end;
$$;

revoke all on function public.leave_game from public;
grant execute on function public.leave_game to authenticated;

-- =================================================================
-- 3) delete_game devient un alias de leave_game
-- =================================================================
--
-- Avant : delete_game faisait un cascade delete (game + tout) — pas du
-- tout l'attente utilisateur. On le redirige vers leave_game pour
-- garder le contrat existant côté iOS sans le supprimer.

create or replace function public.delete_game(p_game_id uuid)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  perform public.leave_game(p_game_id);
end;
$$;

revoke all on function public.delete_game from public;
grant execute on function public.delete_game to authenticated;
