# Baccarat iOS

Native SwiftUI app for the Baccarat 3-boards variant. Shares the same Supabase backend as the web version.

For setup instructions (Xcode project creation, Supabase SDK install, etc.), see **SETUP.md**.

## File map

```
ios/Baccarat/
├── BaccaratApp.swift                  @main entry
├── ContentView.swift                  Switch : AuthGate ↔ MainTabView
├── Core/
│   ├── Authentication/
│   │   ├── Service/AuthService.swift  ObservableObject around Supabase Auth
│   │   ├── Model/UserProfile.swift    Mirror of public.profiles
│   │   ├── AuthErrorMessage.swift     Supabase err → French message
│   │   └── View/
│   │       ├── AuthGateView.swift     NavigationStack between login/signup/forgot
│   │       ├── LoginView.swift
│   │       ├── SignUpView.swift
│   │       └── ForgotPasswordView.swift
│   ├── Shell/
│   │   └── MainTabView.swift          3 tabs : Online / Compteur / Dettes
│   ├── Online/
│   │   └── View/OnlineRootView.swift  Entry + Lobby + Join placeholders
│   ├── Counter/
│   │   └── View/CounterRootView.swift List + Create sheet + Detail placeholder
│   ├── Debts/
│   │   └── View/DebtsRootView.swift   Bilan net + avatar trailing
│   ├── Profile/
│   │   └── View/ProfileSheet.swift    Avatar + display_name edit + signout
│   └── Game/
│       ├── Model/Card.swift           Card / Rank / Suit / Deck
│       ├── Model/HandCategory.swift   10 catégories d'annonces
│       └── Logic/HandEvaluator.swift  evaluate5 / evaluateBest / compareHands / autoPick / computeNuts
├── Shared/
│   └── Theme/Theme.swift              Colors + reusable view modifiers
├── Supabase/
│   ├── SupabaseConfig.swift           URL + anon key (public)
│   └── SupabaseClientProvider.swift   Shared SupabaseClient
└── Resources/                         (avatars in Assets, card assets via CDN)
```

## What's wired up

- ✅ Auth (sign in, sign up, password reset, session persistence)
- ✅ Profile (basic edit + sign out)
- ✅ Three-tab shell
- ✅ Hand evaluator (ported from src/game/eval.js)
- ✅ Card model + deck shuffle

## What's still placeholder

- ⏳ Online Lobby / In-Game UI + networking
- ⏳ Counter detail (setup form, scoreboard, manche editor, history)
- ⏳ Debts pairwise computation + UI
- ⏳ Avatar upload to Supabase Storage
- ⏳ App icon + splash + asset catalog
- ⏳ Push notifications (later)

## Architecture choices

- **MVVM via `@StateObject` + `@EnvironmentObject`** for shared services (`AuthService`).
- **One `NavigationStack` per tab** so SwiftUI handles push/pop, swipe-back, the back chevron — all native.
- **Sheets via `.sheet(isPresented:)`** with `.presentationDetents([.medium, .large])` for half-sheet feel.
- **No state library yet** (no Combine pipelines, no async streams beyond Supabase's own). Add Observable / a state machine library later if complexity grows.

## Sharing with the web

- **RULES.md** at the repo root is the source of truth for game rules. The Swift code must follow it.
- **Supabase migrations** in `/supabase/migrations/` apply to both clients.
- **HandEvaluator.swift** mirrors `src/game/eval.js` line-by-line for parity. If you change scoring logic in one place, mirror it in the other.

## Next batches (suggested order)

1. Test the Auth flow end-to-end (signup → main tabs → signout → resume)
2. Wire ProfileSheet's photo picker to Supabase Storage upload
3. Port the multi-counter state (load from `state.counters` localStorage? Or start fresh and reuse the Supabase `games` table directly?)
4. Counter detail : setup form, scoreboard, manche editor
5. Online : decide between PeerJS (web bridge, unlikely) vs Supabase Realtime (preferred) vs custom server
6. Debts tab from real data (`manche_results` + `balances` tables)
