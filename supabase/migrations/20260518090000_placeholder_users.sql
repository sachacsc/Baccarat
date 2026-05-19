-- Placeholders : "comptes fantômes" créés par l'hôte d'un compteur pour les
-- joueurs qui n'ont pas (encore) de compte Bakarat. Permettent au système
-- de Dettes d'exister DÈS la création (l'hôte voit "Tu dois 10€ à Alex"
-- avant même qu'Alex installe l'app).
--
-- Quand le vrai Alex finit par revendiquer son siège via share code, le
-- placeholder est "absorbé" : son UUID est remplacé par l'UUID de l'auth
-- user dans game_participants ET dans game_pair_settlements (transfer des
-- dettes existantes), et `placeholder_users.claimed_by_user_id` est set.
--
-- Note : les placeholders ne sont PAS des auth.users — c'est volontaire,
-- éviter de polluer auth.users avec des comptes "fantômes" gérés par les
-- hôtes. Les FK sur game_participants.user_id et game_pair_settlements
-- doivent donc être détendues pour accepter un UUID placeholder.

-- ===== 1. Table placeholder_users =====
create table public.placeholder_users (
  id                   uuid primary key default gen_random_uuid(),
  display_name         text not null,
  created_by           uuid not null references auth.users(id) on delete cascade,
  claimed_by_user_id   uuid references auth.users(id) on delete set null,
  claimed_at           timestamptz,
  created_at           timestamptz not null default now()
);

create index placeholder_users_created_by_idx on public.placeholder_users(created_by);
create index placeholder_users_claimed_idx on public.placeholder_users(claimed_by_user_id) where claimed_by_user_id is not null;

alter table public.placeholder_users enable row level security;

-- Visible au créateur OU au user qui l'a revendiqué (post-claim, transition).
create policy "placeholders visible to creator or claimer"
  on public.placeholder_users for select
  using (created_by = auth.uid() or claimed_by_user_id = auth.uid());

-- Pas de policy INSERT/UPDATE/DELETE — RPC SECURITY DEFINER only.

-- ===== 2. game_participants : ajout placeholder_id =====
alter table public.game_participants
  add column placeholder_id uuid references public.placeholder_users(id) on delete set null;

create index game_participants_placeholder_idx
  on public.game_participants(placeholder_id)
  where placeholder_id is not null;

-- Relax la contrainte d'identité : au moins un des trois doit être set.
alter table public.game_participants drop constraint participant_has_identity;
alter table public.game_participants add constraint participant_has_identity
  check (user_id is not null or placeholder_id is not null or guest_name is not null);

-- ===== 3. game_pair_settlements : drop FK pour autoriser placeholder UUIDs =====
-- Avant : user_a/user_b avaient FK vers auth.users(id). Avec les placeholders,
-- l'un des deux peut être un placeholder_users.id. On retire les FK et on
-- gère l'intégrité au niveau des RPCs (mark/unmark_pair_settled).
alter table public.game_pair_settlements drop constraint game_pair_settlements_user_a_fkey;
alter table public.game_pair_settlements drop constraint game_pair_settlements_user_b_fkey;

-- RLS étendue : créateur de placeholder voit aussi les settlements impliquant
-- ses placeholders.
drop policy "gps visible to involved users" on public.game_pair_settlements;
create policy "gps visible to involved users or placeholder creator"
  on public.game_pair_settlements for select
  using (
    user_a = auth.uid()
    or user_b = auth.uid()
    or exists (
      select 1 from public.placeholder_users p
      where p.id in (user_a, user_b) and p.created_by = auth.uid()
    )
  );

-- ===== 4. RPC create_placeholder_user =====
create or replace function public.create_placeholder_user(p_display_name text)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_me uuid := auth.uid();
  v_id uuid;
begin
  if v_me is null then raise exception 'Not authenticated'; end if;
  if p_display_name is null or length(trim(p_display_name)) = 0 then
    raise exception 'display_name required';
  end if;
  insert into public.placeholder_users (display_name, created_by)
  values (trim(p_display_name), v_me)
  returning id into v_id;
  return v_id;
