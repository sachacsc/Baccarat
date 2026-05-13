// Configuration du client Supabase (git-tracked).
//
// La anon key est PUBLIQUE par design — elle est servie à tous les clients web.
// La sécurité repose sur RLS (Row Level Security) côté Postgres, pas sur la confidentialité de cette clé.
// NE JAMAIS mettre ici le service_role secret.
//
// Ce fichier expose les constantes globales SUPABASE_URL et SUPABASE_ANON_KEY,
// utilisées par index.html pour instancier supabase.createClient(...).

window.SUPABASE_URL = 'https://wwutjnqchxzdfxmhfaaj.supabase.co';
window.SUPABASE_ANON_KEY = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Ind3dXRqbnFjaHh6ZGZ4bWhmYWFqIiwicm9sZSI6ImFub24iLCJpYXQiOjE3Nzg2MjMwMTcsImV4cCI6MjA5NDE5OTAxN30.JeealVciyofN8NrTWFXOrqznKAPInldkRiJ7tm7fk4Y';
