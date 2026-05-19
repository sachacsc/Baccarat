//
//  SessionsService.swift
//  Bakarat
//
//  Agrège TOUTES les parties cloud dont je suis participant — online ET
//  compteur — pour alimenter l'onglet fusionné "Comptes". Diffère de
//  `OnlineHistoryService` sur deux points :
//   1. Aucun filtre de mode (online + counter dans la même liste).
//   2. Renseigne `iAmOwner` + le nom du host pour distinguer "mes compteurs"
//      vs "ceux que j'ai rejoints via un share code".
//
//  Live updates : pattern identique aux autres services (debounce 400ms).
//

import Foundation
import Combine
import Supabase
import Realtime

struct CloudSession: Identifiable, Hashable {
    let gameId: UUID
    let mode: String              // "online" | "counter"
    let status: String            // "active" | "finished" | "abandoned"
    let ownerUserId: UUID
    let ownerDisplay: String?
    let ownerAvatarUrl: String?
    let createdAt: Date
    let lastMancheAt: Date?
    let linePrice: Double
    let currency: String

    let myBalance: Double         // somme de mes deltas
    let numManches: Int
    let numParticipants: Int
    let mySeatIndex: Int?
    let iAmOwner: Bool

    var id: UUID { gameId }

    var lastActivity: Date { lastMancheAt ?? createdAt }
}

@MainActor
final class SessionsService: ObservableObject {
    @Published private(set) var sessions: [CloudSession] = []
    @Published var isLoading = false
    @Published var loadError: String?

    private let client = SupabaseClientProvider.shared
    private var realtimeChannel: RealtimeChannelV2?
    private var subscribeTasks: [Task<Void, Never>] = []
    private var debounceTask: Task<Void, Never>?
    private var currentUserId: UUID?

    // MARK: - Load

    func load(myUserId: UUID) async {
        isLoading = true
        loadError = nil
        defer { isLoading = false }

        do {
            // 1) Mes participations → game_ids
            let myParts: [PartRow] = try await client
                .from("game_participants")
                .select("game_id,seat_index")
                .eq("user_id", value: myUserId.uuidString)
                .execute()
                .value

            guard !myParts.isEmpty else { sessions = []; return }
            let gameIds = Array(Set(myParts.map { $0.game_id }))
            let mySeatByGame = Dictionary(uniqueKeysWithValues: myParts.map { ($0.game_id, $0.seat_index) })

            // 2) Embedded join : games + participants + manches + results
            let games: [GameRow] = try await client
                .from("games")
                .select("""
                    id,mode,status,owner_user_id,line_price,currency,created_at,
                    manches(id,created_at,manche_results(seat_index,delta)),
                    game_participants(seat_index,user_id,guest_name)
                    """)
                .in("id", values: gameIds.map { $0.uuidString })
                .execute()
                .value

            // 3) Profils des owners (pour afficher "Partie de Sacha")
            let ownerIds = Array(Set(games.map { $0.owner_user_id }))
            let owners: [OwnerProfileRow] = try await client
                .from("profiles")
                .select("user_id,display_name,avatar_url")
                .in("user_id", values: ownerIds.map { $0.uuidString })
                .execute()
                .value
            let ownerByUid = Dictionary(uniqueKeysWithValues: owners.map { ($0.user_id, $0) })

            // 4) Build CloudSession items
            let items: [CloudSession] = games.compactMap { g in
                guard let mySeat = mySeatByGame[g.id] else { return nil }
                var myBalance: Double = 0
                var lastMancheDate: Date?
                for m in g.manches ?? [] {
                    if let mr = m.manche_results.first(where: { $0.seat_index == mySeat }) {
                        myBalance += mr.delta
                    }
                    if let d = parseDate(m.created_at) {
                        if let prev = lastMancheDate { lastMancheDate = max(prev, d) }
                        else { lastMancheDate = d }
                    }
                }
                let owner = ownerByUid[g.owner_user_id]
                return CloudSession(
                    gameId: g.id,
                    mode: g.mode,
                    status: g.status,
                    ownerUserId: g.owner_user_id,
                    ownerDisplay: owner?.display_name,
                    ownerAvatarUrl: owner?.avatar_url,
                    createdAt: parseDate(g.created_at) ?? .distantPast,
                    lastMancheAt: lastMancheDate,
                    linePrice: g.line_price,
                    currency: g.currency,
                    myBalance: myBalance,
                    numManches: g.manches?.count ?? 0,
                    numParticipants: g.game_participants?.count ?? 0,
                    mySeatIndex: mySeat,
                    iAmOwner: g.owner_user_id == myUserId
                )
            }

            // Filtre : un lobby online créé sans manche jouée n'a rien à
            // raconter, on ne le surface pas. Les compteurs sont créés en
            // cloud uniquement à la 1re manche, donc pas de filtre côté counter.
            sessions = items
                .filter { !($0.mode == "online" && $0.numManches == 0) }
                .sorted { $0.lastActivity > $1.lastActivity }
        } catch {
            loadError = error.localizedDescription
            #if DEBUG
            print("[SessionsService] load FAILED: \(error)")
            #endif
        }
    }

    // MARK: - Live updates

    func startLiveUpdates(myUserId: UUID) async {
        if currentUserId == myUserId, realtimeChannel != nil { return }
        await stopLiveUpdates()
        currentUserId = myUserId

        let ch = client.realtimeV2.channel("sessions-\(myUserId.uuidString.prefix(8))")
        realtimeChannel = ch
        let tables = ["games", "manches", "manche_results", "game_participants"]
        var streams: [AsyncStream<AnyAction>] = []
        for t in tables {
            streams.append(ch.postgresChange(AnyAction.self, schema: "public", table: t))
        }
        do { try await ch.subscribeWithError() }
        catch { return }
        for stream in streams {
            let task = Task { [weak self] in
                for await _ in stream { await self?.scheduleReload() }
            }
            subscribeTasks.append(task)
        }
        await load(myUserId: myUserId)
    }

    func stopLiveUpdates() async {
        debounceTask?.cancel(); debounceTask = nil
        for t in subscribeTasks { t.cancel() }
        subscribeTasks = []
        if let ch = realtimeChannel { await ch.unsubscribe() }
        realtimeChannel = nil
        currentUserId = nil
    }

    private func scheduleReload() {
        debounceTask?.cancel()
        let uid = currentUserId
        debounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard let self, !Task.isCancelled, let uid else { return }
            await self.load(myUserId: uid)
        }
    }

    private func parseDate(_ s: String?) -> Date? {
        guard let s else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }
}

// MARK: - DTOs Postgrest

private struct PartRow: Decodable {
    let game_id: UUID
    let seat_index: Int
}

private struct GameRow: Decodable {
    let id: UUID
    let mode: String
    let status: String
    let owner_user_id: UUID
    let line_price: Double
    let currency: String
    let created_at: String?
    let manches: [MancheRow]?
    let game_participants: [PartFullRow]?
}

private struct MancheRow: Decodable {
    let id: UUID
    let created_at: String?
    let manche_results: [MR]
}

private struct MR: Decodable {
    let seat_index: Int
    let delta: Double
}

private struct PartFullRow: Decodable {
    let seat_index: Int
    let user_id: UUID?
    let guest_name: String?
}

private struct OwnerProfileRow: Decodable {
    let user_id: UUID
    let display_name: String
    let avatar_url: String?
}
