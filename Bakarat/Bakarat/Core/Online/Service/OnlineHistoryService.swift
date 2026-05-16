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
import Realtime

@MainActor
final class OnlineHistoryService: ObservableObject {
    @Published var games: [GameHistoryItem] = []
    @Published var isLoading = false
    @Published var loadError: String?

    private let client = SupabaseClientProvider.shared

    // Live updates (Realtime postgres_changes)
    private var realtimeChannel: RealtimeChannelV2?
    private var subscribeTasks: [Task<Void, Never>] = []
    private var debounceTask: Task<Void, Never>?
    private var currentUserId: UUID?

    func load(myUserId: UUID) async {
        isLoading = true
        loadError = nil
        defer { isLoading = false }
        let userTag = myUserId.uuidString.prefix(8)

        do {
            // Étape 1 : récupère mes seats par game_id.
            let myParticipations: [GameParticipantRow] = try await client
                .from("game_participants")
                .select("game_id,seat_index")
                .eq("user_id", value: myUserId.uuidString)
                .execute()
                .value

            #if DEBUG
            print("[OnlineHistoryService] load(\(userTag)) — found \(myParticipations.count) participations")
            #endif

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
                    id,status,line_price,currency,created_at,finished_at,last_active_at,mode,
                    manches(id,manche_number,created_at,manche_results(seat_index,delta))
                    """)
                .in("id", values: gameIds.map { $0.uuidString })
                .eq("mode", value: "online")
                .order("last_active_at", ascending: false)
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
                    lastActiveAt: parseDate(row.last_active_at),
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
            #if DEBUG
            let ongoing = games.filter { $0.isOngoing }.count
            print("[OnlineHistoryService] load(\(userTag)) DONE — \(games.count) games (\(ongoing) en cours)")
            #endif
        } catch {
            loadError = error.localizedDescription
            games = []
            #if DEBUG
            print("[OnlineHistoryService] load(\(userTag)) FAILED: \(error)")
            #endif
        }
    }

    // MARK: - Live updates (Supabase Realtime)

    /// Ouvre un channel Realtime qui écoute les INSERT/UPDATE sur les tables
    /// games, manches, manche_results, game_participants. RLS filtre déjà :
    /// on ne reçoit que les events pour les parties auxquelles on participe.
    /// À chaque event, on debounce 500ms puis on relance un `load()` complet.
    func startLiveUpdates(myUserId: UUID) async {
        // Évite les doubles subscriptions.
        if let active = currentUserId, active == myUserId, realtimeChannel != nil {
            return
        }
        await stopLiveUpdates()
        currentUserId = myUserId

        let channelName = "history-\(myUserId.uuidString.prefix(8))"
        let ch = client.realtimeV2.channel(channelName)
        realtimeChannel = ch

        // Bind les streams AVANT subscribe.
        let tables = ["games", "manches", "manche_results", "game_participants"]
        var streams: [(table: String, stream: AsyncStream<AnyAction>)] = []
        for table in tables {
            let s = ch.postgresChange(AnyAction.self, schema: "public", table: table)
            streams.append((table, s))
        }

        do {
            try await ch.subscribeWithError()
            #if DEBUG
            print("[OnlineHistoryService] live channel subscribed: \(channelName)")
            #endif
        } catch {
            #if DEBUG
            print("[OnlineHistoryService] subscribe failed: \(error)")
            #endif
            return
        }

        for (table, stream) in streams {
            let task = Task { [weak self] in
                for await _ in stream {
                    #if DEBUG
                    print("[OnlineHistoryService] event on \(table) → reload scheduled")
                    #endif
                    await self?.scheduleReload()
                }
            }
            subscribeTasks.append(task)
        }
    }

    /// Ferme le channel + cancel les tâches d'écoute. Idempotent.
    func stopLiveUpdates() async {
        debounceTask?.cancel()
        debounceTask = nil
        for t in subscribeTasks { t.cancel() }
        subscribeTasks = []
        if let ch = realtimeChannel {
            await ch.unsubscribe()
        }
        realtimeChannel = nil
        currentUserId = nil
    }

    private func scheduleReload() {
        debounceTask?.cancel()
        let uid = currentUserId
        debounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard let self, !Task.isCancelled, let uid else { return }
            await self.load(myUserId: uid)
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
    let last_active_at: String?
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
    let lastActiveAt: Date?
    let myBalance: Double
    let numManches: Int
    let numParticipants: Int

    /// "En cours" : status active ET un heartbeat reçu il y a < 5 min.
    /// Le `last_active_at` est bump par les clients connectés toutes les 30s,
    /// donc absence de bump = plus personne dans le salon.
    var isOngoing: Bool {
        guard status == "active" else { return false }
        let lastSignal = lastActiveAt ?? lastMancheAt ?? createdAt
        return Date().timeIntervalSince(lastSignal) < 5 * 60
    }
}
