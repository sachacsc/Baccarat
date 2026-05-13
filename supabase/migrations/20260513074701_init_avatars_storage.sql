-- Bucket "avatars" public en lecture : tout le monde peut voir un avatar (il sera
-- affiché à côté du pseudo dans la liste des dettes, etc.). En écriture : seul le
-- propriétaire peut uploader son propre avatar.
--
-- Convention de chemin : avatars/{user_id}/{filename}
--   → la 1ère partie du path = uuid du user, vérifié par RLS.

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'avatars',
  'avatars',
  true,
  5242880, -- 5 MB max
  array['image/jpeg', 'image/png', 'image/webp', 'image/gif']
)
on conflict (id) do update set
  public = excluded.public,
  file_size_limit = excluded.file_size_limit,
  allowed_mime_types = excluded.allowed_mime_types;

-- Drop policies existantes (idempotent) avant de recréer
drop policy if exists "Avatars publicly readable"      on storage.objects;
drop policy if exists "Users upload their own avatar"  on storage.objects;
drop policy if exists "Users update their own avatar"  on storage.objects;
drop policy if exists "Users delete their own avatar"  on storage.objects;

-- Lecture publique sur tout le bucket avatars (sinon impossible d'afficher les avatars des autres)
create policy "Avatars publicly readable"
  on storage.objects for select
  to public
  using (bucket_id = 'avatars');

-- Upload : un user ne peut uploader que dans son dossier {user_id}/
create policy "Users upload their own avatar"
  on storage.objects for insert
  to authenticated
  with check (
    bucket_id = 'avatars'
    and auth.uid()::text = (storage.foldername(name))[1]
  );

-- Update : idem, on ne peut remplacer (upsert) que son propre fichier
create policy "Users update their own avatar"
  on storage.objects for update
  to authenticated
  using (
    bucket_id = 'avatars'
    and auth.uid()::text = (storage.foldername(name))[1]
  );

-- Delete : idem
create policy "Users delete their own avatar"
  on storage.objects for delete
  to authenticated
  using (
    bucket_id = 'avatars'
    and auth.uid()::text = (storage.foldername(name))[1]
  );
