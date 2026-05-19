//
//  OnlineGameEditService.swift
//  Bakarat
//
//  Fetch + edit cloud-side d'une game online : liste des manches avec
//  board_results + per-seat deltas, list des participants (incl. avatars),
//  et wrappers RPC pour update_online_manche, record_online_adjustment,
//  delete_online_manche.
//
//  Utilisé par CloudSessionDetailView (liste des manches) et ses sheets
//  d'édition (EditOnlineMancheSheet, OnlineAdjustmentSheet).
//

import Foundation
import Combine
import Supabase

// MARK: - Domain models

/// Multiplicateur d'un board en mode online. Calque CounterMulti.
enum OnlineMulti: Int, CaseIterable, Identifiable, Codable {
    case x1 = 1
    case x8 = 8
    case x16 = 16
    case x20 = 20

    var id: Int { rawValue }
    var displayLabel: String { "×\(rawValue)" }

    static func from(_ raw: Int) -> OnlineMulti {
        OnlineMulti(rawValue: raw) ?? .x1
    }
}

/// Résultat d'un board pour l'édition. Une seule winner-seat (pas de split
/// dans l'éditeur — l'édition manuelle écrase la structure de split).
struct OnlineBoardEdit: Identifiable, Equatable {
    let id: Int                  // 0, 1, 2 — board index
    var winnerSeat: Int?         // nil = abandoned
    var multi: OnlineMulti = .x1
}

/// Participant d'une game (lien game_participants + profile pour affichage).
struct OnlineGameParticipant: Identifiable, Hashable {
    let seat: Int
    let userId: UUID?            // nil = guest ou siège libéré
    let displayName: String      // affichage (display_name, guest_name, ou "Seat N")
    let avatarUrl: String?

    var id: Int { seat }
}

/// Manche d'une game online (cloud-side) avec données dénormalisées pour l'UI.
struct OnlineMancheRow: Identifiable, Hashable {
    let id: UUID                 // manche_id
    let mancheNumber: Int        // négatif = adjustment
    let dealerSeat: Int
    let createdAt: Date
    let kind: String             // "normal" | "adjustment"
    /// Résultat par board (3 entrées en normal, vide en adjustment).
    var boardResults: [BoardResultRow]
    /// Seat → delta financier pour cette manche.
    var perSeatDeltas: [Int: Double]
    /// Full board winner (seat) si applicable.
    var fullBoardSeat: Int?

    var isAdjustment: Bool { kind == "adjustment" }

    struct BoardResultRow: Hashable, Codable {
        let board_num: Int
        let final_winner_seat: Int?
        let final_multi: Int
        let is_split: Bool
        let splitter_seats: [Int]
    }
}

// MARK: - Service

@MainActor
final class OnlineGameEditService: ObservableObject {
    @Published private(set) var manches: [OnlineMancheRow] = []
    @Published private(set) var participants: [OnlineGameParticipant] = []
    @Published private(set) var linePrice: Double = 2.5
    @Published private(set) var currency: String = "EUR"
    @Published private(set) var isLoading = false
    @Published var loadError: String?

    private let client = SupabaseClientProvider.shared

    // MARK: - Fetch

    func load(gameId: UUID) async {
        isLoading = true
        loadError = nil
        defer { isLoading = false }

        do {
            // 1) Game (linePrice, currency)
            let game: GameDTO = try await client
                .from("games")
                .select("id,line_price,currency")
                .eq("id", value: gameId.uuidString)
                .single()
                .execute()
                .value
            self.linePrice = game.line_price
            self.currency  = game.currency

            // 2) Participants + profiles
            let parts: [PartDTO] = try await client
                .from("game_participants")
                .select("seat_index,user_id,guest_name")
                .eq("game_id", value: gameId.uuidString)
                .execute()
                .value

            let loggedUids = parts.compactMap { $0.user_id }
            var profilesByUid: [UUID: ProfileDTO] = [:]
            if !loggedUids.isEmpty {
                let profs: [ProfileDTO] = try await client
                    .from("profiles")
                    .select("user_id,display_name,avatar_url")
                    .in("user_id", values: loggedUids.map { $0.uuidString })
                    .execute()
                    .value
                profilesByUid = Dictionary(uniqueKeysWithValues: profs.map { ($0.user_id, $0) })
            }

            self.participants = parts
                .sorted { $0.seat_index < $1.seat_index }
                .map { p in
                    let prof = p.user_id.flatMap { profilesByUid[$0] }
                    let name = prof?.display_name
                        ?? p.guest_name
                        ?? "Seat \(p.seat_index + 1)"
                    return OnlineGameParticipant(
                        seat: p.seat_index,
                        userId: p.user_id,
                        displayName: name,
                        avatarUrl: prof?.avatar_url
                    )
                }

            // 3) Manches + manche_results
            let manchesDTO: [MancheDTO] = try await client
                .from("manches")
                .select("id,manche_number,dealer_seat,kind,board_results,full_board_seat,created_at,manche_results(seat_index,delta)")
                .eq("game_id", value: gameId.uuidString)
                .order("manche_number", ascending: true)
                .execute()
                .value

            self.manches = manchesDTO.map { m in
                let boards: [OnlineMancheRow.BoardResultRow] = (m.board_results ?? [])
                    .compactMap { (raw: BoardResultRaw) in
                        OnlineMancheRow.BoardResultRow(
                            board_num: raw.board_num ?? 0,
                            final_winner_seat: raw.final_winner_seat ?? raw.winner_seat,
                            final_multi: raw.final_multi ?? raw.multi ?? 1,
                            is_split: raw.is_split ?? false,
                            splitter_seats: raw.splitter_seats ?? []
                        )
                    }
                var deltas: [Int: Double] = [:]
                for r in m.manche_results { deltas[r.seat_index] = r.delta }
                return OnlineMancheRow(
                    id: m.id,
                    mancheNumber: m.manche_number,
                    dealerSeat: m.dealer_seat ?? 0,
                    createdAt: Self.parseDate(m.created_at) ?? .distantPast,
                    kind: m.kind ?? "normal",
                    boardResults: boards,
                    perSeatDeltas: deltas,
                    fullBoardSeat: m.full_board_seat
                )
            }
        } catch {
            loadError = error.localizedDescription
            #if DEBUG
            print("[OnlineGameEditService] load FAILED: \(error)")
            #endif
        }
    }

