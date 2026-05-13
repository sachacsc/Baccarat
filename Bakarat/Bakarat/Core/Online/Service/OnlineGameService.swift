//
//  OnlineGameService.swift
//  Bakarat
//
//  Service ObservableObject autour de Supabase Realtime V2. Une instance par
//  vue (créée dans OnlineRootView via @StateObject). Gère le cycle de vie du
//  channel : create/join → subscribe → broadcast → leave.
//
//  Phase 1 : lobby uniquement.
//    - Host : génère un code, ouvre `online:CODE`, se déclare participant,
//             répond aux helloFromGuest avec un snapshot.
//    - Guest : ouvre `online:CODE`, envoie helloFromGuest, attend un snapshot.
//
//  Phase 2+ : on ajoutera la propagation des actions (deal, announce, reveal,
//  tie-break) via le même channel — d'où l'enveloppe OnlineMessage extensible.
//

import Foundation
import Combine
import Supabase
import Realtime

@MainActor
final class OnlineGameService: ObservableObject {
    @Published private(set) var room: OnlineRoom?
    @Published private(set) var role: OnlineRole?
    @Published private(set) var phase: Phase = .idle
    @Published var lastError: String?
    /// Numéro de tentative actuel du helloFromGuest (0 = pas de retry en cours).
    /// Permet d'afficher "Tentative N/X" pendant que le guest attend le snapshot.
    @Published private(set) var helloAttempt: Int = 0
    /// Code du channel sur lequel on a tenté de se connecter (utile pour
    /// afficher "Recherche du salon XXXX" pendant l'attente du snapshot).
    @Published private(set) var pendingChannelCode: String?
    /// Nombre total de tentatives avant abandon (visible dans le loader UI).
    static let maxHelloAttempts: Int = 5

    enum Phase: Equatable {
        /// Pas encore dans une room (vue entry)
        case idle
        /// En cours d'ouverture du channel (loader)
        case connecting
        /// Connecté, en lobby (avant start)
        case lobby
        /// La partie est lancée (Phase 2+)
        case playing
        /// On a quitté ou été déco
        case left
    }

    private let client = SupabaseClientProvider.shared
    private var channel: RealtimeChannelV2?
    private var subscribeTask: Task<Void, Never>?
    private var listenerTask: Task<Void, Never>?
    private var helloRetryTask: Task<Void, Never>?

    // MARK: - Logging

    /// Log de debug — préfixé par le rôle pour reconnaître HOST vs GUEST dans la console.
    private func log(_ msg: String) {
        #if DEBUG
        let tag: String
        switch role {
        case .host:  tag = "HOST "
        case .guest: tag = "GUEST"
        case .none:  tag = "?    "
        }
        print("[Online \(tag)] \(msg)")
        #endif
    }

    // MARK: - Public API

    /// Crée une nouvelle room et devient host.
    func createRoom(myUserId: UUID, myDisplayName: String) async {
        let code = RoomCode.random()
        let me = OnlineParticipant(userId: myUserId, displayName: myDisplayName, isHost: true)
        self.role = .host
        self.room = OnlineRoom(code: code, hostUserId: myUserId, participants: [me], status: .lobby)
        log("createRoom code=\(code) user=\(myDisplayName) (\(myUserId.uuidString.prefix(8)))")
        await openChannel(code: code, myUserId: myUserId, myDisplayName: myDisplayName)
    }

    /// Rejoint une room existante en tant que guest.
    /// Retourne false si le code a un format invalide (=> ne navigue pas au salon).
    @discardableResult
    func joinRoom(code rawCode: String, myUserId: UUID, myDisplayName: String) async -> Bool {
        let code = rawCode.uppercased().filter { $0.isLetter || $0.isNumber }
        guard code.count == 4 else {
            lastError = "Code invalide (4 caractères attendus)."
            log("joinRoom REJECTED: bad format '\(rawCode)' → '\(code)' (\(code.count) chars)")
            return false
        }
        self.role = .guest
        self.room = nil
        self.lastError = nil
        log("joinRoom code=\(code) user=\(myDisplayName) (\(myUserId.uuidString.prefix(8)))")
        await openChannel(code: code, myUserId: myUserId, myDisplayName: myDisplayName)
        return true
    }

