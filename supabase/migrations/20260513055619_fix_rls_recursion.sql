-- Fix : les policies de games <-> game_participants se référencent mutuellement,
-- causant une récursion infinie ("infinite recursion detected in policy for relation").
--
-- Solution : une fonction SECURITY DEFINER qui renvoie l'ensemble des game_ids
-- accessibles à l'utilisateur courant. La fonction tourne avec les droits de son
-- propriétaire, donc bypasse RLS lorsqu'elle requête games/game_participants en interne.
-- Les policies utilisent ensuite "game_id in (select my_game_ids())" sans recursion.

create or replace function public.my_game_ids()
returns setof uuid
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  -- Games dont je suis owner
  select g.id from public.games g where g.owner_user_id = auth.uid()
  union
  -- Games où je suis listé comme participant loggué
  select gp.game_id from public.game_participants gp where gp.user_id = auth.uid()
$$;

revoke all on function public.my_game_ids from public;
grant execute on function public.my_game_ids to authenticated, anon;

-- Drop les anciennes policies récursives
drop policy if exists "games visible to owner or participants"             on public.games;
drop policy if exists "game_participants visible to owner or participants" on public.game_participants;
drop policy if exists "manches visible to participants"                    on public.manches;
drop policy if exists "manche_results visible to participants"             on public.manche_results;

-- Nouvelles policies non récursives
create policy "games visible to owner or participants"
  on public.games for select
  using (id in (select public.my_game_ids()));

create policy "game_participants visible to participants"
  on public.game_participants for select
  using (game_id in (select public.my_game_ids()));

create policy "manches visible to participants"
  on public.manches for select
  using (game_id in (select public.my_game_ids()));

create policy "manche_results visible to participants"
  on public.manche_results for select
  using (
    manche_id in (
      select m.id from public.manches m where m.game_id in (select public.my_game_ids())
    )
  );
