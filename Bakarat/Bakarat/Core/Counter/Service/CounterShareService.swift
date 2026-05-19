//
//  CounterShareService.swift
//  Bakarat
//
//  Wrappers Swift autour des RPCs Supabase du partage de compteur :
//
//   • get_or_create_share_code(p_game_id) → text   (host only)
//   • lookup_share_code(p_share_code) → liste seats + game info
//   • claim_seat(p_share_code, p_seat_index)       (joiner)
//   • unclaim_seat(p_game_id)                      (joiner)
//
//  Aucun état stocké : c'est un service stateless, on l'instancie au besoin
//  depuis les vues qui en ont besoin (ShareCounterSheet, ClaimSeatView).
//

import Foundation
import Supabase

/// Snapshot d'un game accessible via share_code. Une row par seat.
struct SharedGameSeat: Identifiable, Hashable {
    let gameId: UUID
    let mode: String
    let linePrice: Double
    let currency: String
    let ownerDisplay: String?
    let createdAt: Date?

    let seatIndex: Int
    /// Label original tapé par l'hôte au moment de la création (préservé même
    /// après revendication, pour que tout le monde s'y retrouve).
    let guestName: String?
    let claimedByUserId: UUID?
    let claimedByDisplay: String?
    let claimedByAvatar: String?

    var id: Int { seatIndex }
    var isClaimed: Bool { claimedByUserId != nil }
}

enum CounterShareError: LocalizedError {
    case invalidShareCode
    case rpc(String)

    var errorDescription: String? {
        switch self {
        case .invalidShareCode:     return "Code invalide."
        case .rpc(let msg):         return msg
        }
    }
}

enum CounterShareService {

    // MARK: - Host

    /// Récupère (ou génère la 1re fois) le share_code du game. Réservé à
    /// l'owner par la policy de la RPC.
    static func getOrCreateShareCode(gameId: UUID) async throws -> String {
        struct Params: Encodable { let p_game_id: UUID }
        do {
            let code: String = try await SupabaseClientProvider.shared
                .rpc("get_or_create_share_code", params: Params(p_game_id: gameId))
                .execute()
                .value
            return code
        } catch {
            throw CounterShareError.rpc(error.localizedDescription)
        }
    }

    // MARK: - Joiner

    /// Résout un share_code en liste de seats (game stub + état des claims).
    /// Renvoie un tableau vide si le code est inconnu.
    static func lookup(shareCode: String) async throws -> [SharedGameSeat] {
        struct Params: Encodable { let p_share_code: String }
        let raw: [LookupRow] = try await SupabaseClientProvider.shared
            .rpc("lookup_share_code", params: Params(p_share_code: shareCode))
            .execute()
            .value
        if raw.isEmpty { throw CounterShareError.invalidShareCode }
        return raw.map { r in
            SharedGameSeat(
                gameId: r.game_id,
                mode: r.mode,
                linePrice: r.line_price,
                currency: r.currency,
                ownerDisplay: r.owner_display,
                createdAt: parseISO(r.created_at),
                seatIndex: r.seat_index,
                guestName: r.guest_name,
                claimedByUserId: r.claimed_by_user_id,
                claimedByDisplay: r.claimed_by_display,
                claimedByAvatar: r.claimed_by_avatar
            )
        }
    }

    @discardableResult
    static func claim(shareCode: String, seatIndex: Int) async throws -> UUID {
        struct Params: Encodable { let p_share_code: String; let p_seat_index: Int }
        do {
            let gameId: UUID = try await SupabaseClientProvider.shared
                .rpc("claim_seat", params: Params(p_share_code: shareCode, p_seat_index: seatIndex))
                .execute()
                .value
            return gameId
        } catch {
            throw CounterShareError.rpc(error.localizedDescription)
        }
    }

    static func unclaim(gameId: UUID) async throws {
        struct Params: Encodable { let p_game_id: UUID }
        do {
            try await SupabaseClientProvider.shared
                .rpc("unclaim_seat", params: Params(p_game_id: gameId))
                .execute()
        } catch {
            throw CounterShareError.rpc(error.localizedDescription)
        }
    }

    // MARK: - Placeholder users

    /// Crée un placeholder côté Supabase pour un joueur sans compte. Le
    /// caller devient `created_by`. Retourne l'UUID du placeholder à stocker
    /// dans `Counter.cloudSeatMapJSON`.
    static func createPlaceholder(displayName: String) async throws -> UUID {
        struct Params: Encodable { let p_display_name: String }
        do {
            let id: UUID = try await SupabaseClientProvider.shared
                .rpc("create_placeholder_user", params: Params(p_display_name: displayName))
                .execute()
                .value
            return id
        } catch {
            throw CounterShareError.rpc(error.localizedDescription)
        }
    }

    // MARK: - Deep links

    /// URL canonique pour partager un compteur. On utilise un lien HTTPS
    /// public (GitHub Pages) plutôt que le custom scheme directement —
    /// WhatsApp/Messages/Slack ne rendent cliquables que les `https://`,
    /// pas les schemes custom. La page de redirection saute aussitôt vers
    /// `com.sacha.bakarat://join/<CODE>` (deep link iOS).
    static func joinURL(forCode code: String) -> URL {
        let normalized = normalize(code)
        return URL(string: "https://sachacsc.github.io/Baccarat/join/?code=\(normalized)")!
    }

    // MARK: - Format helpers

    /// Découpe un code 6-char en "ABC-DEF" pour l'affichage.
    static func formatForDisplay(_ code: String) -> String {
        let trimmed = code.replacingOccurrences(of: "-", with: "").uppercased()
        guard trimmed.count == 6 else { return trimmed }
        let mid = trimmed.index(trimmed.startIndex, offsetBy: 3)
        return "\(trimmed[..<mid])-\(trimmed[mid...])"
    }

    /// Normalise un code saisi par l'utilisateur (retire tirets/espaces, uppercase).
    static func normalize(_ input: String) -> String {
        input
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: " ", with: "")
            .uppercased()
    }

    private static func parseISO(_ s: String?) -> Date? {
        guard let s else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }
}

// MARK: - DTOs RPC (internes)

private struct LookupRow: Decodable {
    let game_id: UUID
    let mode: String
    let line_price: Double
    let currency: String
    let owner_display: String?
    let created_at: String?
    let seat_index: Int
    let guest_name: String?
    let claimed_by_user_id: UUID?
    let claimed_by_display: String?
    let claimed_by_avatar: String?
}