    /// Quitte la room (broadcast de leave + unsubscribe).
    func leave(myUserId: UUID) async {
        log("leave")
        if let channel {
            // Best-effort leave broadcast
            try? await sendMessage(.init(kind: .leave, payload: .leave(userId: myUserId)))
            await channel.unsubscribe()
        }
        listenerTask?.cancel()
        subscribeTask?.cancel()
        helloRetryTask?.cancel()
        channel = nil
        room = nil
        role = nil
        phase = .left
        pendingChannelCode = nil
        helloAttempt = 0
    }

    /// Host : met à jour les réglages de la room en lobby (prix, flash, timer) et broadcast.
    /// Sans effet pour les guests (la modif sera ignorée).
    func updateSettings(linePrice: Double? = nil,
                        flashMode: Bool? = nil,
                        announceTimerSeconds: Int? = nil) async {
        guard role == .host, var current = room else { return }
        if let v = linePrice            { current.linePrice = v }
        if let v = flashMode            { current.flashMode = v }
        if let v = announceTimerSeconds { current.announceTimerSeconds = v }
        room = current
        log("updateSettings price=\(current.linePrice) flash=\(current.flashMode) timer=\(current.announceTimerSeconds)")
        await broadcastSnapshot()
    }

    /// Host uniquement : démarre la 1ère manche (génère le deck, distribue les
    /// mains, prépare community + brûles). Broadcast immédiat.
    func startGame() async {
        guard role == .host, var current = room else { return }
        guard current.participants.count >= 2 else {
            lastError = "Au moins 2 joueurs requis."
            return
        }

        guard let initialGameState = OnlineGameService.buildInitialGameState(
            mancheNumber: 1,
            participants: current.participants,
            dealerSeat: 0,
            linePrice: current.linePrice
        ) else {
            lastError = "Distribution impossible (trop de joueurs ou bug)."
            return
        }

        current.status = .playing
        current.gameState = initialGameState
        room = current
        phase = .playing
        await broadcastSnapshot()

        // On laisse les joueurs encaisser leur main pendant quelques secondes
        // (tension dramatique). Puis on enchaîne sur la révélation progressive
        // de TOUTES les cartes communautaires.
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        await revealCommunityProgressively()
    }

    // MARK: - Community reveal (tempo dramatique)

    /// Délais pour le pacing de révélation (en nanosecondes).
    private static let revealInterval: UInt64    = 700_000_000   // 0.7s entre 2 cartes
    private static let burnPause: UInt64         = 1_200_000_000 // 1.2s avant chaque burn suivant
    private static let preAnnouncePause: UInt64  = 1_500_000_000 // 1.5s avant la 1ère annonce
    private static let boardRevealPause: UInt64  = 5_000_000_000 // 5s entre 2 reveals
    private static let nextBoardAnnouncePause: UInt64 = 1_500_000_000

