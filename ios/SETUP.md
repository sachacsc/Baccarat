# Baccarat iOS — Setup Xcode

> App SwiftUI native pour iOS. Backend partagé avec la version web (Supabase).

## Pré-requis

- macOS récent
- Xcode 16+ (Liquid Glass natif sur iOS 26+)
- Compte Apple Developer (99 €/an) pour TestFlight + App Store, **optionnel** pour développer/tester sur simulateur

## Création du projet Xcode (à faire une fois)

1. **Ouvre Xcode → File → New → Project**
2. **iOS → App**
3. Configure :
   - **Product Name** : `Baccarat`
   - **Team** : ton compte Apple Developer (ou None pour commencer)
   - **Organization Identifier** : `com.sachacs` (ou ce que tu veux)
   - **Bundle Identifier** : `com.sachacs.Baccarat`
   - **Interface** : `SwiftUI`
   - **Language** : `Swift`
   - **Storage** : `None` (on n'utilise pas CoreData)
   - **Include Tests** : à toi de voir
4. **Save in** : `/Users/sacha/Developer/Baccarat/ios/`
   - ⚠ Décoche "Create Git repository" (le repo parent est déjà initialisé)
   - Xcode va créer le dossier `Baccarat.xcodeproj` à cet emplacement
5. Ouvre le projet créé.

## Ajouter les fichiers Swift que j'ai écrits

Le dossier `ios/Baccarat/` contient déjà l'arborescence Core/Shared/Supabase avec les premiers `.swift`. Pour les intégrer au projet Xcode :

1. **Supprime le `ContentView.swift` par défaut** créé par Xcode (et son entry `BaccaratApp.swift` si il en a créé un).
2. Dans le navigateur de fichiers Xcode, **clique droit sur le groupe `Baccarat` → Add Files to "Baccarat"...**
3. Sélectionne le dossier `ios/Baccarat/Core` → coche **"Create groups"** (pas "Create folder references") → **Add**
4. Refais pareil pour `Shared`, `Supabase`, et le fichier `BaccaratApp.swift` à la racine de `ios/Baccarat/`.

## Ajouter le SDK Supabase

1. Dans Xcode : **File → Add Package Dependencies...**
2. URL : `https://github.com/supabase/supabase-swift.git`
3. Version : "Up to Next Major Version" 2.0.0
4. Sélectionne le produit **Supabase** → Add Package

Si Xcode te propose plusieurs produits (Auth, Realtime, Functions…), prends juste **Supabase** qui embarque tout.

## Configurer les credentials Supabase

Ouvre `ios/Baccarat/Supabase/SupabaseConfig.swift` et vérifie que l'URL + l'anon key correspondent à ton projet :

```swift
enum SupabaseConfig {
    static let url = URL(string: "https://wwutjnqchxzdfxmhfaaj.supabase.co")!
    static let anonKey = "eyJhbGc..."
}
```

(Mêmes valeurs que `supabase-config.js` côté web.)

## Lancer en simulateur

1. En haut de Xcode, sélectionne un simulateur (iPhone 16, etc.)
2. ⌘ R (Run)

Tu devrais voir l'écran de login.

## Configurer redirect URLs Supabase

Pour que les password resets (et plus tard OAuth) reviennent à l'app, il faut un URL scheme custom dans Info.plist :

1. Ouvre `Info.plist` (ou Target → Info)
2. Ajoute `URL Types` → un schéma `com.sachacs.Baccarat` (ou similaire)
3. Dans Supabase Dashboard → Authentication → URL Configuration, ajoute :
   `com.sachacs.Baccarat://auth/callback` aux Redirect URLs

Ça permettra le deep linking quand on activera le reset password.

## Backend partagé

Toute la couche Supabase (tables, RLS, RPCs, Storage) est définie dans `/supabase/migrations/`. Les migrations ont déjà été appliquées au projet distant. Tu n'as RIEN à reconfigurer côté DB pour l'iOS — le SDK Swift se branche sur les mêmes tables.

## Structure du projet

Voir `ios/README.md`.

## Lancer sur ton iPhone physique

1. Branche ton iPhone en USB
2. En haut de Xcode, sélectionne ton iPhone comme device
3. La 1ère fois : tu dois faire confiance au certificat de dev sur ton iPhone (Réglages → Général → VPN et gestion de l'appareil)
4. ⌘ R

Pour TestFlight : il faut un compte Apple Developer payant.

## Prochaines étapes (workflow recommandé)

1. **Login flow** : tester signup + signin + persistence de session
2. **Profile** : afficher display_name, permettre l'édit, upload avatar
3. **Compteur** : porter la logique de validation/scoring depuis `src/game/eval.js`
4. **Online** : matchmaking via Supabase Realtime (peer-to-peer ou hub)
5. **Polish** : transitions, haptics, splash screen, app icon
6. **Publish** : TestFlight → App Store
