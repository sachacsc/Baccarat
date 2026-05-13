-- Persistance des parties : games + participants + manches + résultats.
-- Une "game" = une session de jeu (potentiellement plusieurs manches).
-- En mode compteur, l'owner est celui qui sauvegarde (en général le donneur initial).
-- En mode online (plus tard), l'owner = l'hôte.
--
-- Les participants peuvent être des comptes loggués (user_id) ou des invités (guest_name).
-- Un même seat peut être lié à un compte plus tard (UPDATE de game_participants.user_id),
-- ce qui permettra de recalculer rétroactivement les balances.

-- ===== games =====
create table public.games (
  id              uuid primary key default gen_random_uuid(),
  owner_user_id   uuid not null references auth.users(id) on delete cascade,
  mode            text not null check (mode in ('counter','online')),
  line_price      numeric(10,2) not null,
  currency        text not null default 'EUR',
  settings_json   jsonb not null default '{}'::jsonb,
  status          text not null default 'active' check (status in ('active','finished','abandoned')),
  created_at      timestamptz not null default now(),
  finished_at     timestamptz
);

create index games_owner_idx on public.games(owner_user_id, created_at desc);

-- ===== game_participants =====
-- Une ligne par siège. user_id et guest_name sont mutuellement exclusifs.
create table public.game_participants (
  game_id     uuid not null references public.games(id) on delete cascade,
  seat_index  int  not null,
  user_id     uuid references auth.users(id) on delete set null,
  guest_name  text,
  joined_at   timestamptz not null default now(),
  primary key (game_id, seat_index),
  constraint participant_identity check (
    (user_id is not null and guest_name is null) or
    (user_id is null and guest_name is not null)
  )
);

create index game_participants_user_idx on public.game_participants(user_id) where user_id is not null;

