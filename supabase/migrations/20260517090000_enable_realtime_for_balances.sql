-- Active Realtime postgres_changes sur la table balances afin que l'onglet
-- "Dettes" se rafraîchisse automatiquement après chaque manche (online ou
-- compteur) qui modifie le ledger pairwise.
--
-- La RLS reste appliquée : un client ne reçoit que les events sur les rows
-- dont il est propriétaire (user_id = auth.uid()).

alter publication supabase_realtime add table public.balances;
