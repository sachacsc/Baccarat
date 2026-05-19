//
//  DebtsService.swift
//  Bakarat
//
//  Source de vérité de l'onglet "Dettes". Fetch les parties où je suis loggé,
//  calcule pour chacune les transactions minimales (Tricount-min par roster
//  de la partie), retire celles déjà réglées dans `game_pair_settlements`,
//  et expose deux projections :
//
//   • `perPlayer` : agrégat par autre user (somme des montants signés)
//   • `perGame`   : liste GameDebt avec toutes les transactions me concernant
//
//  Cette instance est partagée (env object) entre l'onglet Dettes, l'historique
//  Online et la liste Compteur — ces deux derniers consomment `settledGameIds`
//  pour griser les rows "réglées".
//

import Foundation
import Combine
import Supabase
import Realtime

@MainActor
final class DebtsService: ObservableObject {
    @Published private(set) var perPlayer: [DebtAggregate] = []
    @Published private(set) var perGame:   [GameDebt] = []
    @Published private(set) var net: Double = 0
    @Published private(set) var totalIOwe: Double = 0
    @Published private(set) var totalOwedToMe: Double = 0
    /// gameIds entièrement réglés du POV du user courant. Source du greying
    /// dans Online history et Counter list.
    @Published private(set) var settledGameIds: Set<UUID> = []

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
        let tag = myUserId.uuidString.prefix(8)

