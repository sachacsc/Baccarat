-- Permet à un user de DÉPLACER son siège : si claim_seat est appelée alors
-- qu'il occupe déjà un autre siège dans le même game, on libère l'ancien
-- avant de prendre le nouveau (au lieu de raise exception).
--
-- Use case réel : l'auto-bind du host à la 1ère manche compteur tombe sur
-- seat 0 par défaut. Si l'utilisateur n'était pas seat 0, il doit pouvoir
-- corriger sans devoir d'abord taper un "Ce n'est pas moi" séparé.

create or replace function public.claim_seat(
  p_share_code text,
  p_seat_index int
)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_me      uuid := auth.uid();
  v_game_id uuid;
begin
  if v_me is null then
    raise exception 'Not authenticated';
  end if;

  select id into v_game_id from public.games where share_code = p_share_code;
  if v_game_id is null then
    raise exception 'Invalid share code';
  end if;

  -- Si je suis déjà sur le seat ciblé, no-op.
  if exists (
    select 1 from public.game_participants
     where game_id = v_game_id and seat_index = p_seat_index
       and user_id = v_me
  ) then
    return v_game_id;
  end if;

  -- Le seat ciblé doit être libre (pas occupé par un AUTRE user).
  if not exists (
    select 1 from public.game_participants
     where game_id = v_game_id and seat_index = p_seat_index
       and user_id is null
  ) then
    raise exception 'Seat not available';
  end if;

  -- Libère mon ancien seat dans ce game (si existant).
  update public.game_participants
     set user_id = null
   where game_id = v_game_id and user_id = v_me;

  update public.game_participants
     set user_id = v_me
   where game_id = v_game_id and seat_index = p_seat_index;

  return v_game_id;
end;
$$;

grant execute on function public.claim_seat to authenticated;
revoke all on function public.claim_seat from public;
