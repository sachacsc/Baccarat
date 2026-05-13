-- Ledger pairwise entre joueurs loggués.
--
-- Schéma : 2 lignes par paire (A→B et B→A) avec montants opposés.
-- Avantage : requête "ma balance avec Alex" devient trivial (where user_id = me).
-- Convention : balances(user_id, other_user_id).amount > 0 → other doit à user_id.
--                                                 amount < 0 → user_id doit à other.

create table public.balances (
  user_id        uuid not null references auth.users(id) on delete cascade,
  other_user_id  uuid not null references auth.users(id) on delete cascade,
  amount         numeric(12,2) not null default 0,
  updated_at     timestamptz not null default now(),
  primary key (user_id, other_user_id),
  check (user_id <> other_user_id)
);

create index balances_user_idx on public.balances(user_id);

alter table public.balances enable row level security;

-- On ne voit QUE ses propres lignes (les 2 sens d'une paire sont visibles via les 2 owners).
create policy "balances visible to owner"
  on public.balances for select
  using (user_id = auth.uid());

-- Pas de policy INSERT/UPDATE/DELETE pour authenticated → écritures via SECURITY DEFINER seulement.

-- ===== Helper : applique un transfert entre 2 users (paie X → reçoit Y, montant A) =====
-- Crée/MET À JOUR les 2 lignes opposées de la paire en une transaction atomique.
create or replace function public._apply_transfer(p_payer uuid, p_payee uuid, p_amount numeric)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if p_payer is null or p_payee is null or p_payer = p_payee or p_amount <= 0 then return; end if;

  -- Côté payeur : on baisse ce que le payee leur "doit" (ou on augmente leur dette envers payee)
  insert into public.balances (user_id, other_user_id, amount)
  values (p_payer, p_payee, -p_amount)
  on conflict (user_id, other_user_id) do update
    set amount = public.balances.amount - p_amount,
        updated_at = now();

  -- Côté payee : symétrique, on monte ce que le payer leur doit
  insert into public.balances (user_id, other_user_id, amount)
  values (p_payee, p_payer, p_amount)
  on conflict (user_id, other_user_id) do update
    set amount = public.balances.amount + p_amount,
        updated_at = now();
end;
$$;

revoke all on function public._apply_transfer from public;

-- ===== Calcul des balances pour une manche donnée =====
-- Itère sur les board_results de la manche, pour chaque board calcule les transferts
-- entre joueurs LOGGUÉS uniquement (les invités sont ignorés — ils ne peuvent pas avoir
-- de balance puisqu'ils n'ont pas de compte).
create or replace function public._apply_balances_for_manche(p_manche_id uuid)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_manche       record;
  v_price        numeric;
  v_seat_to_user jsonb;   -- {seat_index: user_id} pour les loggués
  v_board        jsonb;
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
begin
  select * into v_manche from public.manches where id = p_manche_id;
  if not found then return; end if;
  v_price := v_manche.line_price;

  -- Snapshot {seat_index: user_id} des participants loggués de cette game
  select coalesce(jsonb_object_agg(gp.seat_index, gp.user_id), '{}'::jsonb)
    into v_seat_to_user
    from public.game_participants gp
    where gp.game_id = v_manche.game_id and gp.user_id is not null;

  -- Si moins de 2 joueurs loggués, aucune balance à calculer
  if jsonb_path_exists(v_seat_to_user, '$.*') is not true then return; end if;
  if (select count(*) from jsonb_object_keys(v_seat_to_user)) < 2 then return; end if;

  -- ===== Boucle sur les 3 boards =====
  for v_board in select * from jsonb_array_elements(v_manche.board_results)
  loop
    v_winner_seat := nullif(v_board->>'final_winner_seat', '')::int;
    if v_winner_seat is null then continue; end if;
    v_winner_user := nullif(v_seat_to_user->>v_winner_seat::text, '')::uuid;
    if v_winner_user is null then continue; end if;  -- gagnant invité, on skip

    v_multi := coalesce((v_board->>'multi')::numeric, 1);
    v_final_multi := coalesce((v_board->>'final_multi')::numeric, v_multi);
    v_is_split := coalesce((v_board->>'is_split')::boolean, false);
    v_splitter_seats := coalesce(v_board->'splitter_seats', '[]'::jsonb);

    -- Tous les autres participants loggués paient
    for v_loser_seat in select (k::text)::int from jsonb_object_keys(v_seat_to_user) k
    loop
      if v_loser_seat = v_winner_seat then continue; end if;
      v_loser_user := nullif(v_seat_to_user->>v_loser_seat::text, '')::uuid;
      if v_loser_user is null then continue; end if;

      if v_is_split then
        -- Splitter (non-gagnant final) paie au multi du tiebreak, autres au multi base (1)
        v_is_splitter := v_splitter_seats @> to_jsonb(v_loser_seat);
        v_payment := v_price * (case when v_is_splitter then v_final_multi else 1 end);
      else
        v_payment := v_price * v_multi;
      end if;

      perform public._apply_transfer(v_loser_user, v_winner_user, v_payment);
    end loop;
  end loop;

  -- ===== Full board bonus =====
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

revoke all on function public._apply_balances_for_manche from public;

-- ===== Hook : record_manche appelle le calcul des balances après l'insert =====
-- On remplace la fonction existante en ajoutant l'appel à _apply_balances_for_manche
-- à la fin (avant le RETURN). Tout le reste est identique à la version précédente.
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
      insert into public.game_participants (game_id, seat_index, user_id, guest_name)
      values (
        v_game_id,
        (p->>'seat_index')::int,
        nullif(p->>'user_id','')::uuid,
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

  -- Met à jour le ledger pairwise (entre joueurs loggués uniquement)
  perform public._apply_balances_for_manche(v_manche_id);

  return v_game_id;
end;
$$;

grant execute on function public.record_manche to authenticated;