end;
$$;

grant execute on function public.create_placeholder_user to authenticated;
revoke all on function public.create_placeholder_user from public;

-- ===== 5. record_manche : accepter placeholder_id dans participants =====
-- On remplace la fonction existante (init_balances.sql) en ajoutant la
-- gestion de placeholder_id côté insert game_participants.
create or replace function public.record_manche(
  p_game_id        uuid,
  p_mode           text,
  p_line_price     numeric,
  p_currency       text,
  p_settings_json  jsonb,
  p_participants   jsonb,
  p_manche_number  int,
  p_dealer_seat    int,
  p_num_active     int,
  p_board_results  jsonb,
  p_full_board_seat int,
  p_results_per_seat jsonb
)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_game_id   uuid := p_game_id;
  v_manche_id uuid;
  v_caller    uuid := auth.uid();
  p           jsonb;
  r           jsonb;
begin
  if v_caller is null then
    raise exception 'Not authenticated';
  end if;

  if v_game_id is null then
    insert into public.games (owner_user_id, mode, line_price, currency, settings_json)
    values (v_caller, p_mode, p_line_price, p_currency, coalesce(p_settings_json, '{}'::jsonb))
    returning id into v_game_id;

    for p in select * from jsonb_array_elements(p_participants) loop
      insert into public.game_participants (game_id, seat_index, user_id, placeholder_id, guest_name)
      values (
        v_game_id,
        (p->>'seat_index')::int,
        nullif(p->>'user_id','')::uuid,
        nullif(p->>'placeholder_id','')::uuid,
        nullif(p->>'guest_name','')
      );
    end loop;
  else
    if not exists (select 1 from public.games where id = v_game_id and owner_user_id = v_caller) then
      raise exception 'Game not found or unauthorized';
    end if;
  end if;

  insert into public.manches (game_id, manche_number, dealer_seat, line_price, num_active, board_results, full_board_seat)
  values (v_game_id, p_manche_number, p_dealer_seat, p_line_price, p_num_active, p_board_results, p_full_board_seat)
  on conflict (game_id, manche_number) do nothing
  returning id into v_manche_id;

  if v_manche_id is null then
    return v_game_id;
  end if;

  for r in select * from jsonb_array_elements(p_results_per_seat) loop
    insert into public.manche_results (manche_id, seat_index, delta, boards_won_json)
    values (
      v_manche_id,
      (r->>'seat_index')::int,
      (r->>'delta')::numeric,
      coalesce(r->'boards_won_json', '[]'::jsonb)
    );
  end loop;

  -- _apply_balances_for_manche : on garde l'appel pour le legacy ledger.
  -- N'affecte plus les Dettes (qui sont recalculées on-the-fly côté client)
  -- mais entretient la table balances pour rétrocompat éventuelle.
  perform public._apply_balances_for_manche(v_manche_id);

  return v_game_id;
end;
$$;