    /// Host : dévoile progressivement les 15 cartes communautaires —
    /// brûle 1 + flop (3×3 board par board) → brûle 2 + turn (1×3) →
    /// brûle 3 + river (1×3). Annonce s'ouvre seulement après les 15 cartes.
    func revealCommunityProgressively() async {
        guard role == .host else { return }

        // ===== FLOP : board par board, carte par carte =====
        await updateGameState { gs in
            gs.phase = .flop
            gs.burnsRevealed = max(gs.burnsRevealed, 1)
        }
        for boardIdx in 0..<3 {
            for cardIdx in 0..<3 {
                try? await Task.sleep(nanoseconds: Self.revealInterval)
                await updateGameState { gs in
                    let card = gs.pendingFlop[boardIdx][cardIdx]
                    if gs.communityCards[boardIdx].count <= cardIdx {
                        gs.communityCards[boardIdx].append(card)
                    }
                }
            }
        }

        // ===== TURN : une carte sur chaque board =====
        try? await Task.sleep(nanoseconds: Self.burnPause)
        await updateGameState { gs in
            gs.phase = .turn
            gs.burnsRevealed = max(gs.burnsRevealed, 2)
        }
        for boardIdx in 0..<3 {
            try? await Task.sleep(nanoseconds: Self.revealInterval)
            await updateGameState { gs in
                let card = gs.pendingTurns[boardIdx]
                if gs.communityCards[boardIdx].count < 4 {
                    gs.communityCards[boardIdx].append(card)
                }
            }
        }

        // ===== RIVER : une carte sur chaque board =====
        try? await Task.sleep(nanoseconds: Self.burnPause)
        await updateGameState { gs in
            gs.phase = .river
            gs.burnsRevealed = max(gs.burnsRevealed, 3)
        }
        for boardIdx in 0..<3 {
            try? await Task.sleep(nanoseconds: Self.revealInterval)
            await updateGameState { gs in
                let card = gs.pendingRivers[boardIdx]
                if gs.communityCards[boardIdx].count < 5 {
                    gs.communityCards[boardIdx].append(card)
                }
            }
        }

        // ===== Pause pour laisser regarder le tableau complet, puis annonces board 1
        try? await Task.sleep(nanoseconds: Self.preAnnouncePause)
        await enterAnnouncing()
    }

    /// Helper : applique une mutation au gameState courant et broadcast.
    private func updateGameState(_ mutate: (inout OnlineGameState) -> Void) async {
        guard var current = room, var gs = current.gameState else { return }
        mutate(&gs)
        current.gameState = gs
        room = current
        await broadcastSnapshot()
    }

    /// Host : ouvre la phase d'annonces pour le board courant.
    func enterAnnouncing() async {
        guard role == .host, var current = room, var gs = current.gameState else { return }
        // On accepte d'arriver depuis :
        //  - .river (fin de la révélation initiale → annonces board 1)
        //  - .boardReveal (après reveal du board précédent → annonces board suivant)
        guard gs.phase == .river || gs.phase == .boardReveal else { return }
        gs.phase = .announcing
        gs.submissions = [:]
        gs.excludedThisBoard = []
        current.gameState = gs
        room = current
        await broadcastSnapshot()
    }

    /// Guest : envoie son annonce au host (intent).
    func submitAnnounce(submission: BoardSubmission, mySeat: Int) async {
        // Côté host on traite directement, côté guest on broadcast.
        if role == .host {
            await handleIncomingSubmission(seat: mySeat, submission: submission)
        } else {
            try? await sendMessage(
                .init(kind: .submitAnnounce,
                      payload: .submitAnnounce(seat: mySeat, submission: submission))
            )
        }
    }

    /// Host : reçoit une annonce, l'enregistre, et déclenche le reveal si
    /// toutes les soumissions attendues sont arrivées.
    private func handleIncomingSubmission(seat: Int, submission: BoardSubmission) async {
        guard role == .host, var current = room, var gs = current.gameState else { return }
        guard gs.phase == .announcing else { return }
        // Vérifie que le joueur n'a pas déjà soumis et qu'il est encore éligible
        guard gs.submissions[seat] == nil else { return }
        guard !gs.excludedThisBoard.contains(seat) else { return }
        // Vérifie que les cartes appartiennent à la main (anti-cheat basique)
        if submission.categoryId != "skip" {
            let myHand = gs.hands[seat] ?? []
            for c in submission.cards where !myHand.contains(c) { return }
        }
        gs.submissions[seat] = submission
        current.gameState = gs
        room = current
        await broadcastSnapshot()

        // Tout le monde a soumis (parmi les joueurs encore en lice) ?
        let eligibleSeats = eligibleSeats(in: gs)
        if Set(gs.submissions.keys).isSuperset(of: eligibleSeats) {
            await revealBoard()
        }
    }

