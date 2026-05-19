-- Supprimer un game / le quitter depuis l'onglet Comptes.
--
-- delete_game : owner only. Supprime le game ET tout ce qui en dépend
--   (game_participants, manches, manche_results, game_pair_settlements)
--   via les FK CASCADE déjà en place.
--
-- leave_game  : participant non-owner. Retire le caller comme participant
--   et supprime ses lignes de game_pair_settlements pour ce game. La game
--   reste vivante pour les autres joueurs.

create or replace function public.delete_game(p_game_id uuid)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_me uuid := auth.uid();
begin
  if v_me is null then raise exception 'Not authenticated'; end if;

  if not exists (
    select 1 from public.games
    where id = p_game_id and owner_user_id = v_me
  ) then
    raise exception 'Only the game owner can delete this game';
  end if;

  -- FK cascade fait le reste (game_participants, manches, manche_results,
  -- game_pair_settlements via on delete cascade sur game_id).
  delete from public.games where id = p_game_id;
end;
$$;

grant execute on function public.delete_game to authenticated;
revoke all on function public.delete_game from public;

create or replace function public.leave_game(p_game_id uuid)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_me uuid := auth.uid();
begin
  if v_me is null then raise exception 'Not authenticated'; end if;

  -- Owner ne quitte pas son propre game (il doit delete à la place).
  if exists (
    select 1 from public.games
    where id = p_game_id and owner_user_id = v_me
  ) then
    raise exception 'Owners cannot leave their own game (use delete instead)';
  end if;

  -- Caller doit être participant.
  if not exists (
    select 1 from public.game_participants
    where game_id = p_game_id and user_id = v_me
  ) then
    raise exception 'You are not a participant of this game';
  end if;

  -- Retire le user_id du seat (le seat redevient libre, le label guest_name
  -- ou placeholder_id éventuel reste).
  update public.game_participants
     set user_id = null
   where game_id = p_game_id and user_id = v_me;

  -- Supprime les settlements qui m'impliquent dans ce game.
  delete from public.game_pair_settlements
   where game_id = p_game_id
     and (user_a = v_me or user_b = v_me);
end;
$$;

grant execute on function public.leave_game to authenticated;
revoke all on function public.leave_game from public;
