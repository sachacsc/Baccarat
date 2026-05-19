-- Device tokens pour notifications push APNs (iOS) / FCM (Android plus tard).
--
-- Schéma : 1 row par (user_id, token). Un user peut avoir plusieurs devices
-- (iPhone + iPad), et un token peut éventuellement bouger (réinstall, etc.).
-- Pas de uniqueness sur token seul : si un même device se reconnecte sous
-- un autre compte, l'ancien row reste jusqu'à unregister explicite.
--
-- Pour câbler côté APNs : voir la docstring de la fonction
-- `notify_settlement` (Edge Function dans supabase/functions/).

create table public.device_tokens (
  user_id     uuid not null references auth.users(id) on delete cascade,
  token       text not null,
  platform    text not null check (platform in ('ios', 'android')),
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  primary key (user_id, token)
);

create index device_tokens_user_idx on public.device_tokens(user_id);

alter table public.device_tokens enable row level security;

create policy "device_tokens visible to owner"
  on public.device_tokens for select
  using (user_id = auth.uid());

-- Pas de policy INSERT/UPDATE/DELETE → RPCs SECURITY DEFINER only.

-- ===== RPC register_device_token =====
create or replace function public.register_device_token(
  p_token text,
  p_platform text
)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_me uuid := auth.uid();
begin
  if v_me is null then raise exception 'Not authenticated'; end if;
  if p_token is null or length(p_token) < 4 then
    raise exception 'Invalid token';
  end if;
  if p_platform not in ('ios', 'android') then
    raise exception 'Invalid platform';
  end if;

  insert into public.device_tokens(user_id, token, platform)
  values (v_me, p_token, p_platform)
  on conflict (user_id, token) do update
    set platform = excluded.platform,
        updated_at = now();
end;
$$;

grant execute on function public.register_device_token to authenticated;
revoke all on function public.register_device_token from public;

-- ===== RPC unregister_device_token =====
create or replace function public.unregister_device_token(p_token text)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_me uuid := auth.uid();
begin
  if v_me is null then raise exception 'Not authenticated'; end if;
  delete from public.device_tokens where user_id = v_me and token = p_token;
end;
$$;

grant execute on function public.unregister_device_token to authenticated;
revoke all on function public.unregister_device_token from public;