    /// Host : reveal du board courant. Détermine winner / split / abandon,
    /// stocke dans boardResults[currentBoard], avance à la phase suivante
    /// après un délai.
    func revealBoard() async {
        guard role == .host, var current = room, var gs = current.gameState else { return }
        guard gs.phase == .announcing else { return }

        let boardIdx = gs.currentBoard
        let boardCards = gs.communityCards[boardIdx]
        // Construit le résultat par joueur
        var perPlayer: [PlayerBoardResult] = []
        for player in gs.players where player.inManche {
            let sub = gs.submissions[player.seat]
            let isExcluded = gs.excludedThisBoard.contains(player.seat)
            let isForfeit  = player.forfeitFromBoard.map { $0 <= boardIdx } ?? false
            let isSkip     = sub?.categoryId == "skip"
            let cards      = sub?.cards ?? []
            var isValid = false
            if let categoryId = sub?.categoryId,
               let cat = HandCategory.from(id: categoryId),
               !isSkip, !isExcluded, !isForfeit {
                isValid = HandEvaluator.validateAnnounce(cat, hole: cards, board: boardCards)
            }
            let isBluff = sub != nil && !isSkip && !isExcluded && !isForfeit && !isValid
            perPlayer.append(PlayerBoardResult(
                userId: player.userId, seat: player.seat,
                announcedCategoryId: sub?.categoryId,
                cards: cards, isValid: isValid, isBluff: isBluff,
                isSkip: isSkip, isExcluded: isExcluded, isForfeit: isForfeit
            ))
        }

        // Détermine le gagnant : meilleure catégorie valide, puis meilleur ranks
        let validResults = perPlayer.filter { $0.isValid }
        var winnerSeat: Int?
        var winningCategoryId: String?
        var finalMulti = 1
        var isSplit = false
        var splitterSeats: [Int] = []
        var abandoned = false

        if validResults.isEmpty {
            // Bluffeurs exclus définitivement du board ; si plus de candidats
            // → board abandonné (Phase 2.2 simplifiée : on ne fait pas de rebid).
            let bluffers = perPlayer.filter { $0.isBluff }.map { $0.seat }
            gs.excludedThisBoard.append(contentsOf: bluffers)
            abandoned = true
        } else {
            // Trie par force décroissante
            let sorted = validResults.sorted { a, b in
                guard let ca = a.announcedCategoryId.flatMap({ HandCategory.from(id: $0) }),
                      let cb = b.announcedCategoryId.flatMap({ HandCategory.from(id: $0) }) else { return false }
                if ca != cb { return ca.rawValue > cb.rawValue }
                // À catégorie égale : compare les mains réelles
                let bestA = HandEvaluator.evaluateBest(a.cards + boardCards)
                let bestB = HandEvaluator.evaluateBest(b.cards + boardCards)
                guard let bA = bestA, let bB = bestB else { return false }
                return HandEvaluator.compare(bA, bB) > 0
            }
            let top = sorted[0]
            let topCat = top.announcedCategoryId.flatMap { HandCategory.from(id: $0) }
            // Détection split : même catégorie + force égale
            let tied = sorted.filter { r in
                guard r.announcedCategoryId == top.announcedCategoryId else { return false }
                let bA = HandEvaluator.evaluateBest(r.cards + boardCards)
                let bB = HandEvaluator.evaluateBest(top.cards + boardCards)
                guard let _bA = bA, let _bB = bB else { return false }
                return HandEvaluator.compare(_bA, _bB) == 0
            }
            if tied.count >= 2 {
                isSplit = true
                splitterSeats = tied.map { $0.seat }
                // Phase 2.2 simplifiée : on prend arbitrairement le 1er splitter comme winner
                // (tie-break propre arrive Phase 2.3).
                winnerSeat = splitterSeats.first
                winningCategoryId = top.announcedCategoryId
                finalMulti = topCat?.multi ?? 1
            } else {
                winnerSeat = top.seat
                winningCategoryId = top.announcedCategoryId
                finalMulti = topCat?.multi ?? 1
            }
        }

        gs.boardResults[boardIdx] = BoardResult(
            board: boardIdx, winnerSeat: winnerSeat,
            winningCategoryId: winningCategoryId, finalMulti: finalMulti,
            isSplit: isSplit, splitterSeats: splitterSeats,
            perPlayer: perPlayer, abandoned: abandoned
        )
        gs.phase = .boardReveal
        current.gameState = gs
        room = current
        await broadcastSnapshot()

        // Délai pour laisser le reveal à l'écran, puis on enchaîne
        try? await Task.sleep(nanoseconds: 5_000_000_000)
        await advanceAfterReveal()
    }

