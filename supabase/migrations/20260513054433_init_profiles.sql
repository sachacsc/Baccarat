-- Profil joueur : 1 ligne par utilisateur Supabase Auth.
-- Créé automatiquement à l'inscription via un trigger sur auth.users.
-- Lecture publique (pour afficher "Alex te doit X€"), édition réservée au propriétaire.

create table public.profiles (
  user_id      uuid primary key references auth.users(id) on delete cascade,
  display_name text not null,
  avatar_url   text,
  currency     text not null default 'EUR',
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);

comment on table public.profiles is 'Profil utilisateur (extension de auth.users)';

-- Auto-update du timestamp à chaque modif
create or replace function public.touch_updated_at()
returns trigger language plpgsql as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

create trigger profiles_touch_updated_at
  before update on public.profiles
  for each row execute function public.touch_updated_at();

-- À la création d'un user Supabase Auth, on crée son profile.
-- display_name = celui passé dans raw_user_meta_data, sinon partie locale de l'email.
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
      split_part(new.email, '@', 1)
    )
  );
  return new;
end;
$$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- ===== RLS =====
alter table public.profiles enable row level security;

-- Tout le monde (anon + authentifié) peut lire les profils.
-- Pour un jeu social où on affiche les noms d'autres joueurs, c'est nécessaire.
-- Aucune donnée sensible n'est dans cette table.
create policy "profiles are viewable by everyone"
  on public.profiles
  for select
  using (true);

-- Chacun ne modifie que son propre profil.
-- UPDATE en RLS nécessite aussi une SELECT policy (déjà couverte ci-dessus).
create policy "users update their own profile"
  on public.profiles
  for update
  using (auth.uid() = user_id)
  with check (auth.uid() = user_id);

-- L'INSERT est uniquement fait par le trigger (security definer bypasse RLS).
-- On ne crée pas de policy INSERT pour les rôles anon/authenticated → impossible
-- pour un client d'insérer une ligne profile arbitraire.
