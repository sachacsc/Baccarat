// Supabase Edge Function : notify_settlement
//
// Reçoit un webhook de Postgres (trigger after insert/update sur
// game_pair_settlements) et envoie une notification APNs au user
// counterpart (celui qui n'a PAS déclaré le paiement). Pour iOS.
//
// Setup nécessaire AVANT déploiement (à faire manuellement) :
//
//  1. Apple Developer Portal :
//     - Activer "Push Notifications" sur l'App ID com.sacha.Bakarat.
//     - Keys → Create new APNs Auth Key, télécharger AuthKey_XXXXXXXXXX.p8.
//     - Noter : Key ID (10 chars) + Team ID (10 chars).
//
//  2. Supabase Dashboard → Edge Functions → Secrets :
//      APNS_KEY_ID        = "XXXXXXXXXX"        (depuis Apple)
//      APNS_TEAM_ID       = "8ATC9B23MK"        (Team ID, déjà connu)
//      APNS_KEY_P8        = "<contenu du .p8>"  (le BEGIN/END PRIVATE KEY inclus)
//      APNS_BUNDLE_ID     = "com.sacha.Bakarat"
//      APNS_ENVIRONMENT   = "development"       (puis "production" pour App Store)
//
//  3. Déployer : `supabase functions deploy notify_settlement`
//
//  4. Créer le trigger pg_net dans Postgres (cf. migration séparée à venir) :
//     trigger after insert or update on game_pair_settlements →
//        net.http_post(url='<function url>', headers={Authorization: ...}, body=row)
//
// CE FICHIER EST UN SKELETON. Implémentation APNs HTTP/2 + signature JWT à
// compléter avant utilisation production. Ne pas déployer tel quel.

// deno-lint-ignore-file no-explicit-any
// @ts-nocheck — squelette, types Deno non importés

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

interface SettlementPayload {
  game_id: string;
  user_a: string;
  user_b: string;
  settled_by: string;
}

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") {
    return new Response("Method Not Allowed", { status: 405 });
  }

  let body: SettlementPayload;
  try {
    body = await req.json();
  } catch {
    return new Response("Invalid JSON", { status: 400 });
  }

  // Le user counterparty = celui qui n'a PAS marqué payé.
  const recipient = body.settled_by === body.user_a ? body.user_b : body.user_a;

  // Service role client pour lire device_tokens (RLS bypass).
  const supabase = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  );

  const { data: tokens, error } = await supabase
    .from("device_tokens")
    .select("token, platform")
    .eq("user_id", recipient)
    .eq("platform", "ios");

  if (error) {
    console.error("device_tokens query failed", error);
    return new Response("DB error", { status: 500 });
  }
  if (!tokens || tokens.length === 0) {
    return new Response("No tokens", { status: 204 });
  }

  // TODO: générer un JWT signé ES256 avec APNS_KEY_P8 / APNS_KEY_ID / APNS_TEAM_ID.
  // TODO: pour chaque token, POST https://api.sandbox.push.apple.com/3/device/<token>
  //       avec headers apns-topic = APNS_BUNDLE_ID + Authorization: bearer <jwt>
  //       et body { aps: { alert: { title: "Bakarat", body: "X a marqué une dette comme payée." } } }
  //
  // Voir https://developer.apple.com/documentation/usernotifications/sending_notification_requests_to_apns
  //
  // Bibliothèque utile : https://deno.land/x/djwt pour le JWT ES256.

  console.log(`[notify_settlement] would notify ${tokens.length} device(s) for user ${recipient}`);

  return new Response(JSON.stringify({ recipients: tokens.length, status: "skeleton" }), {
    headers: { "Content-Type": "application/json" },
  });
});