    /// Host : après un reveal de board, on passe au board suivant (annonces) ou
    /// on termine la manche. Les cartes communautaires sont déjà toutes
    /// dévoilées avant l'annonce du board 1 — on ne révèle rien ici.
    func advanceAfterReveal() async {
        guard role == .host, var current = room, var gs = current.gameState else { return }
        guard gs.phase == .boardReveal else { return }
        if gs.currentBoard < 2 {
            gs.currentBoard += 1
            current.gameState = gs
            room = current
            await broadcastSnapshot()

            try? await Task.sleep(nanoseconds: Self.nextBoardAnnouncePause)
            await enterAnnouncing()
        } else {
            // Fin de la manche (Phase 2.3 ajoutera le scoring + full board + persistance)
            gs.phase = .mancheEnd
            current.gameState = gs
            room = current
            await broadcastSnapshot()
        }
    }

    // MARK: - Utilities

    /// Liste des seats encore éligibles à soumettre une annonce sur le board courant.
    private func eligibleSeats(in gs: OnlineGameState) -> Set<Int> {
        var result: Set<Int> = []
        for p in gs.players where p.inManche {
            if gs.excludedThisBoard.contains(p.seat) { continue }
            if let ff = p.forfeitFromBoard, ff <= gs.currentBoard { continue }
            result.insert(p.seat)
        }
        return result
    }

    // MARK: - Game state construction (host)

    /// Construit l'état initial d'une manche : seats fixes, deck mélangé,
    /// mains distribuées, community pré-piochée (flop visible, turn/river
    /// pending), brûles cachées.
    static func buildInitialGameState(
        mancheNumber: Int,
        participants: [OnlineParticipant],
        dealerSeat: Int,
        linePrice: Double
    ) -> OnlineGameState? {
        // Players = participants triés par ordre de connexion, seat = index.
        let players = participants.enumerated().map { idx, p in
            GamePlayer(
                userId: p.userId, displayName: p.displayName,
                seat: idx, score: 0,
                inManche: true, connected: true, forfeitFromBoard: nil
            )
        }
        let target = OnlineDealer.cardsPerPlayer(activeCount: players.count)
        guard target > 0 else { return nil }

        // Ordre de distribution : 1er après le donneur → donneur servi en dernier
        let n = players.count
        let dealOrder: [Int] = (1...n).map { (dealerSeat + $0) % n }

        var deck = Deck.shuffled()
        guard let hands = OnlineDealer.dealHands(
            deck: &deck, orderedSeats: dealOrder, target: target
        ) else { return nil }

        guard let community = OnlineDealer.dealCommunity(deck: &deck) else { return nil }

        return OnlineGameState(
            mancheNumber: mancheNumber,
            linePrice: linePrice,
            players: players,
            dealerSeat: dealerSeat,
            phase: .dealing,
            currentBoard: 0,
            rebidRound: 0,
            hands: hands,
            burns: [community.burn1, community.burn2, community.burn3],
            burnsRevealed: 0,
            communityCards: [[], [], []],
            pendingFlop: community.flop,
            pendingTurns: community.turns,
            pendingRivers: community.rivers,
            submissions: [:],
            boardResults: [nil, nil, nil],
            fullBoardWinnerSeat: nil,
            excludedThisBoard: []
        )
        // Note : on conserve community.flop séparément pour le passage à `.flop`
        //        (geré dans la fonction `revealFlop()` à venir Phase 2.2).
    }

    // MARK: - Channel lifecycle

