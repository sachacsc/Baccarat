//
//  OnlineHistoryService.swift
//  Bakarat
//
//  Récupère depuis Supabase la liste des parties online auxquelles
//  l'utilisateur courant a participé, avec son solde cumulé par partie.
//
//  Stratégie : un select embarqué sur `games` joint à `game_participants`
//  (filtré sur user_id = me) puis joint à `manches → manche_results`. La
//  somme des deltas pour le seat de l'utilisateur est calculée côté Swift
//  (Postgrest ne permet pas l'aggrégation conditionnelle dans un select).
//

import Foundation
import Combine
import Supabase

@MainActor
final class OnlineHistoryService: ObservableObject {
    @Published var games: [GameHistoryItem] = []
    @Published var isLoading = false
    @Published var loadError: String?

    private let client = SupabaseClientProvider.shared

    func load(myUserId: UUID) async {
        isLoading = true
        loadError = nil
        defer { isLoading = false }

        do {
            // Étape 1 : récupère mes seats par game_id.
            let myParticipations: [GameParticipantRow] = try await client
                .from("game_participants")
                .select("game_id,seat_index")
                .eq("user_id", value: myUserId.uuidString)
                .execute()
                .value

            guard !myParticipations.isEmpty else {
                games = []
                return
            }

            let gameIds = myParticipations.map { $0.game_id }
            let mySeatByGame = Dictionary(
                uniqueKeysWithValues: myParticipations.map { ($0.game_id, $0.seat_index) }
            )

            // Étape 2 : games joint manches joint manche_results, filtrés sur mes games.
            let gameRows: [GameRow] = try await client
                .from("games")
                .select("""
                    id,status,line_price,currency,created_at,finished_at,mode,
                    manches(id,manche_number,created_at,manche_results(seat_index,delta))
                    """)
                .in("id", values: gameIds.map { $0.uuidString })
                .eq("mode", value: "online")
                .order("created_at", ascending: false)
                .execute()
                .value

            // Étape 3 : nombre de participants par game (compte côté Postgrest).
            //          Postgrest ne renvoie pas count(distinct), donc on compte les rows.
            let participantsRows: [GameParticipantBasicRow] = try await client
                .from("game_participants")
                .select("game_id")
                .in("game_id", values: gameIds.map { $0.uuidString })
                .execute()
                .value
            var participantCount: [UUID: Int] = [:]
            for r in participantsRows {
                participantCount[r.game_id, default: 0] += 1
            }

            // Étape 4 : agrégation finale.
            let items: [GameHistoryItem] = gameRows.compactMap { row in
                guard let mySeat = mySeatByGame[row.id] else { return nil }
                var myBalance: Double = 0
                var lastMancheDate: Date? = nil
                var numManches = 0
                for m in row.manches ?? [] {
                    numManches += 1
                    if let mr = m.manche_results.first(where: { $0.seat_index == mySeat }) {
                        myBalance += mr.delta
                    }
                    let date = parseDate(m.created_at)
                    if let d = date {
                        if let prev = lastMancheDate {
                            lastMancheDate = max(prev, d)
                        } else {
                            lastMancheDate = d
                        }
                    }
                }
                return GameHistoryItem(
                    id: row.id,
                    status: row.status,
                    linePrice: row.line_price,
                    currency: row.currency,
                    createdAt: parseDate(row.created_at) ?? .now,
                    finishedAt: row.finished_at.flatMap { parseDate($0) },
                    lastMancheAt: lastMancheDate,
                    myBalance: myBalance,
                    numManches: numManches,
                    numParticipants: participantCount[row.id] ?? 0
                )
            }

            // Tri : "en cours" d'abord (récent), puis terminées.
            games = items.sorted { a, b in
                if a.isOngoing != b.isOngoing { return a.isOngoing }
                let aD = a.lastMancheAt ?? a.createdAt
                let bD = b.lastMancheAt ?? b.createdAt
                return aD > bD
            }
        } catch {
            loadError = error.localizedDescription
            games = []
            #if DEBUG
            print("[OnlineHistoryService] load failed: \(error)")
            #endif
        }
    }

    private func parseDate(_ s: String?) -> Date? {
        guard let s else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = formatter.date(from: s) { return d }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: s)
    }
}

// MARK: - DTOs Postgrest

private struct GameParticipantRow: Decodable {
    let game_id: UUID
    let seat_index: Int
}

private struct GameParticipantBasicRow: Decodable {
    let game_id: UUID
}

private struct GameRow: Decodable {
    let id: UUID
    let status: String
    let line_price: Double
    let currency: String
    let created_at: String
    let finished_at: String?
    let mode: String
    let manches: [MancheRow]?
}

private struct MancheRow: Decodable {
    let id: UUID
    let manche_number: Int
    let created_at: String
    let manche_results: [MancheResultRow]
}

private struct MancheResultRow: Decodable {
    let seat_index: Int
    let delta: Double
}

// MARK: - Modèle public

struct GameHistoryItem: Identifiable, Hashable {
    let id: UUID
    let status: String
    let linePrice: Double
    let currency: String
    let createdAt: Date
    let finishedAt: Date?
    let lastMancheAt: Date?
    let myBalance: Double
    let numManches: Int
    let numParticipants: Int

    /// Heuristique "en cours" : status active ET dernière manche < 24h
    /// (les games "active" sans manche récente sont en pratique abandonnées).
    var isOngoing: Bool {
        guard status == "active" else { return false }
        guard let last = lastMancheAt else {
            // Pas encore de manche : on regarde la date de création.
            return Date().timeIntervalSince(createdAt) < 24 * 3600
        }
        return Date().timeIntervalSince(last) < 24 * 3600
    }
}