    // MARK: - RPC wrappers

    /// Update a manche (board_results + per-seat deltas). Reverts old balances,
    /// updates the row, applies new balances.
    func updateManche(mancheId: UUID,
                      boardResults: [BoardResultRaw],
                      fullBoardSeat: Int?,
                      perSeatDeltas: [Int: Double]) async throws {
        struct Params: Encodable {
            let p_manche_id: UUID
            let p_board_results: [BoardResultRaw]
            let p_full_board_seat: Int?
            let p_results_per_seat: [SeatDelta]
        }
        struct SeatDelta: Encodable {
            let seat_index: Int
            let delta: Double
            let boards_won_json: [BoardWon]
        }
        struct BoardWon: Encodable {
            let board_num: Int
            let multi: Int
        }
        // Recompute boards_won_json from boardResults
        var boardsWonBySeat: [Int: [BoardWon]] = [:]
        for b in boardResults {
            if let w = b.final_winner_seat ?? b.winner_seat {
                boardsWonBySeat[w, default: []].append(
                    BoardWon(board_num: b.board_num ?? 0,
                             multi: b.final_multi ?? b.multi ?? 1)
                )
            }
        }
        let resultsPerSeat = perSeatDeltas.map { (seat, delta) in
            SeatDelta(seat_index: seat, delta: delta,
                      boards_won_json: boardsWonBySeat[seat] ?? [])
        }
        let params = Params(
            p_manche_id: mancheId,
            p_board_results: boardResults,
            p_full_board_seat: fullBoardSeat,
            p_results_per_seat: resultsPerSeat
        )
        try await client.rpc("update_online_manche", params: params).execute()
    }

    /// Records an adjustment manche : pairwise transfers + per-seat deltas.
    @discardableResult
    func recordAdjustment(gameId: UUID,
                          transfers: [AdjustmentTransfer],
                          perSeatDeltas: [Int: Double]) async throws -> UUID {
        struct Params: Encodable {
            let p_game_id: UUID
            let p_transfers: [AdjustmentTransfer]
            let p_results_per_seat: [SeatDelta]
        }
        struct SeatDelta: Encodable {
            let seat_index: Int
            let delta: Double
            let boards_won_json: [Int]  // always empty
        }
        let resultsPerSeat = perSeatDeltas.map { (seat, delta) in
            SeatDelta(seat_index: seat, delta: delta, boards_won_json: [])
        }
        let params = Params(
            p_game_id: gameId,
            p_transfers: transfers,
            p_results_per_seat: resultsPerSeat
        )
        let resp = try await client.rpc("record_online_adjustment", params: params).execute()
        let id = try JSONDecoder().decode(UUID.self, from: resp.data)
        return id
    }

    /// Delete a manche : reverts its balances and removes the row.
    func deleteManche(mancheId: UUID) async throws {
        struct Params: Encodable { let p_manche_id: UUID }
        try await client.rpc("delete_online_manche", params: Params(p_manche_id: mancheId)).execute()
    }

    // MARK: - Helpers

    private static func parseDate(_ s: String?) -> Date? {
        guard let s else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }
}

// MARK: - DTOs

/// Raw board entry as stored in manches.board_results (jsonb). The shape
/// matches what the SQL trigger reads. Encodable so the edit sheet can
/// rewrite it directly.
struct BoardResultRaw: Codable, Hashable {
    let board_num: Int?
    let winner_seat: Int?           // legacy field name (= final winner when no split)
    let final_winner_seat: Int?     // canonical : the actual winner after tie-breaks
    let multi: Int?                 // legacy field name (= announce multi)
    let final_multi: Int?           // canonical : multi used for scoring
    let is_split: Bool?
    let splitter_seats: [Int]?
}

struct AdjustmentTransfer: Codable, Hashable {
    let from_seat: Int
    let to_seat: Int
    let amount: Double
}

private struct GameDTO: Decodable {
    let id: UUID
    let line_price: Double
    let currency: String
}

private struct PartDTO: Decodable {
    let seat_index: Int
    let user_id: UUID?
    let guest_name: String?
}

private struct ProfileDTO: Decodable {
    let user_id: UUID
    let display_name: String?
    let avatar_url: String?
}

private struct MancheDTO: Decodable {
    let id: UUID
    let manche_number: Int
    let dealer_seat: Int?
    let kind: String?
    let board_results: [BoardResultRaw]?
    let full_board_seat: Int?
    let created_at: String?
    let manche_results: [MancheResultDTO]
}

private struct MancheResultDTO: Decodable {
    let seat_index: Int
    let delta: Double
}