    private func openChannel(code: String, myUserId: UUID, myDisplayName: String) async {
        phase = .connecting
        pendingChannelCode = code
        let name = "online:\(code)"
        log("openChannel name=\(name)")

        // Si on a déjà un channel ouvert (re-join), on nettoie d'abord
        if let existing = channel {
            log("openChannel: closing previous channel")
            await existing.unsubscribe()
        }

        let ch = client.realtimeV2.channel(name)
        self.channel = ch
        log("openChannel: initial status = \(ch.status)")

        // Bind les broadcasts AVANT subscribe (sinon on peut rater le 1er message)
        listenerTask?.cancel()
        listenerTask = Task { [weak self] in
            guard let self else { return }
            self.log("listenerTask: started, waiting for messages")
            for await msg in ch.broadcastStream(event: "msg") {
                await self.handleIncoming(rawMessage: msg, myUserId: myUserId, myDisplayName: myDisplayName)
            }
            self.log("listenerTask: broadcastStream ended")
        }

        // Observe les changements de statut du channel (joined / joining / closed / errored)
        subscribeTask?.cancel()
        subscribeTask = Task { [weak self] in
            guard let self else { return }
            for await status in ch.statusChange {
                self.log("channel status → \(status)")
            }
            self.log("channel statusChange stream ended")
        }

        do {
            log("openChannel: calling subscribeWithError…")
            try await ch.subscribeWithError()
            log("openChannel: subscribe OK")
            phase = .lobby

            // Si host : on est seul pour l'instant, rien d'autre à faire.
            // Si guest : on annonce notre arrivée, le host répondra avec un snapshot.
            // On envoie en boucle (retry) jusqu'à recevoir le snapshot ou abandonner —
            // ça évite la race "guest envoie hello avant que le host soit pleinement
            // joint au channel" qui laissait le lobby bloqué sur 'Préparation…'.
            if role == .guest {
                startGuestHelloRetry(myUserId: myUserId, myDisplayName: myDisplayName)
            }
        } catch {
            log("openChannel: subscribe FAILED \(error.localizedDescription)")
            lastError = "Connexion au channel impossible : \(error.localizedDescription)"
            phase = .idle
        }
    }

    /// Guest : (re)envoie helloFromGuest jusqu'à recevoir un snapshot, max ~8s.
    private func startGuestHelloRetry(myUserId: UUID, myDisplayName: String) {
        helloRetryTask?.cancel()
        helloAttempt = 0
        let maxAttempts = Self.maxHelloAttempts
        helloRetryTask = Task { [weak self] in
            guard let self else { return }
            for attempt in 1...maxAttempts {
                if Task.isCancelled { return }
                if self.room != nil {
                    self.log("guest got snapshot (after \(attempt - 1) retries)")
                    self.helloAttempt = 0
                    return
                }
                self.helloAttempt = attempt
                self.log("guest sending helloFromGuest #\(attempt)/\(maxAttempts)")
                do {
                    try await self.sendMessage(
                        .init(kind: .helloFromGuest,
                              payload: .hello(userId: myUserId, displayName: myDisplayName))
                    )
                } catch {
                    self.log("guest hello send failed: \(error.localizedDescription)")
                }
                try? await Task.sleep(nanoseconds: 1_000_000_000) // 1s
            }
            if self.room == nil {
                let code = self.pendingChannelCode ?? "????"
                self.log("guest gave up after \(maxAttempts) retries, no snapshot for '\(code)'")
                self.lastError = "Aucun salon trouvé avec le code \(code). Demande à l'hôte de vérifier."
                self.helloAttempt = 0
            }
        }
    }

    private func sendMessage(_ msg: OnlineMessage) async throws {
        guard let channel else {
            log("sendMessage skipped: no channel (kind=\(msg.kind.rawValue))")
            return
        }
        // On encode l'OnlineMessage en JSON string puis on l'enveloppe dans une clé "p".
        // Plus simple et plus fiable que de mapper récursivement vers AnyJSON.
        let data = try JSONEncoder().encode(msg)
        let str = String(data: data, encoding: .utf8) ?? ""
        log("→ broadcast kind=\(msg.kind.rawValue) bytes=\(data.count)")
        try await channel.broadcast(event: "msg", message: ["p": .string(str)])
    }

