//
//  CounterCloudSync.swift
//  Bakarat
//
//  Sérialise une CounterManche locale en payload `record_manche` et l'envoie
//  à Supabase. Idempotent côté serveur (RPC `on conflict (game_id,
//  manche_number) do nothing`). À la première validation, crée la row `games`
//  + les `game_participants` ; les fois suivantes, ajoute juste la manche.
//
//  Auto-bind du host : si un seat porte un name correspondant au
//  display_name du user loggué (trimmed, case-insensitive), c'est ce seat
//  qui reçoit son `user_id`. Sinon, on tombe sur le seat 0. Sans cet
//  attachement, les manches du compteur ne contribuent à AUCUNE dette
//  côté Dettes (le mapping seat→user_id reste vide). Le user peut toujours
//  corriger via ShareCounterSheet → "C'est moi".
//
//  Tolérant aux erreurs : fire-and-forget côté UI, mais on remonte l'erreur
//  au caller s'il veut l'afficher.
//

import Foundation
import SwiftData
import Supabase

@MainActor
enum CounterCloudSync {

    /// Pousse une manche validée vers le cloud. Rattrape AVANT toute manche
    /// précédente du même compteur qui n'aurait pas encore été syncée
    /// (cas : validation offline puis retour en ligne — sans ça, les
    /// manches plus récentes créeraient une game avec un manche_number
    /// décalé). Met à jour `counter.cloudGameId` à la 1re sync réussie.
    @discardableResult
    static func pushManche(
        counter: Counter,
        manche: CounterManche,
        authUserId: UUID,
        authDisplayName: String?,
        modelContext: ModelContext
    ) async throws -> UUID {
        // Rattrape les manches précédentes non-syncées dans l'ordre.
        let pending = counter.manches
            .filter { !$0.isSyncedToCloud && $0.id != manche.id }
            .sorted { $0.number < $1.number }
        for m in pending {
            try await pushOne(
                counter: counter,
                manche: m,
                authUserId: authUserId,
                authDisplayName: authDisplayName,
                modelContext: modelContext
            )
        }
        return try await pushOne(
            counter: counter,
            manche: manche,
            authUserId: authUserId,
            authDisplayName: authDisplayName,
            modelContext: modelContext
        )
    }

    /// Rattrape silencieusement TOUTES les manches non-syncées du compteur.
    /// Appelé à `onAppear` de CounterDetailView pour récupérer les manches
    /// jouées offline. Différé en best-effort — erreur silencieuse.
    static func resyncPending(
        counter: Counter,
        authUserId: UUID,
        authDisplayName: String?,
        modelContext: ModelContext
    ) async {
        let pending = counter.manches
            .filter { !$0.isSyncedToCloud }
            .sorted { $0.number < $1.number }
        for m in pending {
            do {
                try await pushOne(
                    counter: counter,
                    manche: m,
                    authUserId: authUserId,
                    authDisplayName: authDisplayName,
                    modelContext: modelContext
                )
            } catch {
                // Si une manche échoue, on arrête : les suivantes
                // dépendent de l'ordre de manche_number côté RPC.
                #if DEBUG
                print("[CounterCloudSync] resyncPending stopped at #\(m.number): \(error)")
                #endif
                return
            }
        }
    }

    /// Push une seule manche. Idempotent côté RPC (on conflict do nothing).
    @discardableResult
    private static func pushOne(
        counter: Counter,
        manche: CounterManche,
        authUserId: UUID,
        authDisplayName: String?,
        modelContext: ModelContext
    ) async throws -> UUID {
        let participants = buildParticipants(
            counter: counter,
            authUserId: authUserId,
            authDisplayName: authDisplayName
        )
        let boardResults = buildBoardResults(manche: manche)
        let resultsPerSeat = buildResultsPerSeat(counter: counter, manche: manche)
        let fullBoardSeat = manche.boardResults.first(where: { $0.isFullBoard })?.winnerSeat
        let numActive = counter.activePlayersOrdered.count
        let currencyISO = mapCurrency(counter.currency)

        let params = RecordMancheParams(
            p_game_id: counter.cloudGameId,
            p_mode: "counter",
            p_line_price: counter.linePrice,
            p_currency: currencyISO,
            p_settings_json: EmptySettings(),
            p_participants: participants,
            p_manche_number: manche.number,
            p_dealer_seat: manche.dealerSeat,
            p_num_active: numActive,
            p_board_results: boardResults,
            p_full_board_seat: fullBoardSeat,
            p_results_per_seat: resultsPerSeat
        )

        let gameId: UUID = try await SupabaseClientProvider.shared
            .rpc("record_manche", params: params)
            .execute()
            .value

        if counter.cloudGameId == nil {
            counter.cloudGameId = gameId
        }
        manche.isSyncedToCloud = true
        try? modelContext.save()
        return gameId
    }

    // MARK: - Build payloads

