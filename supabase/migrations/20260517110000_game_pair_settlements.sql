-- Onglet "Dettes" : table de marquage bilatéral des soldes réglés, par paire
-- et par partie.
--
-- Modèle : 1 row par (game_id, user_a, user_b) avec user_a < user_b
-- (canonical ordering) → un seul row par paire, quel que soit qui l'a marquée.
-- Quand cette row existe, les DEUX joueurs voient ce game comme "réglé"
-- entre eux (bilateral). C'est ce que l'utilisateur a explicitement demandé :
-- "la ligne de dette est notée payé pour les deux joueurs à partir du moment
--  où l'un d'eux l'a déclaré".
--
-- Writes : uniquement via SECURITY DEFINER RPC (`mark_pair_settled` /
-- `unmark_pair_settled`) afin de valider que les deux users sont bien
-- participants du game avant d'écrire.

create table public.game_pair_settlements (
  game_id     uuid not null references public.games(id) on delete cascade,
  user_a      uuid not null references auth.users(id)  on delete cascade,
  user_b      uuid not null references auth.users(id)  on delete cascade,
  settled_at  timestamptz not null default now(),
  settled_by  uuid not null references auth.users(id),
  primary key (game_id, user_a, user_b),
  check (user_a < user_b)
);

create index gps_user_a_idx on public.game_pair_settlements(user_a);
create index gps_user_b_idx on public.game_pair_settlements(user_b);
create index gps_game_idx   on public.game_pair_settlements(game_id);

alter table public.game_pair_settlements enable row level security;

-- Visible aux deux users de la paire (les autres participants du game ne voient
-- PAS le statut de cette paire spécifique). Suffisant pour le greying côté UI
-- du user concerné.
create policy "gps visible to involved users"
  on public.game_pair_settlements
  for select
  using (user_a = auth.uid() or user_b = auth.uid());

-- Aucune policy INSERT/UPDATE/DELETE pour les rôles authenticated → tout passe
-- par les RPC SECURITY DEFINER ci-dessous.

-- ===== mark_pair_settled =====
-- Le caller marque sa dette/créance avec p_other_user_id sur le game donné
-- comme réglée. C'est bilatéral : l'autre user la verra aussi comme réglée
-- (single source of truth).
create or replace function public.mark_pair_settled(
  p_game_id        uuid,
  p_other_user_id  uuid
)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_me uuid := auth.uid();
  v_a  uuid;
  v_b  uuid;
begin
  if v_me is null then
    raise exception 'Not authenticated';
  end if;
  if p_other_user_id is null or p_other_user_id = v_me then
    raise exception 'Invalid counterparty';
  end if;

  -- Les deux doivent être participants loggés du game.
  if not exists (
    select 1 from public.game_participants
    where game_id = p_game_id and user_id = v_me
  ) then
    raise exception 'Caller is not a participant of this game';
  end if;
  if not exists (
    select 1 from public.game_participants
    where game_id = p_game_id and user_id = p_other_user_id
  ) then
    raise exception 'Counterparty is not a participant of this game';
  end if;

  if v_me < p_other_user_id then
    v_a := v_me; v_b := p_other_user_id;
  else
    v_a := p_other_user_id; v_b := v_me;
  end if;

  insert into public.game_pair_settlements (game_id, user_a, user_b, settled_by)
  values (p_game_id, v_a, v_b, v_me)
  on conflict (game_id, user_a, user_b) do update
    set settled_at = now(), settled_by = v_me;
end;
$$;

grant execute on function public.mark_pair_settled to authenticated;
revoke all on function public.mark_pair_settled from public;

-- ===== unmark_pair_settled =====
-- Annule un marquage. N'importe lequel des deux users peut annuler.
create or replace function public.unmark_pair_settled(
  p_game_id        uuid,
  p_other_user_id  uuid
)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_me uuid := auth.uid();
  v_a  uuid;
  v_b  uuid;
begin
  if v_me is null then
    raise exception 'Not authenticated';
  end if;
  if p_other_user_id is null then return; end if;

  if v_me < p_other_user_id then
    v_a := v_me; v_b := p_other_user_id;
  else
    v_a := p_other_user_id; v_b := v_me;
  end if;

  delete from public.game_pair_settlements
   where game_id = p_game_id and user_a = v_a and user_b = v_b;
end;
$$;

grant execute on function public.unmark_pair_settled to authenticated;
revoke all on function public.unmark_pair_settled from public;

-- Realtime pour rafraîchir les vues Dettes + Historique en temps réel quand
-- l'autre user déclare un règlement.
alter publication supabase_realtime add table public.game_pair_settlements;