    private func handleIncoming(rawMessage: [String: AnyJSON],
                                myUserId: UUID,
                                myDisplayName: String) async {
        // Realtime V2 enveloppe les broadcasts au format :
        //   { "type": "broadcast", "event": "msg", "payload": { "p": "<json>" } }
        // On extrait notre payload utilisateur (clé "p" nichée dans "payload").
        // Fallback : si le SDK nous le donne déjà unwrappé, on accepte aussi.
        let userPayload: [String: AnyJSON]
        if case .object(let o) = rawMessage["payload"] {
            userPayload = o
        } else if rawMessage["p"] != nil {
            userPayload = rawMessage
        } else {
            let keys = rawMessage.keys.sorted().joined(separator: ",")
            log("← incoming: unexpected shape, top keys=[\(keys)]")
            return
        }

        guard case .string(let payloadStr) = userPayload["p"] else {
            let keys = userPayload.keys.sorted().joined(separator: ",")
            log("← incoming: missing 'p' in user payload, keys=[\(keys)]")
            return
        }
        guard let data = payloadStr.data(using: .utf8) else {
            log("← incoming: cannot encode payload as utf8, ignoring")
            return
        }
        let msg: OnlineMessage
        do {
            msg = try JSONDecoder().decode(OnlineMessage.self, from: data)
        } catch {
            log("← incoming: decode FAILED \(error) — payload=\(payloadStr.prefix(160))")
            return
        }
        log("← kind=\(msg.kind.rawValue)")
        switch msg.payload {
        case .hello(let userId, let displayName):
            // Côté host : on ajoute le guest à la liste, on broadcast le snapshot
            guard role == .host, var current = room else {
                log("hello ignored: role=\(String(describing: role)) room=\(room == nil ? "nil" : "set")")
                return
            }
            if current.participants.contains(where: { $0.userId == userId }) {
                log("hello duplicate from \(displayName) — re-broadcasting snapshot")
                // Le guest est déjà dans la liste mais re-demande un snapshot (retry).
                // On rebroadcast pour qu'il sorte de "Préparation du salon…".
                await broadcastSnapshot()
            } else {
                log("hello new guest \(displayName) (\(userId.uuidString.prefix(8))), adding to room")
                current.participants.append(
                    OnlineParticipant(userId: userId, displayName: displayName, isHost: false)
                )
                room = current
                await broadcastSnapshot()
            }

        case .snapshot(let snapshot):
            // Côté guest (ou rejoin) : on prend le snapshot du host
            if role == .guest {
                log("snapshot received (\(snapshot.participants.count) participants)")
                self.room = snapshot
                helloRetryTask?.cancel()
            } else if role == .host {
                // Sécurité : ignore les snapshots d'un autre host (ne devrait pas arriver)
                if snapshot.hostUserId != myUserId {
                    log("snapshot ignored: foreign host \(snapshot.hostUserId.uuidString.prefix(8))")
                    return
                }
            }

        case .leave(let userId):
            guard role == .host, var current = room else { return }
            if userId == myUserId { return } // jamais soi-même
            log("guest \(userId.uuidString.prefix(8)) left")
            current.participants.removeAll { $0.userId == userId }
            room = current
            await broadcastSnapshot()

        case .start:
            log("start received")
            phase = .playing
            if var current = room {
                current.status = .playing
                room = current
            }

        case .submitAnnounce(let seat, let submission):
            // Seul le host traite les soumissions
            if role == .host {
                log("submitAnnounce seat=\(seat) category=\(submission.categoryId)")
                await handleIncomingSubmission(seat: seat, submission: submission)
            }
        }
    }

    private func broadcastSnapshot() async {
        guard let snapshot = room else { return }
        log("broadcasting snapshot (status=\(snapshot.status.rawValue), \(snapshot.participants.count) participants)")
        try? await sendMessage(.init(kind: .roomSnapshot, payload: .snapshot(snapshot)))
    }
}
