-- Partage de compteur ("Tricount-style"). Le créateur tape des noms de joueurs,
-- l'app génère un share_code court. Les autres utilisateurs entrent ce code
-- (ou cliquent un lien), choisissent leur siège dans la liste, et leur user_id
-- vient s'attacher au seat existant — sans perdre le label original tapé par
-- l'hôte (utile pour que tout le monde s'y retrouve même si les display_name
-- diffèrent).
--
-- Trois changements clés :
--   1. game_participants : on relâche la contrainte d'exclusivité user_id /
--      guest_name. Un seat peut avoir LES DEUX : user_id (compte revendiqué)
--      et guest_name (étiquette d'origine de l'hôte).
--   2. games : nouvelle colonne share_code text unique, générée à la demande
--      via la RPC `get_or_create_share_code`.
--   3. RPCs : claim_seat / unclaim_seat / lookup_share_code, avec validation
--      de l'unicité (un user = un seat max par game).
--
-- Compte temporaire : on bascule `enable_anonymous_sign_ins = true` côté
-- config.toml (déjà fait). Le trigger `handle_new_user` est mis à jour pour
-- générer un display_name lisible pour ces comptes (pas d'email).

-- ===== 1. Relax la contrainte user_id <-> guest_name sur game_participants =====
alter table public.game_participants
  drop constraint participant_identity;

alter table public.game_participants
  add constraint participant_has_identity check (
    user_id is not null or guest_name is not null
  );

-- Un même user ne peut revendiquer qu'UN seul siège par game.
create unique index if not exists game_participants_unique_user_per_game
  on public.game_participants(game_id, user_id)
  where user_id is not null;

-- ===== 2. Colonne share_code sur games =====
alter table public.games add column if not exists share_code text;
create unique index if not exists games_share_code_uniq
  on public.games(share_code)
  where share_code is not null;

-- Générateur de codes lisibles : 6 caractères alphanumériques, sans 0/O/1/I/L
-- (caractères ambigus à l'oeil). Format affiché côté client : "ABC-XYZ"
-- (purement cosmétique, le format stocké est sans tiret).
create or replace function public._generate_share_code()
returns text
language plpgsql
volatile
as $$
declare
  v_alphabet text := 'ABCDEFGHJKMNPQRSTUVWXYZ23456789';  -- 31 chars
  v_code text;
  v_i int;
  v_attempts int := 0;
begin
  loop
    v_code := '';
    for v_i in 1..6 loop
      v_code := v_code || substr(v_alphabet, 1 + floor(random() * length(v_alphabet))::int, 1);
    end loop;
    -- Boucle jusqu'à trouver un code non collidé (probabilité de collision
    -- négligeable avec 31^6 ≈ 887M combinaisons).
    exit when not exists (select 1 from public.games where share_code = v_code);
    v_attempts := v_attempts + 1;
    if v_attempts > 10 then
      raise exception 'Unable to generate unique share code after 10 attempts';
    end if;
  end loop;
  return v_code;
end;
$$;

revoke all on function public._generate_share_code from public;

-- ===== 3. RPC : get_or_create_share_code =====
-- Réservé à l'owner du game. Génère un code la première fois, le retourne
-- les fois suivantes. Idempotent.
create or replace function public.get_or_create_share_code(p_game_id uuid)
returns text
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_me      uuid := auth.uid();
  v_owner   uuid;
  v_existing text;
  v_new     text;
begin
  if v_me is null then
    raise exception 'Not authenticated';
  end if;

  select owner_user_id, share_code into v_owner, v_existing
    from public.games where id = p_game_id;

  if v_owner is null then
    raise exception 'Game not found';
  end if;
  if v_owner <> v_me then
    raise exception 'Only the game owner can share';
  end if;

  if v_existing is not null then
    return v_existing;
  end if;

  v_new := public._generate_share_code();
  update public.games set share_code = v_new where id = p_game_id;
  return v_new;
end;
$$;

grant execute on function public.get_or_create_share_code to authenticated;
revoke all on function public.get_or_create_share_code from public;

-- ===== 4. RPC : lookup_share_code =====
-- Retourne les infos publiques d'un game à partir de son code, sans
-- exposer l'historique des manches. Sert à pré-remplir l'écran "Rejoindre".
-- Retourne aussi l'état actuel des seats (claimed ou libre).
--
-- Bypass RLS volontairement : tant que le caller a le code, on l'autorise à
-- voir le game stub. Pas d'info sensible exposée (juste line_price, currency,
-- nom des seats).
create or replace function public.lookup_share_code(p_share_code text)
returns table (
  game_id           uuid,
  mode              text,
  line_price        numeric,
  currency          text,
  owner_display     text,
  created_at        timestamptz,
  seat_index        int,
  guest_name        text,
  claimed_by_user_id uuid,
  claimed_by_display text,
  claimed_by_avatar  text
)
language sql
security definer
set search_path = public, pg_temp
stable
as $$
  select
    g.id           as game_id,
    g.mode         as mode,
    g.line_price   as line_price,
    g.currency     as currency,
    owner_p.display_name as owner_display,
    g.created_at   as created_at,
    gp.seat_index  as seat_index,
    gp.guest_name  as guest_name,
    gp.user_id     as claimed_by_user_id,
    claim_p.display_name as claimed_by_display,
    claim_p.avatar_url   as claimed_by_avatar
  from public.games g
  join public.game_participants gp on gp.game_id = g.id
  left join public.profiles owner_p on owner_p.user_id = g.owner_user_id
  left join public.profiles claim_p on claim_p.user_id = gp.user_id
  where g.share_code = p_share_code
  order by gp.seat_index;