    private static func buildParticipants(
        counter: Counter,
        authUserId: UUID,
        authDisplayName: String?
    ) -> [Participant] {
        let players = counter.playersOrdered
        // hostSeat est explicite (choisi via picker "C'est moi"). Fallback
        // seat 0 si nil (compteurs legacy) — l'utilisateur peut corriger via
        // ShareCounterSheet.
        let hostSeat = counter.hostSeatIndex ?? players.first?.seat ?? 0
        let placeholders = counter.placeholderIdsBySeat

        return players.map { p in
            if p.seat == hostSeat {
                // Le siège du host : user_id = compte loggué, label conservé.
                return Participant(
                    seat_index: p.seat,
                    user_id: authUserId,
                    placeholder_id: nil,
                    guest_name: p.name
                )
            } else if let placeholderId = placeholders[p.seat] {
                // Siège d'un autre joueur attaché à un placeholder.
                return Participant(
                    seat_index: p.seat,
                    user_id: nil,
                    placeholder_id: placeholderId,
                    guest_name: p.name
                )
            } else {
                // Fallback : pas de placeholder créé (compteur legacy) → guest pur.
                return Participant(
                    seat_index: p.seat,
                    user_id: nil,
                    placeholder_id: nil,
                    guest_name: p.name
                )
            }
        }
    }

    private static func buildBoardResults(manche: CounterManche) -> [BoardResultPayload] {
        manche.boardResults.enumerated().map { (idx, r) in
            BoardResultPayload(
                board_num: idx + 1,
                winner_seat: r.winnerSeat,
                multi: r.multi,
                is_split: r.splitterSeats != nil,
                splitter_seats: r.splitterSeats,
                final_winner_seat: r.winnerSeat,
                final_multi: r.multi
            )
        }
    }

    private static func buildResultsPerSeat(counter: Counter, manche: CounterManche) -> [SeatResultPayload] {
        let deltas = manche.perPlayerDeltas
        return counter.playersOrdered.compactMap { p in
            guard let d = deltas[p.seat] else { return nil }
            return SeatResultPayload(seat_index: p.seat, delta: d)
        }
    }

    /// Convertit la devise stockée localement (symbole "€") vers son code ISO
    /// attendu par la DB. Conservatif : tout symbole inconnu → "EUR" pour
    /// éviter un rejet côté serveur.
    private static func mapCurrency(_ symbol: String) -> String {
        switch symbol {
        case "€":  return "EUR"
        case "$":  return "USD"
        case "£":  return "GBP"
        case "CHF": return "CHF"
        default:
            // Si c'est déjà un code ISO 3 lettres, on le garde tel quel.
            if symbol.count == 3, symbol.uppercased() == symbol { return symbol }
            return "EUR"
        }
    }
}

// MARK: - RPC params

private struct RecordMancheParams: Encodable {
    let p_game_id: UUID?
    let p_mode: String
    let p_line_price: Double
    let p_currency: String
    let p_settings_json: EmptySettings
    let p_participants: [Participant]
    let p_manche_number: Int
    let p_dealer_seat: Int
    let p_num_active: Int
    let p_board_results: [BoardResultPayload]
    let p_full_board_seat: Int?
    let p_results_per_seat: [SeatResultPayload]

    enum CodingKeys: String, CodingKey {
        case p_game_id, p_mode, p_line_price, p_currency, p_settings_json,
             p_participants, p_manche_number, p_dealer_seat, p_num_active,
             p_board_results, p_full_board_seat, p_results_per_seat
    }

    /// ⚠️ encode `null` explicite (pas `encodeIfPresent`) — sinon PostgREST
    /// ne trouve pas la signature à 12 paramètres (PGRST202 "function not
    /// found in schema cache"). Même contrainte que `OnlineGameService`.
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(p_game_id, forKey: .p_game_id)
        try c.encode(p_mode, forKey: .p_mode)
        try c.encode(p_line_price, forKey: .p_line_price)
        try c.encode(p_currency, forKey: .p_currency)
        try c.encode(p_settings_json, forKey: .p_settings_json)
        try c.encode(p_participants, forKey: .p_participants)
        try c.encode(p_manche_number, forKey: .p_manche_number)
        try c.encode(p_dealer_seat, forKey: .p_dealer_seat)
        try c.encode(p_num_active, forKey: .p_num_active)
        try c.encode(p_board_results, forKey: .p_board_results)
        try c.encode(p_full_board_seat, forKey: .p_full_board_seat)
        try c.encode(p_results_per_seat, forKey: .p_results_per_seat)
    }
}

private struct EmptySettings: Encodable {}

private struct Participant: Encodable {
    let seat_index: Int
    let user_id: UUID?
    let placeholder_id: UUID?
    let guest_name: String?
}

private struct BoardResultPayload: Encodable {
    let board_num: Int
    let winner_seat: Int?
    let multi: Int
    let is_split: Bool
    let splitter_seats: [Int]?
    let final_winner_seat: Int?
    let final_multi: Int?
}

private struct SeatResultPayload: Encodable {
    let seat_index: Int
    let delta: Double
}