-- ===== 6. mark_pair_settled : accepter placeholder otherUserId =====
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
  if v_me is null then raise exception 'Not authenticated'; end if;
  if p_other_user_id is null or p_other_user_id = v_me then
    raise exception 'Invalid counterparty';
  end if;

  if not exists (
    select 1 from public.game_participants
    where game_id = p_game_id and user_id = v_me
  ) then
    raise exception 'Caller is not a participant of this game';
  end if;

  -- L'autre peut être un user_id réel OU un placeholder_id que j'ai créé.
  if not exists (
    select 1 from public.game_participants gp
    where gp.game_id = p_game_id
      and (
        gp.user_id = p_other_user_id
        or (
          gp.placeholder_id = p_other_user_id
          and exists (
            select 1 from public.placeholder_users
            where id = p_other_user_id and created_by = v_me
          )
        )
      )
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

-- ===== 7. claim_seat : migrer placeholder → real user au moment du claim =====
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
  v_me            uuid := auth.uid();
  v_game_id       uuid;
  v_placeholder   uuid;
begin
  if v_me is null then
    raise exception 'Not authenticated';
  end if;

  select id into v_game_id from public.games where share_code = p_share_code;
  if v_game_id is null then
    raise exception 'Invalid share code';
  end if;

  -- Déjà sur ce siège ?
  if exists (
    select 1 from public.game_participants
     where game_id = v_game_id and seat_index = p_seat_index
       and user_id = v_me
  ) then
    return v_game_id;
  end if;

  -- Récupère le placeholder du seat ciblé (s'il y en a un).
  select placeholder_id into v_placeholder
    from public.game_participants
   where game_id = v_game_id and seat_index = p_seat_index;

  -- Le seat doit être disponible : pas de user_id réel dessus déjà.
  if exists (
    select 1 from public.game_participants
     where game_id = v_game_id and seat_index = p_seat_index
       and user_id is not null
  ) then
    raise exception 'Seat not available';
  end if;

  -- Libère mon ancien siège dans ce game si j'en avais un.
  update public.game_participants
     set user_id = null
   where game_id = v_game_id and user_id = v_me;

  -- Prend le siège, retire le placeholder s'il y en avait un.
  update public.game_participants
     set user_id = v_me, placeholder_id = null
   where game_id = v_game_id and seat_index = p_seat_index;

  -- Migration si placeholder : son UUID est remplacé partout par v_me.
  if v_placeholder is not null then
    -- Marque le placeholder comme claimé.
    update public.placeholder_users
       set claimed_by_user_id = v_me, claimed_at = now()
     where id = v_placeholder;

    -- Tous les autres game_participants qui utilisaient ce placeholder
    -- (autres compteurs du même hôte avec ce joueur) basculent sur v_me.
    update public.game_participants
       set user_id = v_me, placeholder_id = null
     where placeholder_id = v_placeholder;

    -- Migration des dettes : remplace v_placeholder par v_me dans user_a / user_b
    -- de game_pair_settlements. La PK étant (game_id, user_a, user_b), il peut
    -- y avoir conflit si v_me a déjà une row avec le même partenaire — on le
    -- gère en supprimant la row qui collide avant d'updater.
    delete from public.game_pair_settlements gps
     where gps.user_a = v_placeholder
       and exists (
         select 1 from public.game_pair_settlements other
         where other.game_id = gps.game_id and other.user_a = v_me and other.user_b = gps.user_b
       );
    update public.game_pair_settlements
       set user_a = v_me
     where user_a = v_placeholder;

    delete from public.game_pair_settlements gps
     where gps.user_b = v_placeholder
       and exists (
         select 1 from public.game_pair_settlements other
         where other.game_id = gps.game_id and other.user_a = gps.user_a and other.user_b = v_me
       );
    update public.game_pair_settlements
       set user_b = v_me
     where user_b = v_placeholder;
  end if;

  return v_game_id;
end;
$$;

grant execute on function public.claim_seat to authenticated;
revoke all on function public.claim_seat from public;

-- ===== 8. lookup_share_code : retourner placeholder_id + display name =====
-- L'écran "Rejoindre" doit montrer le nom du joueur, qu'il soit guest ou
-- placeholder. Le placeholder est un siège "à claimer" tout comme un guest.
-- Drop nécessaire car le type de retour change (ajout de 2 colonnes).
drop function if exists public.lookup_share_code(text);

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
  placeholder_id    uuid,
  placeholder_name  text,
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
    gp.placeholder_id as placeholder_id,
    ph.display_name   as placeholder_name,
    gp.user_id     as claimed_by_user_id,
    claim_p.display_name as claimed_by_display,
    claim_p.avatar_url   as claimed_by_avatar
  from public.games g
  join public.game_participants gp on gp.game_id = g.id
  left join public.profiles owner_p on owner_p.user_id = g.owner_user_id
  left join public.profiles claim_p on claim_p.user_id = gp.user_id
  left join public.placeholder_users ph on ph.id = gp.placeholder_id
  where g.share_code = p_share_code
  order by gp.seat_index;
$$;

grant execute on function public.lookup_share_code to authenticated, anon;
revoke all on function public.lookup_share_code from public;
