-- Active Realtime postgres_changes sur les tables nécessaires à la live
-- update de l'historique online côté client.
--
-- La RLS reste appliquée : un client ne reçoit que les events pour les rows
-- qu'il a le droit de SELECT (= games auxquelles il participe).

alter publication supabase_realtime add table public.games;
alter publication supabase_realtime add table public.manches;
alter publication supabase_realtime add table public.manche_results;
alter publication supabase_realtime add table public.game_participants;
