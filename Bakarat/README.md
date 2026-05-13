# Bakarat iOS

Native SwiftUI app for the Baccarat 3-boards variant. Shares the same Supabase backend as the web version at the repo root.

## Quick start (you've already created the project, jump here)

1. **Add the Supabase SDK** :
   Xcode → **File → Add Package Dependencies...**
   URL: `https://github.com/supabase/supabase-swift.git`
   Version: **Up to Next Major Version** → `2.0.0`
   Product: select **Supabase** (the umbrella one).

2. **Build & run** :
   ⌘ R on a simulator (iPhone 16 or later).
   Xcode 16 auto-detects every `.swift` file inside `Bakarat/` thanks to the synchronized folder group — you don't need to drag anything.

3. **You should see** the login screen. Create a test account → land on the 3-tab shell (Online / Compteur / Dettes).

## File map

```
Bakarat/                           Xcode project root
├── Bakarat/                       App source (auto-synced into Xcode)
│   ├── BakaratApp.swift           @main entry
│   ├── ContentView.swift          AuthGate ↔ MainTabView
│   ├── Assets.xcassets/           AppIcon + accent (default for now)
│   ├── Core/
│   │   ├── Authentication/
│   │   │   ├── Service/AuthService.swift
│   │   │   ├── Model/UserProfile.swift
│   │   │   ├── AuthErrorMessage.swift
│   │   │   └── View/  (AuthGate, Login, SignUp, ForgotPassword)
│   │   ├── Shell/MainTabView.swift
│   │   ├── Online/View/OnlineRootView.swift
│   │   ├── Counter/View/CounterRootView.swift
│   │   ├── Debts/View/DebtsRootView.swift
│   │   ├── Profile/View/ProfileSheet.swift
│   │   └── Game/
│   │       ├── Model/Card.swift
│   │       ├── Model/HandCategory.swift
│   │       └── Logic/HandEvaluator.swift
│   ├── Shared/
│   │   ├── Theme/Theme.swift                  brand colors + modifiers
│   │   └── Components/BrandLogo.swift         placeholder logo
│   └── Supabase/
│       ├── SupabaseConfig.swift               url + anon key
│       └── SupabaseClientProvider.swift       shared client
├── Bakarat.xcodeproj
├── BakaratTests/
└── BakaratUITests/
```

## What's wired up

- Auth (sign in / sign up / forgot password / session persistence)
- Profile sheet (display_name edit, sign out, PhotosPicker stub)
- 3-tab shell with native `NavigationStack` per tab (push/pop, swipe-back, back chevron all free)
- Hand evaluator ported from `src/game/eval.js`
- Card / Rank / Suit model compatible with web JSON

## What's still placeholder

- Online Lobby + In-Game UI + networking (Supabase Realtime planned)
- Counter detail (setup, scoreboard, manche editor, history)
- Debts pairwise computation + UI
- Avatar upload to Supabase Storage
- Custom app icon + splash

## Notes

- `SupabaseConfig.swift` contains the same public anon key as the web's `supabase-config.js`. Security is enforced by RLS on the DB side.
- **The repo root contains the web app** (vanilla JS, GH Pages). They share the same Supabase project — never reimplement business logic in only one place.
- Game rules : `../RULES.md` (relative from this folder = repo root). Read it once before touching scoring.
- For overall architecture and shared conventions, see `../CLAUDE.md`.

## Architecture choices

- MVVM via `@StateObject` + `@EnvironmentObject` for `AuthService`.
- One `NavigationStack` per tab → push/pop, back chevron, swipe-back gesture all native.
- Sheets with `.presentationDetents([.medium, .large])` for iOS half-sheet feel.
- No state management library yet — add Observable / TCA if complexity grows.

## Why the project sits at the repo root

You created the Xcode project at `/Baccarat/Bakarat/` instead of inside an `/ios/` subfolder. That's fine — keeping it here means simpler relative paths and Xcode is happy. The web app stays untouched at the repo root.

## Reset password redirect

For the password reset flow to bring users back into the app from their email link, add an URL scheme:

1. Target → Info → URL Types → +
2. URL Schemes: `com.sachacs.bakarat` (or your bundle id)
3. In Supabase Dashboard → Authentication → URL Configuration → Redirect URLs, add:
   `com.sachacs.bakarat://auth/callback`

Implementation of the deep link handler will come in a later batch.
