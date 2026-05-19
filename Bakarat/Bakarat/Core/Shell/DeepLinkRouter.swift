//
//  DeepLinkRouter.swift
//  Bakarat
//
//  Routeur central pour les URLs ouvrant l'app via le scheme custom
//  `com.sacha.bakarat://`. Deux routes pour l'instant :
//
//   • com.sacha.bakarat://join/{SHARE_CODE}
//        → ouvre l'écran "Rejoindre un compteur" avec le code pré-rempli,
//          présenté automatiquement par PlayRootView.
//
//   • com.sacha.bakarat://auth/callback[#access_token=...&refresh_token=...]
//        → flow de reset mot de passe Supabase. AuthService consomme l'URL
//          via `client.auth.session(from:)` puis bascule en
//          PASSWORD_RECOVERY ; ContentView affiche SetNewPasswordSheet.
//

import Foundation
import Combine
import Supabase

@MainActor
final class DeepLinkRouter: ObservableObject {
    /// Share code à joindre, set par un deep link bakarat://join/XYZ.
    /// PlayRootView le watch et présente JoinByCodeSheet quand il devient
    /// non-nil. Reset à nil par PlayRootView après consommation.
    @Published var pendingJoinCode: String? = nil

    /// True après un deep link bakarat://auth/callback. ContentView affiche
    /// la sheet de nouveau mot de passe quand vrai. Reset par cette sheet.
    @Published var pendingPasswordReset: Bool = false

    /// Hook depuis BakaratApp.onOpenURL.
    func handle(url: URL) {
        guard url.scheme?.lowercased() == "com.sacha.bakarat" else { return }
        switch url.host?.lowercased() {
        case "join":
            // Format : com.sacha.bakarat://join/<code>
            // url.pathComponents = ["/", "<code>"]
            if let code = url.pathComponents.last(where: { $0 != "/" }) {
                pendingJoinCode = normalize(code)
            }
        case "auth":
            // Reset password : Supabase pose les tokens dans le fragment.
            // On délègue au client supabase qui les extrait et bascule le
            // session en mode recovery (event PASSWORD_RECOVERY).
            pendingPasswordReset = true
            Task {
                _ = try? await SupabaseClientProvider.shared.auth.session(from: url)
            }
        default:
            break
        }
    }

    private func normalize(_ raw: String) -> String {
        raw.replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: " ", with: "")
            .uppercased()
    }
}