        do {
            // 1) Mes participations → game_ids
            let myParticipations: [BasicParticipantRow] = try await client
                .from("game_participants")
                .select("game_id,seat_index")
                .eq("user_id", value: myUserId.uuidString)
                .execute()
                .value

            guard !myParticipations.isEmpty else {
                resetEmpty()
                return
            }
            let gameIds = Array(Set(myParticipations.map { $0.game_id }))

            // 2) Une seule grosse query : games + participants + manches + results
            let gameRows: [GameRow] = try await client
                .from("games")
                .select("""
                    id,mode,created_at,line_price,currency,
                    game_participants(seat_index,user_id,placeholder_id,guest_name),
                    manches(id,manche_results(seat_index,delta))
                    """)
                .in("id", values: gameIds.map { $0.uuidString })
                .execute()
                .value

            // 3) Settlements (RLS filtre déjà : moi en user_a OU user_b)
            let settlementRows: [SettlementRow] = try await client
                .from("game_pair_settlements")
                .select("game_id,user_a,user_b,settled_at,settled_by")
                .execute()
                .value
            // Index : (gameId, otherUserId) → true si réglé
            var settledLookup: [String: Bool] = [:]
            for s in settlementRows {
                let other = (s.user_a == myUserId) ? s.user_b : s.user_a
                settledLookup["\(s.game_id.uuidString)|\(other.uuidString)"] = true
            }

            // 4) Compute per-game Tricount-min, filtre les paiements me concernant
            var gameDebts: [GameDebt] = []
            var counterpartyIds = Set<UUID>()

            for g in gameRows {
                // Map seat_index → user_id (seuls les seats loggés contribuent).
                let participants = g.game_participants ?? []
                var seatToUser: [Int: UUID] = [:]
                // Un seat contribue dès qu'il a soit un user_id réel, soit un
                // placeholder_id. On unifie en "actor UUID" pour le calcul des
                // deltas. Le mapping seat → actor est ensuite passé à Tricount-min.
                for p in participants {
                    if let uid = p.user_id { seatToUser[p.seat_index] = uid }
                    else if let pid = p.placeholder_id { seatToUser[p.seat_index] = pid }
                }
                // Au moins 2 acteurs ET je suis bien dedans (sinon rien à régler).
                guard seatToUser.values.contains(myUserId), seatToUser.count >= 2 else { continue }

                // Agrégation des deltas par seat puis projection sur user_id.
                var deltasByUser: [UUID: Double] = [:]
                for m in g.manches ?? [] {
                    for r in m.manche_results {
                        guard let uid = seatToUser[r.seat_index] else { continue }
                        deltasByUser[uid, default: 0] += r.delta
                    }
                }
                guard deltasByUser.count >= 2 else { continue }

                // Tricount-min sur le roster de cette partie.
                let payments = TricountMin.settle(deltas: deltasByUser)

                // Garde uniquement ce qui me concerne.
                var myPayments: [GamePayment] = []
                for p in payments {
                    let direction: DebtDirection
                    let otherId: UUID
                    if p.payerUserId == myUserId {
                        direction = .iOwe
                        otherId = p.payeeUserId
                    } else if p.payeeUserId == myUserId {
                        direction = .owesMe
                        otherId = p.payerUserId
                    } else {
                        continue
                    }
                    let key = "\(g.id.uuidString)|\(otherId.uuidString)"
                    let isSettled = settledLookup[key] == true
                    myPayments.append(GamePayment(
                        gameId: g.id,
                        otherUserId: otherId,
                        amount: p.amount,
                        direction: direction,
                        isSettled: isSettled
                    ))
                    counterpartyIds.insert(otherId)
                }

                if !myPayments.isEmpty {
                    gameDebts.append(GameDebt(
                        gameId: g.id,
                        mode: g.mode,
                        createdAt: parseDate(g.created_at) ?? .distantPast,
                        payments: myPayments
                    ))
                }
            }

            // 5) Affiche les contreparties : profil pour les vrais users,
            //    placeholder_users pour les fantômes. On merge les deux maps.
            let profileByUserId = try await fetchProfilesAndPlaceholders(actorIds: Array(counterpartyIds))

            // 6) Build perPlayer.
            var perPlayerBuilder: [UUID: DebtAggregate] = [:]
            for gd in gameDebts {
                for p in gd.payments where !p.isSettled {
                    let signed = (p.direction == .owesMe ? p.amount : -p.amount)
                    if var existing = perPlayerBuilder[p.otherUserId] {
                        existing.amount += signed
                        existing.contributingGameIds.append(gd.gameId)
                        perPlayerBuilder[p.otherUserId] = existing
                    } else {
                        let prof = profileByUserId[p.otherUserId]
                        perPlayerBuilder[p.otherUserId] = DebtAggregate(
                            otherUserId: p.otherUserId,
                            displayName: prof?.display_name ?? "Joueur",
                            avatarUrl: prof?.avatar_url,
                            amount: signed,
                            contributingGameIds: [gd.gameId]
                        )
                    }
                }
            }
            let aggregates = perPlayerBuilder.values
                .filter { abs($0.amount) >= 0.005 }
                .sorted { lhs, rhs in
                    if lhs.direction != rhs.direction { return lhs.direction == .owesMe }
                    return lhs.absAmount > rhs.absAmount
                }

            // 7) Decore perGame avec displayName + avatar des contreparties
            //    en l'embarquant dans le payment via lookup côté UI (on garde
            //    GamePayment léger). On expose juste un helper map.
            self.profilesById = profileByUserId
            self.perGame = gameDebts.sorted { $0.createdAt > $1.createdAt }
            self.perPlayer = aggregates
            self.totalOwedToMe = aggregates.filter { $0.direction == .owesMe }.reduce(0) { $0 + $1.absAmount }
            self.totalIOwe    = aggregates.filter { $0.direction == .iOwe   }.reduce(0) { $0 + $1.absAmount }
            self.net = totalOwedToMe - totalIOwe
            self.settledGameIds = Set(gameDebts.filter { $0.isFullySettledByMe }.map { $0.gameId })

            #if DEBUG
            print("[DebtsService] load(\(tag)) — \(gameDebts.count) games impliquant moi, \(aggregates.count) joueurs ouverts")
            #endif
        } catch {
            loadError = error.localizedDescription
            #if DEBUG
            print("[DebtsService] load(\(tag)) FAILED: \(error)")
            #endif
        }
    }

    private func resetEmpty() {
        perPlayer = []
        perGame = []
        net = 0
        totalIOwe = 0
        totalOwedToMe = 0
        settledGameIds = []
    }

    // MARK: - Profiles cache (rendu UI per-game)

    /// userId → profile, peuplé à chaque `load()`. Utilisé par l'UI pour
    /// afficher noms/avatars dans la vue par-partie.
    @Published private(set) var profilesById: [UUID: ProfileRow] = [:]

    /// Lookup unifié pour les actor UUIDs : un acteur peut être soit un user
    /// (présent dans `profiles`), soit un placeholder (présent dans
    /// `placeholder_users`). On query les deux et on merge en une map. Les
    /// rows de placeholder_users sont reformatées en `ProfileRow` (même
    /// shape — display_name + avatar) pour rester compatibles avec l'UI.
    private func fetchProfilesAndPlaceholders(actorIds: [UUID]) async throws -> [UUID: ProfileRow] {
        guard !actorIds.isEmpty else { return [:] }
        let stringIds = actorIds.map { $0.uuidString }

        async let profiles: [ProfileRow] = client
            .from("profiles")
            .select("user_id,display_name,avatar_url")
            .in("user_id", values: stringIds)
            .execute()
            .value
        async let placeholders: [PlaceholderRow] = client
            .from("placeholder_users")
            .select("id,display_name")
            .in("id", values: stringIds)
            .execute()
            .value

        let (profileRows, placeholderRows) = try await (profiles, placeholders)

        var merged: [UUID: ProfileRow] = [:]
        for r in profileRows { merged[r.user_id] = r }
        for p in placeholderRows {
            // Si déjà présent côté profile (cas: placeholder claimé qui a un
            // profil maintenant), on garde le profile.
            if merged[p.id] == nil {
                merged[p.id] = ProfileRow(
                    user_id: p.id,
                    display_name: p.display_name,
                    avatar_url: nil
                )
            }
        }
        return merged
    }

    // MARK: - Actions

    /// Marque comme réglée la dette (game_id, other_user_id) bilatéralement.
    func markPaid(gameId: UUID, otherUserId: UUID) async throws {
        struct Params: Encodable {
            let p_game_id: UUID
            let p_other_user_id: UUID
        }
        try await client
            .rpc("mark_pair_settled", params: Params(p_game_id: gameId, p_other_user_id: otherUserId))
            .execute()
        if let uid = currentUserId { await load(myUserId: uid) }
    }

    /// Annule un règlement (les deux users le voient revenir actif).
    func markUnpaid(gameId: UUID, otherUserId: UUID) async throws {
        struct Params: Encodable {
            let p_game_id: UUID
            let p_other_user_id: UUID
        }
        try await client
            .rpc("unmark_pair_settled", params: Params(p_game_id: gameId, p_other_user_id: otherUserId))
            .execute()
        if let uid = currentUserId { await load(myUserId: uid) }
    }

    /// Marque toutes les parties contribuant à la dette agrégée (par joueur)
    /// comme réglées. Effet bilatéral (l'autre user voit toutes ces lignes
    /// passer en payées).
    func markAllPaidForPlayer(_ aggregate: DebtAggregate) async throws {
        struct Params: Encodable {
            let p_game_id: UUID
            let p_other_user_id: UUID
        }
        for gameId in aggregate.contributingGameIds {
            try await client
                .rpc("mark_pair_settled", params: Params(p_game_id: gameId, p_other_user_id: aggregate.otherUserId))
                .execute()
        }
        if let uid = currentUserId { await load(myUserId: uid) }
    }

    // MARK: - Live updates

    /// Realtime sur game_participants / manches / manche_results /
    /// game_pair_settlements. RLS filtre → on ne reçoit que des events qui
    /// peuvent nous toucher. Debounce 400ms avant reload complet.
    func startLiveUpdates(myUserId: UUID) async {
        if let active = currentUserId, active == myUserId, realtimeChannel != nil {
            return
        }
        await stopLiveUpdates()
        currentUserId = myUserId

        let ch = client.realtimeV2.channel("debts-\(myUserId.uuidString.prefix(8))")
        realtimeChannel = ch

        let tables = ["game_pair_settlements", "manche_results", "manches", "game_participants"]
        var streams: [AsyncStream<AnyAction>] = []
        for t in tables {
            streams.append(ch.postgresChange(AnyAction.self, schema: "public", table: t))
        }

        do {
            try await ch.subscribeWithError()
        } catch {
            #if DEBUG
            print("[DebtsService] subscribe failed: \(error)")
            #endif
            return
        }

        for stream in streams {
            let task = Task { [weak self] in
                for await _ in stream { await self?.scheduleReload() }
            }
            subscribeTasks.append(task)
        }

        // Premier chargement.
        await load(myUserId: myUserId)
    }

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

// MARK: - DTOs Postgrest (internes)

private struct BasicParticipantRow: Decodable {
    let game_id: UUID
    let seat_index: Int
}

private struct GameRow: Decodable {
    let id: UUID
    let mode: String
    let created_at: String?
    let line_price: Double?
    let currency: String?
    let game_participants: [GameParticipantRow]?
    let manches: [MancheRow]?
}

private struct GameParticipantRow: Decodable {
    let seat_index: Int
    let user_id: UUID?
    let placeholder_id: UUID?
    let guest_name: String?
}

private struct PlaceholderRow: Decodable {
    let id: UUID
    let display_name: String
}

private struct MancheRow: Decodable {
    let id: UUID
    let manche_results: [MancheResultRow]
}

private struct MancheResultRow: Decodable {
    let seat_index: Int
    let delta: Double
}

private struct SettlementRow: Decodable {
    let game_id: UUID
    let user_a: UUID
    let user_b: UUID
    let settled_at: String?
    let settled_by: UUID
}

struct ProfileRow: Decodable, Hashable {
    let user_id: UUID
    let display_name: String
    let avatar_url: String?
}
