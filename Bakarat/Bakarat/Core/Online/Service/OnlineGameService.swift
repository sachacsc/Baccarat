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

    // MARK: - Public API

    /// Crée une nouvelle room et devient host.
    func createRoom(myUserId: UUID, myDisplayName: String) async {
        let code = RoomCode.random()
        let me = OnlineParticipant(userId: myUserId, displayName: myDisplayName, isHost: true)
        self.role = .host
        self.room = OnlineRoom(code: code, hostUserId: myUserId, participants: [me], status: .lobby)
        await openChannel(code: code, myUserId: myUserId, myDisplayName: myDisplayName)
    }

    /// Rejoint une room existante en tant que guest.
    func joinRoom(code rawCode: String, myUserId: UUID, myDisplayName: String) async {
        let code = rawCode.uppercased().filter { $0.isLetter || $0.isNumber }
        guard code.count == 4 else {
            lastError = "Code invalide (4 caractères attendus)."
            return
        }
        self.role = .guest
        self.room = nil
        await openChannel(code: code, myUserId: myUserId, myDisplayName: myDisplayName)
    }

    /// Quitte la room (broadcast de leave + unsubscribe).
    func leave(myUserId: UUID) async {
        if let channel {
            // Best-effort leave broadcast
            try? await sendMessage(.init(kind: .leave, payload: .leave(userId: myUserId)))
            await channel.unsubscribe()
        }
        listenerTask?.cancel()
        subscribeTask?.cancel()
        channel = nil
        room = nil
        role = nil
        phase = .left
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
        let name = "online:\(code)"

        // Si on a déjà un channel ouvert (re-join), on nettoie d'abord
        if let existing = channel {
            await existing.unsubscribe()
        }

        let ch = client.realtimeV2.channel(name)
        self.channel = ch

        // Bind les broadcasts AVANT subscribe (sinon on peut rater le 1er message)
        listenerTask = Task { [weak self] in
            guard let self else { return }
            for await msg in ch.broadcastStream(event: "msg") {
                await self.handleIncoming(rawMessage: msg, myUserId: myUserId, myDisplayName: myDisplayName)
            }
        }

        do {
            try await ch.subscribeWithError()
            // Si host : on est seul pour l'instant, rien d'autre à faire.
            // Si guest : on annonce notre arrivée, le host répondra avec un snapshot.
            if role == .guest {
                try await sendMessage(
                    .init(kind: .helloFromGuest,
                          payload: .hello(userId: myUserId, displayName: myDisplayName))
                )
            }
            phase = .lobby
        } catch {
            lastError = "Connexion au channel impossible : \(error.localizedDescription)"
            phase = .idle
        }
    }

    private func sendMessage(_ msg: OnlineMessage) async throws {
        guard let channel else { return }
        // On encode l'OnlineMessage en JSON string puis on l'enveloppe dans une clé "p".
        // Plus simple et plus fiable que de mapper récursivement vers AnyJSON.
        let data = try JSONEncoder().encode(msg)
        let str = String(data: data, encoding: .utf8) ?? ""
        try await channel.broadcast(event: "msg", message: ["p": .string(str)])
    }

    private func handleIncoming(rawMessage: [String: AnyJSON],
                                myUserId: UUID,
                                myDisplayName: String) async {
        // Désenveloppe : on attend ["p": .string(<json>)]
        guard case .string(let payloadStr) = rawMessage["p"],
              let data = payloadStr.data(using: .utf8),
              let msg = try? JSONDecoder().decode(OnlineMessage.self, from: data) else {
            return
        }
        switch msg.payload {
        case .hello(let userId, let displayName):
            // Côté host : on ajoute le guest à la liste, on broadcast le snapshot
            guard role == .host, var current = room else { return }
            if !current.participants.contains(where: { $0.userId == userId }) {
                current.participants.append(
                    OnlineParticipant(userId: userId, displayName: displayName, isHost: false)
                )
                room = current
                await broadcastSnapshot()
            }

        case .snapshot(let snapshot):
            // Côté guest (ou rejoin) : on prend le snapshot du host
            if role == .guest {
                self.room = snapshot
            } else if role == .host {
                // Sécurité : ignore les snapshots d'un autre host (ne devrait pas arriver)
                if snapshot.hostUserId != myUserId { return }
            }

        case .leave(let userId):
            guard role == .host, var current = room else { return }
            if userId == myUserId { return } // jamais soi-même
            current.participants.removeAll { $0.userId == userId }
            room = current
            await broadcastSnapshot()

        case .start:
            phase = .playing
            if var current = room {
                current.status = .playing
                room = current
            }

        case .submitAnnounce(let seat, let submission):
            // Seul le host traite les soumissions
            if role == .host {
                await handleIncomingSubmission(seat: seat, submission: submission)
            }
        }
    }

    private func broadcastSnapshot() async {
        guard let snapshot = room else { return }
        try? await sendMessage(.init(kind: .roomSnapshot, payload: .snapshot(snapshot)))
    }
}