$$;

grant execute on function public.lookup_share_code to authenticated, anon;
revoke all on function public.lookup_share_code from public;

-- ===== 5. RPC : claim_seat =====
-- Le caller revendique le seat (game, seat_index) à partir du share_code.
-- Valide :
--   - le code existe
--   - le seat est libre (user_id is null)
--   - le caller n'a pas déjà un autre seat dans ce game
-- Met à jour la row : user_id = caller, guest_name conservé en label.
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
  v_taken   uuid;
begin
  if v_me is null then
    raise exception 'Not authenticated';
  end if;

  select id into v_game_id from public.games where share_code = p_share_code;
  if v_game_id is null then
    raise exception 'Invalid share code';
  end if;

  -- Le caller a-t-il déjà un seat dans ce game ?
  select user_id into v_taken
    from public.game_participants
   where game_id = v_game_id and user_id = v_me
   limit 1;
  if v_taken is not null then
    raise exception 'You already have a seat in this game';
  end if;

  -- Le seat ciblé doit être libre.
  if not exists (
    select 1 from public.game_participants
     where game_id = v_game_id and seat_index = p_seat_index
       and user_id is null
  ) then
    raise exception 'Seat not available';
  end if;

  update public.game_participants
     set user_id = v_me
   where game_id = v_game_id and seat_index = p_seat_index;

  return v_game_id;
end;
$$;

grant execute on function public.claim_seat to authenticated;
revoke all on function public.claim_seat from public;

-- ===== 6. RPC : unclaim_seat =====
-- Le caller libère le seat qu'il occupe actuellement dans ce game. Le
-- guest_name d'origine reste, le seat redevient libre pour qu'un autre user
-- le revendique.
create or replace function public.unclaim_seat(p_game_id uuid)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_me uuid := auth.uid();
begin
  if v_me is null then
    raise exception 'Not authenticated';
  end if;

  update public.game_participants
     set user_id = null
   where game_id = p_game_id and user_id = v_me;
end;
$$;

grant execute on function public.unclaim_seat to authenticated;
revoke all on function public.unclaim_seat from public;

-- ===== 7. Mise à jour de handle_new_user pour les comptes anonymes =====
-- Anonymes : pas d'email → split_part(null) renvoie ''. On retombe sur un
-- "Invité-XXXX" friendly basé sur les 4 premiers chars de l'UUID.
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.profiles (user_id, display_name)
  values (
    new.id,
    coalesce(
      nullif(trim(new.raw_user_meta_data->>'display_name'), ''),
      nullif(split_part(coalesce(new.email, ''), '@', 1), ''),
      'Invité-' || upper(substr(new.id::text, 1, 4))
    )
  );
  return new;
end;
$$;