-- ===== manches =====
-- Un enregistrement par manche jouée. board_results contient les détails de chaque
-- board (winner_seat, multi, splits éventuels) — stocké en jsonb pour flexibilité.
create table public.manches (
  id                  uuid primary key default gen_random_uuid(),
  game_id             uuid not null references public.games(id) on delete cascade,
  manche_number       int  not null,
  dealer_seat         int,
  line_price          numeric(10,2) not null,  -- snapshot (le prix peut changer au cours d'une session)
  num_active          int  not null,
  board_results       jsonb not null,
  -- structure attendue : [
  --   {board_num: 1, winner_seat: 2, multi: 1, is_split: false},
  --   {board_num: 2, winner_seat: 0, multi: 8, is_split: true, splitter_seats: [0,3], final_winner_seat: 0, final_multi: 8},
  --   {board_num: 3, winner_seat: 1, multi: 16}
  -- ]
  full_board_seat     int,
  created_at          timestamptz not null default now(),
  unique (game_id, manche_number)
);

create index manches_game_idx on public.manches(game_id, manche_number);

-- ===== manche_results =====
-- Un enregistrement par siège par manche (delta financier).
create table public.manche_results (
  manche_id        uuid not null references public.manches(id) on delete cascade,
  seat_index       int  not null,
  delta            numeric(10,2) not null,
  boards_won_json  jsonb not null default '[]'::jsonb,
  -- ex: [{board_num: 1, multi: 1}, {board_num: 2, multi: 8}]
  primary key (manche_id, seat_index)
);

-- ===== RLS =====
alter table public.games             enable row level security;
alter table public.game_participants enable row level security;
alter table public.manches           enable row level security;
alter table public.manche_results    enable row level security;

-- games : un user voit ses games (en tant qu'owner OU participant loggué)
create policy "games visible to owner or participants"
  on public.games for select
  using (
    owner_user_id = auth.uid()
    or exists (
      select 1 from public.game_participants gp
      where gp.game_id = games.id and gp.user_id = auth.uid()
    )
  );

-- game_participants : un user voit les rows des games auxquelles il participe
create policy "game_participants visible to owner or participants"
  on public.game_participants for select
  using (
    user_id = auth.uid()
    or exists (
      select 1 from public.games g
      where g.id = game_participants.game_id
        and (g.owner_user_id = auth.uid() or exists (
          select 1 from public.game_participants gp2
          where gp2.game_id = g.id and gp2.user_id = auth.uid()
        ))
    )
  );

-- manches : visibles aux participants
create policy "manches visible to participants"
  on public.manches for select
  using (
    exists (
      select 1 from public.games g
      where g.id = manches.game_id
        and (g.owner_user_id = auth.uid() or exists (
          select 1 from public.game_participants gp
          where gp.game_id = g.id and gp.user_id = auth.uid()
        ))
    )
  );

-- manche_results : idem
create policy "manche_results visible to participants"
  on public.manche_results for select
  using (
    exists (
      select 1 from public.manches m
      join public.games g on g.id = m.game_id
      where m.id = manche_results.manche_id
        and (g.owner_user_id = auth.uid() or exists (
          select 1 from public.game_participants gp
          where gp.game_id = g.id and gp.user_id = auth.uid()
        ))
    )
  );

-- Pas de policy INSERT/UPDATE/DELETE pour anon/authenticated → les écritures passent
-- exclusivement par les RPCs (SECURITY DEFINER) qui valident l'autorisation.

-- ===== RPC record_manche =====
-- Sauvegarde atomique d'une manche : crée la game si nécessaire (1ère manche),
-- insert manche + manche_results, retourne le game_id pour stockage côté client.
-- Idempotent sur (game_id, manche_number) : ré-appel = no-op.
create or replace function public.record_manche(
  p_game_id        uuid,        -- null à la 1ère manche pour qu'on crée la game
  p_mode           text,        -- 'counter' ou 'online'
  p_line_price     numeric,
  p_currency       text,
  p_settings_json  jsonb,
  p_participants   jsonb,       -- [{seat_index, user_id|null, guest_name|null}, ...]
  p_manche_number  int,
  p_dealer_seat    int,
  p_num_active     int,
  p_board_results  jsonb,
  p_full_board_seat int,
  p_results_per_seat jsonb      -- [{seat_index, delta, boards_won_json}, ...]
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

  -- Si pas de game_id → on crée la game + les participants
  if v_game_id is null then
    insert into public.games (owner_user_id, mode, line_price, currency, settings_json)
    values (v_caller, p_mode, p_line_price, p_currency, coalesce(p_settings_json, '{}'::jsonb))
    returning id into v_game_id;

    for p in select * from jsonb_array_elements(p_participants) loop
      insert into public.game_participants (game_id, seat_index, user_id, guest_name)
      values (
        v_game_id,
        (p->>'seat_index')::int,
        nullif(p->>'user_id','')::uuid,
        nullif(p->>'guest_name','')
      );
    end loop;
  else
    -- Vérif autorisation : seul l'owner peut continuer à ajouter des manches
    if not exists (select 1 from public.games where id = v_game_id and owner_user_id = v_caller) then
      raise exception 'Game not found or unauthorized';
    end if;
  end if;

  -- Insert manche (idempotent)
  insert into public.manches (game_id, manche_number, dealer_seat, line_price, num_active, board_results, full_board_seat)
  values (v_game_id, p_manche_number, p_dealer_seat, p_line_price, p_num_active, p_board_results, p_full_board_seat)
  on conflict (game_id, manche_number) do nothing
  returning id into v_manche_id;

  -- Si déjà existant, on retourne juste l'id de la game (no-op)
  if v_manche_id is null then
    return v_game_id;
  end if;

  -- Insert manche_results
  for r in select * from jsonb_array_elements(p_results_per_seat) loop
    insert into public.manche_results (manche_id, seat_index, delta, boards_won_json)
    values (
      v_manche_id,
      (r->>'seat_index')::int,
      (r->>'delta')::numeric,
      coalesce(r->'boards_won_json', '[]'::jsonb)
    );
  end loop;

  return v_game_id;
end;
$$;

revoke all on function public.record_manche from public;
grant execute on function public.record_manche to authenticated;

comment on function public.record_manche is 'Sauvegarde atomique d''une manche (crée la game si game_id null).';
