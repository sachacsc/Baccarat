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
    private var announceTimerTask: Task<Void, Never>?
    private var presenceTask: Task<Void, Never>?
    private var myUserIdCache: UUID?

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
        if role == .host {
            clearHostState()
        }
        if let channel {
            // Best-effort leave broadcast
            try? await sendMessage(.init(kind: .leave, payload: .leave(userId: myUserId)))
            await channel.unsubscribe()
        }
        listenerTask?.cancel()
        subscribeTask?.cancel()
        helloRetryTask?.cancel()
        announceTimerTask?.cancel()
        presenceTask?.cancel()
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
        log("startGame: called")
        guard role == .host, var current = room else {
            log("startGame: ABORT role=\(String(describing: role)) hasRoom=\(room != nil)")
            return
        }
        log("startGame: \(current.participants.count) participants, linePrice=\(current.linePrice)")
        guard current.participants.count >= 2 else {
            log("startGame: ABORT need ≥ 2 players")
            lastError = "Au moins 2 joueurs requis."
            return
        }

        guard let initialGameState = OnlineGameService.buildInitialGameState(
            mancheNumber: 1,
            participants: current.participants,
            dealerSeat: 0,
            linePrice: current.linePrice
        ) else {
            log("startGame: ABORT buildInitialGameState returned nil")
            lastError = "Distribution impossible (trop de joueurs ou bug)."
            return
        }

        log("startGame: built initial state — \(initialGameState.players.count) seats, \(initialGameState.hands.count) hands")
        current.status = .playing
        current.gameState = initialGameState
        room = current
        phase = .playing
        log("startGame: room.status set to .playing, broadcasting…")
        await broadcastSnapshot()
        log("startGame: snapshot broadcast complete, waiting 3s before reveal")

        // On laisse les joueurs encaisser leur main pendant quelques secondes
        // (tension dramatique). Puis on enchaîne sur la révélation progressive
        // de TOUTES les cartes communautaires.
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        log("startGame: starting community reveal")
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
        gs.rebidRound = 0  // reset pour nouveau board
        gs.announceDeadline = computeDeadline(seconds: current.announceTimerSeconds)
        current.gameState = gs
        room = current
        await broadcastSnapshot()
        scheduleAnnounceTimerIfNeeded(gs.announceDeadline)
    }

    /// Calcule un timestamp (epoch sec) à atteindre, ou nil si timer désactivé.
    private func computeDeadline(seconds: Int) -> TimeInterval? {
        guard seconds > 0 else { return nil }
        return Date().timeIntervalSince1970 + Double(seconds)
    }

    /// Programme un Task qui force le reveal quand la deadline est atteinte.
    /// Au fire, on auto-skippe les joueurs qui n'ont pas soumis.
    private func scheduleAnnounceTimerIfNeeded(_ deadline: TimeInterval?) {
        announceTimerTask?.cancel()
        guard let deadline else { return }
        let delaySec = max(0, deadline - Date().timeIntervalSince1970)
        announceTimerTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delaySec * 1_000_000_000))
            if Task.isCancelled { return }
            await self?.timerExpired()
        }
    }

    /// Host : au timeout, on auto-submit "skip" pour chaque seat éligible qui
    /// n'a pas encore annoncé, puis on déclenche le reveal du board (ou tie-break).
    private func timerExpired() async {
        guard role == .host, var current = room, var gs = current.gameState else { return }
        log("timerExpired: phase=\(gs.phase.rawValue)")
        if gs.phase == .announcing {
            let eligible = eligibleSeats(in: gs)
            for seat in eligible where gs.submissions[seat] == nil {
                gs.submissions[seat] = BoardSubmission(categoryId: "skip", cards: [])
                log("timerExpired: auto-skip seat=\(seat)")
            }
            current.gameState = gs
            room = current
            await broadcastSnapshot()
            await revealBoard()
        } else if gs.phase == .tiebreakAnnouncing {
            guard var tb = gs.tiebreakBoards.last else { return }
            for seat in tb.eligibleSeats where tb.submissions[seat] == nil {
                tb.submissions[seat] = BoardSubmission(categoryId: "skip", cards: [])
                log("timerExpired: tiebreak auto-skip seat=\(seat)")
            }
            gs.tiebreakBoards[gs.tiebreakBoards.count - 1] = tb
            current.gameState = gs
            room = current
            await broadcastSnapshot()
            await revealTiebreakBoard()
        }
    }

    /// Guest/host : demande à passer en spectateur (ou rejoindre) pour la
    /// MANCHE SUIVANTE. Pour l'utilisateur courant uniquement.
    /// Si l'hôte passe en spectateur → transfert d'hôte immédiat AVANT.
    func setSelfSpectator(_ wantsToSpectate: Bool) async {
        guard let uid = myUserIdCache, let gs = service_currentGameState() else { return }
        guard let seat = gs.players.first(where: { $0.userId == uid })?.seat else { return }

        // Si je suis hôte et je passe en spec → transfert AVANT pour ne pas
        // me retrouver "hôte spectateur" (état incohérent).
        if role == .host && wantsToSpectate {
            await transferHostBeforeSpectating()
        }

        if role == .host {
            await applySpectatorChange(seat: seat, wantsToSpectate: wantsToSpectate)
        } else {
            try? await sendMessage(
                .init(kind: .setSpectator,
                      payload: .setSpectator(seat: seat, wantsToSpectate: wantsToSpectate))
            )
        }
    }

    private func service_currentGameState() -> OnlineGameState? {
        room?.gameState
    }

    /// Host uniquement : exclut un joueur de la partie (force-disconnect).
    /// Utile quand la présence Realtime n'a pas détecté la déconnexion (joueur
    /// figé / en airplane mode mais channel encore actif). Effet :
    ///  - connected = false
    ///  - forfeit du board courant (paye comme un loser sur les boards restants)
    ///  - wantsToSpectate = true (retiré des manches suivantes ; peut revenir
    ///    via le popover spectateurs s'il se reconnecte)
    /// Le solde du joueur est conservé.
    func kickPlayer(seat: Int) async {
        guard role == .host, let myId = myUserIdCache else { return }
        guard var current = room, var gs = current.gameState else { return }
        guard let i = gs.players.firstIndex(where: { $0.seat == seat }) else { return }
        // Pas de kick sur soi-même (l'hôte utilise "Quitter la partie").
        guard gs.players[i].userId != myId else { return }

        let name = gs.players[i].displayName
        gs.players[i].connected = false
        if gs.players[i].inManche,
           gs.players[i].forfeitFromBoard == nil,
           gs.phase != .mancheEnd {
            gs.players[i].forfeitFromBoard = gs.currentBoard
        }
        gs.players[i].wantsToSpectate = true
        current.gameState = gs
        room = current
        log("kickPlayer: seat=\(seat) (\(name))")
        await broadcastSnapshot()
        await checkAutoRevealAfterDisconnect()
    }

    /// Host : applique la préférence spectateur d'un seat (broadcast snapshot).
    private func applySpectatorChange(seat: Int, wantsToSpectate: Bool) async {
        guard role == .host, var current = room, var gs = current.gameState else { return }
        guard let i = gs.players.firstIndex(where: { $0.seat == seat }) else { return }
        guard gs.players[i].wantsToSpectate != wantsToSpectate else { return }
        gs.players[i].wantsToSpectate = wantsToSpectate
        log("applySpectatorChange: seat=\(seat) wants=\(wantsToSpectate)")
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

    /// Host : route la soumission vers le handler du board courant ou du tie-break
    /// actif, selon la phase.
    private func handleIncomingSubmission(seat: Int, submission: BoardSubmission) async {
        guard role == .host, let current = room, let gs = current.gameState else { return }
        switch gs.phase {
        case .announcing:
            await handleRegularSubmission(seat: seat, submission: submission)
        case .tiebreakAnnouncing:
            await handleTiebreakSubmission(seat: seat, submission: submission)
        default:
            log("submission ignored: phase=\(gs.phase.rawValue)")
            return
        }
    }

    private func handleRegularSubmission(seat: Int, submission: BoardSubmission) async {
        guard role == .host, var current = room, var gs = current.gameState else { return }
        guard gs.phase == .announcing else { return }
        guard gs.submissions[seat] == nil else { return }
        guard !gs.excludedThisBoard.contains(seat) else { return }
        if submission.categoryId != "skip" {
            let myHand = gs.hands[seat] ?? []
            for c in submission.cards where !myHand.contains(c) { return }
        }
        gs.submissions[seat] = submission
        current.gameState = gs
        room = current
        await broadcastSnapshot()

        let eligible = eligibleSeats(in: gs)
        if Set(gs.submissions.keys).isSuperset(of: eligible) {
            await revealBoard()
        }
    }

    private func handleTiebreakSubmission(seat: Int, submission: BoardSubmission) async {
        guard role == .host, var current = room, var gs = current.gameState else { return }
        guard gs.phase == .tiebreakAnnouncing else { return }
        guard var tb = gs.tiebreakBoards.last else { return }
        guard tb.eligibleSeats.contains(seat) else { return }
        guard tb.submissions[seat] == nil else { return }
        if submission.categoryId != "skip" {
            let myHand = gs.hands[seat] ?? []
            for c in submission.cards where !myHand.contains(c) { return }
        }
        tb.submissions[seat] = submission
        gs.tiebreakBoards[gs.tiebreakBoards.count - 1] = tb
        current.gameState = gs
        room = current
        await broadcastSnapshot()

        let submitted = Set(tb.submissions.keys)
        let eligibleSet = Set(tb.eligibleSeats)
        if submitted.isSuperset(of: eligibleSet) {
            await revealTiebreakBoard()
        }
    }

    /// Host : reveal du board courant. Détermine winner / split / abandon,
    /// stocke dans boardResults[currentBoard], avance à la phase suivante
    /// après un délai.
    func revealBoard() async {
        guard role == .host, var current = room, var gs = current.gameState else { return }
        guard gs.phase == .announcing else { return }
        // Annule le timer dès l'entrée : empêche une seconde fire pendant le
        // sleep/broadcast qui suit (race entre handleRegularSubmission "tous
        // soumis → reveal" et timerExpired qui auto-skip).
        announceTimerTask?.cancel()
        announceTimerTask = nil

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
            // Tous les annonceurs ont bluffé → on les exclut.
            let bluffers = perPlayer.filter { $0.isBluff }.map { $0.seat }
            gs.excludedThisBoard.append(contentsOf: bluffers)

            // Check si rebid possible : au moins 1 joueur non exclu et < 3 rounds.
            let nonExcludedSeats = gs.players
                .filter { $0.inManche && !gs.excludedThisBoard.contains($0.seat) }
                .map { $0.seat }
            if !nonExcludedSeats.isEmpty && gs.rebidRound < 2 {
                gs.rebidRound += 1
                gs.submissions = [:]
                gs.announceDeadline = computeDeadline(seconds: current.announceTimerSeconds)
                current.gameState = gs
                room = current
                log("revealBoard: ALL BLUFF, rebid #\(gs.rebidRound) — eligibles=\(nonExcludedSeats)")
                // On reste en .announcing : excludedThisBoard préserve les bluffeurs
                // pour le prochain tour. Les non-exclus peuvent re-annoncer.
                await broadcastSnapshot()
                scheduleAnnounceTimerIfNeeded(gs.announceDeadline)
                return
            }
            abandoned = true
        } else {
            // Trie par force décroissante. L'annonce du joueur PRIME : on
            // compare au sein de la catégorie annoncée (un joueur qui annonce
            // Couleur ne profite PAS d'avoir une Quinte Flush ; idem un joueur
            // qui annonce Hauteur n'est PAS upgradé en Paire si le board match).
            let sorted = validResults.sorted { a, b in
                guard let ca = a.announcedCategoryId.flatMap({ HandCategory.from(id: $0) }),
                      let cb = b.announcedCategoryId.flatMap({ HandCategory.from(id: $0) }) else { return false }
                if ca != cb { return ca.rawValue > cb.rawValue }
                return compareWithinCategory(ca, a: a.cards, b: b.cards, board: boardCards) > 0
            }
            let top = sorted[0]
            let topCat = top.announcedCategoryId.flatMap { HandCategory.from(id: $0) }
            // Détection split : même catégorie + force égale dans CETTE catégorie
            let tied = sorted.filter { r in
                guard r.announcedCategoryId == top.announcedCategoryId,
                      let cat = topCat else { return false }
                return compareWithinCategory(cat, a: r.cards, b: top.cards, board: boardCards) == 0
            }
            if tied.count >= 2 {
                isSplit = true
                splitterSeats = tied.map { $0.seat }
                // Pas de winner immédiat : on déclenche un tie-break sur un
                // nouveau board virtuel. La méthode `enterTiebreak` ci-dessous
                // pop 5 cartes du tiebreakPool et entre en .tiebreakAnnouncing.
                winnerSeat = nil
                winningCategoryId = top.announcedCategoryId
                finalMulti = topCat?.multi ?? 1
            } else {
                winnerSeat = top.seat
                winningCategoryId = top.announcedCategoryId
                finalMulti = topCat?.multi ?? 1
            }
        }

        let result = BoardResult(
            board: boardIdx, winnerSeat: winnerSeat,
            winningCategoryId: winningCategoryId, finalMulti: finalMulti,
            isSplit: isSplit, splitterSeats: splitterSeats,
            perPlayer: perPlayer, abandoned: abandoned
        )
        gs.boardResults[boardIdx] = result

        if isSplit {
            // Pas de scoring pour l'instant — on attend le tie-break.
            current.gameState = gs
            room = current
            await broadcastSnapshot()
            // Petit délai pour montrer le résultat du board avec le badge ⚡ Split
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            await enterTiebreak(parentBoardIdx: boardIdx,
                                eligibleSeats: splitterSeats,
                                round: 0)
            return
        }

        // Winner clair (ou board abandonné) : scoring + reveal classique
        applyBoardScoring(gs: &gs, result: result)
        gs.phase = .boardReveal
        current.gameState = gs
        room = current
        await broadcastSnapshot()

        try? await Task.sleep(nanoseconds: 5_000_000_000)
        await advanceAfterReveal()
    }

    /// Compare deux annonces AU SEIN de la catégorie annoncée. Pour Hauteur,
    /// on regarde uniquement la carte la plus haute parmi celles sélectionnées :
    /// le "kicker" ne compte pas (sinon K-2 perdrait contre K-5 même si les
    /// deux n'ont que K en réalité — voir le cas du board avec plein de
    /// cartes > 5). Pour les autres catégories, on prend le meilleur 5-card
    /// hand parmi (cartes annoncées + board).
    private func compareWithinCategory(_ cat: HandCategory,
                                       a: [Card],
                                       b: [Card],
                                       board: [Card]) -> Int {
        if cat == .highcard {
            let aTop = a.map { $0.rank.value }.max() ?? 0
            let bTop = b.map { $0.rank.value }.max() ?? 0
            return aTop - bTop
        }
        let bestA = HandEvaluator.evaluateBest(a + board)
        let bestB = HandEvaluator.evaluateBest(b + board)
        guard let bA = bestA, let bB = bestB else { return 0 }
        return HandEvaluator.compare(bA, bB)
    }

    // MARK: - Tie-break

    /// Host : entre dans un round de tie-break sur un board virtuel (5 nouvelles
    /// cartes). Les splitters re-sélectionnent leurs cartes pour la même
    /// catégorie qu'ils ont annoncée à l'origine.
    ///
    /// Pool de cartes utilisé : **tout le deck (52 cartes) sauf les hole cards
    /// des splitters** (qui sont les seules vraiment cachées au reste du monde).
    /// Donc les cartes des non-splitters, les 3 boards et les brûles sont
    /// rebattues dans la pile disponible — comme à la table réelle. On exclut
    /// aussi les cartes des tours de tie-break précédents pour éviter
    /// d'enchaîner deux fois la même.
    private func enterTiebreak(parentBoardIdx: Int,
                               eligibleSeats: [Int],
                               round: Int) async {
        guard role == .host, var current = room, var gs = current.gameState else { return }

        let splitterHoles = Set(eligibleSeats.flatMap { gs.hands[$0] ?? [] })
        let alreadyUsedInTiebreaks = Set(gs.tiebreakBoards.flatMap { $0.cards })
        var pool = Deck.full.filter {
            !splitterHoles.contains($0) && !alreadyUsedInTiebreaks.contains($0)
        }
        pool.shuffle()

        guard pool.count >= 5 else {
            log("enterTiebreak: pool epuisé apres exclusions (\(pool.count) cartes), winner arbitraire")
            if let first = eligibleSeats.first {
                await finalizeParentBoard(parentBoardIdx: parentBoardIdx, winnerSeat: first)
            }
            return
        }

        let tbCards = Array(pool.prefix(5))

        let tb = TiebreakBoard(
            parentBoardIdx: parentBoardIdx,
            round: round,
            cards: tbCards,
            eligibleSeats: eligibleSeats
        )
        gs.tiebreakBoards.append(tb)
        gs.phase = .tiebreakAnnouncing
        gs.announceDeadline = computeDeadline(seconds: current.announceTimerSeconds)
        current.gameState = gs
        room = current
        log("enterTiebreak: parent=\(parentBoardIdx) round=\(round) seats=\(eligibleSeats) pool=\(pool.count + 5)")
        await broadcastSnapshot()
        scheduleAnnounceTimerIfNeeded(gs.announceDeadline)
    }

    /// Host : évalue le tie-break courant. Si winner unique → finalise le parent.
    /// Si re-split → enter un round suivant. Si plus de pool → arbitraire.
    private func revealTiebreakBoard() async {
        guard role == .host, var current = room, var gs = current.gameState else { return }
        guard gs.phase == .tiebreakAnnouncing else { return }
        announceTimerTask?.cancel()
        announceTimerTask = nil
        guard var tb = gs.tiebreakBoards.last,
              let parentResult = gs.boardResults[tb.parentBoardIdx],
              let catId = parentResult.winningCategoryId,
              let lockedCat = HandCategory.from(id: catId) else { return }

        let tbCards = tb.cards

        // Build per-player
        var perPlayer: [PlayerBoardResult] = []
        for seat in tb.eligibleSeats {
            guard let player = gs.players.first(where: { $0.seat == seat }) else { continue }
            let sub = tb.submissions[seat]
            let cards = sub?.cards ?? []
            let isSkip = sub?.categoryId == "skip"
            var isValid = false
            if !isSkip, !cards.isEmpty {
                isValid = HandEvaluator.validateAnnounce(lockedCat, hole: cards, board: tbCards)
            } else if !isSkip, lockedCat == .highcard {
                isValid = true
            }
            let isBluff = !isSkip && !isValid
            perPlayer.append(PlayerBoardResult(
                userId: player.userId, seat: seat,
                announcedCategoryId: catId,
                cards: cards, isValid: isValid, isBluff: isBluff,
                isSkip: isSkip, isExcluded: false, isForfeit: false
            ))
        }

        // Détermine winner / re-split
        let validResults = perPlayer.filter { $0.isValid }
        var winnerSeat: Int? = nil
        var isSplit = false
        var splitterSeats: [Int] = []

        if validResults.isEmpty {
            // Personne n'a fait l'annonce valide (cas rare) → on prend le 1er éligible
            winnerSeat = tb.eligibleSeats.first
        } else {
            let sorted = validResults.sorted { a, b in
                compareWithinCategory(lockedCat, a: a.cards, b: b.cards, board: tbCards) > 0
            }
            let top = sorted[0]
            let tied = sorted.filter { r in
                compareWithinCategory(lockedCat, a: r.cards, b: top.cards, board: tbCards) == 0
            }
            if tied.count >= 2 {
                isSplit = true
                splitterSeats = tied.map { $0.seat }
            } else {
                winnerSeat = top.seat
            }
        }

        tb.result = BoardResult(
            board: tb.parentBoardIdx,
            winnerSeat: winnerSeat,
            winningCategoryId: catId,
            finalMulti: parentResult.finalMulti,
            isSplit: isSplit,
            splitterSeats: splitterSeats,
            perPlayer: perPlayer,
            abandoned: false
        )
        gs.tiebreakBoards[gs.tiebreakBoards.count - 1] = tb
        gs.phase = .tiebreakReveal
        current.gameState = gs
        room = current
        log("revealTiebreak: parent=\(tb.parentBoardIdx) round=\(tb.round) winner=\(String(describing: winnerSeat)) split=\(isSplit)")
        await broadcastSnapshot()

        // Pause pour laisser voir le résultat
        try? await Task.sleep(nanoseconds: 4_000_000_000)

        if isSplit {
            // Re-tie-break avec les nouveaux splitters
            await enterTiebreak(parentBoardIdx: tb.parentBoardIdx,
                                eligibleSeats: splitterSeats,
                                round: tb.round + 1)
        } else if let winner = winnerSeat {
            await finalizeParentBoard(parentBoardIdx: tb.parentBoardIdx, winnerSeat: winner)
        }
    }

    /// Host : applique le résultat du tie-break au board parent (set winnerSeat,
    /// applique le scoring) et avance à la phase suivante.
    private func finalizeParentBoard(parentBoardIdx: Int, winnerSeat: Int) async {
        guard role == .host, var current = room, var gs = current.gameState else { return }
        guard var parentResult = gs.boardResults[parentBoardIdx] else { return }
        parentResult.winnerSeat = winnerSeat
        parentResult.isSplit = false
        gs.boardResults[parentBoardIdx] = parentResult
        applyBoardScoring(gs: &gs, result: parentResult)
        gs.phase = .boardReveal
        current.gameState = gs
        room = current
        log("finalizeParentBoard: parent=\(parentBoardIdx) → winner seat=\(winnerSeat)")
        await broadcastSnapshot()

        try? await Task.sleep(nanoseconds: 2_500_000_000)
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
            // Fin de la manche : full-board bonus si applicable, puis on bascule
            // en .mancheEnd pour afficher le récap et débloquer "Manche suivante".
            applyFullBoardBonus(gs: &gs)
            gs.phase = .mancheEnd
            // Archive locale de la manche pour le sheet "Solde & historique".
            let archive = buildMancheArchive(gs: gs)
            current.pastManches.append(archive)
            current.gameState = gs
            room = current
            await broadcastSnapshot()
            // Persistance Supabase : crée la `games` (1ère manche) puis insère
            // la manche + manche_results + applique les balances pairwise.
            await recordMancheToSupabase()
        }
    }

    /// Construit l'archive d'une manche terminée (delta + boards remportés
    /// + multis + nombre de joueurs actifs).
    private func buildMancheArchive(gs: OnlineGameState) -> MancheArchive {
        var perPlayerDelta: [Int: Double] = [:]
        var boardsWon: [Int: [Int]] = [:]
        var boardMultis: [Int: Int] = [:]
        for r in gs.boardResults.compactMap({ $0 }) {
            boardMultis[r.board] = r.finalMulti
        }
        for p in gs.players {
            perPlayerDelta[p.seat] = p.score - (gs.initialScores[p.seat] ?? 0)
            boardsWon[p.seat] = gs.boardResults.compactMap { r -> Int? in
                guard let r else { return nil }
                return r.winnerSeat == p.seat ? r.board : nil
            }
        }
        let numActive = gs.players.filter { $0.inManche }.count
        return MancheArchive(
            mancheNumber: gs.mancheNumber,
            dealerSeat: gs.dealerSeat,
            perPlayerDelta: perPlayerDelta,
            boardsWon: boardsWon,
            fullBoardWinnerSeat: gs.fullBoardWinnerSeat,
            numActive: numActive,
            boardMultis: boardMultis
        )
    }

    // MARK: - Scoring (RULES.md)

    /// Score d'un board : gagnant +prix×multi×(N-1), chaque autre joueur actif
    /// paie prix×multi. Skip/forfeit comptent comme "loser" (paient quand même).
    private func applyBoardScoring(gs: inout OnlineGameState, result: BoardResult) {
        guard !result.abandoned, let winnerSeat = result.winnerSeat else { return }
        let prix = gs.linePrice
        let multi = Double(result.finalMulti)
        let activeSeats = gs.players.filter { $0.inManche }.map { $0.seat }
        let N = activeSeats.count
        guard N >= 2 else { return }

        let winnerGain = prix * multi * Double(N - 1)
        let loserCost  = prix * multi

        for i in 0..<gs.players.count {
            let seat = gs.players[i].seat
            guard gs.players[i].inManche else { continue }
            if seat == winnerSeat {
                gs.players[i].score += winnerGain
            } else {
                gs.players[i].score -= loserCost
            }
        }
        log("scoring board \(result.board+1): winner seat=\(winnerSeat) +\(winnerGain), losers -\(loserCost)")
    }

    /// Bonus "Full Board" : si un même joueur a gagné les 3 boards (split compte
    /// pour le tie-break gagnant) → +prix×(N-1), chaque autre paie prix×1.
    private func applyFullBoardBonus(gs: inout OnlineGameState) {
        let winners = gs.boardResults.compactMap { $0?.winnerSeat }
        guard winners.count == 3, Set(winners).count == 1, let fbWinner = winners.first else {
            return
        }
        let prix = gs.linePrice
        let activeSeats = gs.players.filter { $0.inManche }.map { $0.seat }
        let N = activeSeats.count
        guard N >= 2 else { return }

        let bonus = prix * Double(N - 1)
        let cost  = prix

        for i in 0..<gs.players.count {
            let seat = gs.players[i].seat
            guard gs.players[i].inManche else { continue }
            if seat == fbWinner {
                gs.players[i].score += bonus
            } else {
                gs.players[i].score -= cost
            }
        }
        gs.fullBoardWinnerSeat = fbWinner
        log("FULL BOARD bonus: seat=\(fbWinner) +\(bonus)")
    }

    // MARK: - Connectivity : forfeit + host transfer (Realtime presence)

    /// Traite les `presenceChange.leaves`. Comportement unifié pour host ET guests :
    ///  - Marque les joueurs comme déconnectés + forfait pour la manche courante
    ///    + wantsToSpectate=true pour les manches suivantes (le solde reste).
    ///  - Si c'est l'hôte qui part : élection du nouvel hôte (plus petit seat
    ///    parmi les joueurs actifs+connectés). Le nouvel hôte reprend la phase
    ///    courante via `resumeFromCurrentPhase`.
    private func handlePresenceLeaves(_ leaves: [String: PresenceV2]) async {
        guard var current = room else { return }
        let myId = myUserIdCache

        var hostLeft = false
        var anyChange = false

        for (_, presence) in leaves {
            guard case .string(let uidStr) = presence.state["user_id"],
                  let userId = UUID(uuidString: uidStr) else { continue }
            if userId == myId { continue }

            if userId == current.hostUserId {
                hostLeft = true
            }

            if var gs = current.gameState,
               let i = gs.players.firstIndex(where: { $0.userId == userId }) {
                if gs.players[i].connected {
                    gs.players[i].connected = false
                    anyChange = true
                }
                let inLiveManche = gs.phase != .mancheEnd
                if inLiveManche && gs.players[i].inManche && gs.players[i].forfeitFromBoard == nil {
                    gs.players[i].forfeitFromBoard = gs.currentBoard
                    log("forfeit: seat=\(gs.players[i].seat) (\(uidStr.prefix(8))) from board \(gs.currentBoard + 1)")
                    anyChange = true
                }
                // Retire des manches suivantes (tant qu'il n'a pas explicitement
                // rejoint via le popover spectateurs).
                if !gs.players[i].wantsToSpectate {
                    gs.players[i].wantsToSpectate = true
                    anyChange = true
                }
                current.gameState = gs
            }
        }

        if anyChange {
            room = current
        }

        if hostLeft && role != .host {
            await electNewHost()
            return
        }

        if role == .host {
            if anyChange {
                await broadcastSnapshot()
                await checkAutoRevealAfterDisconnect()
            }
        }
    }

    /// Si un forfait débloque le reveal (tous les remaining ont soumis),
    /// on déclenche immédiatement pour ne pas rester bloqué.
    private func checkAutoRevealAfterDisconnect() async {
        guard role == .host, let gs = room?.gameState else { return }
        if gs.phase == .announcing {
            let eligible = eligibleSeats(in: gs)
            if Set(gs.submissions.keys).isSuperset(of: eligible) {
                await revealBoard()
            }
        } else if gs.phase == .tiebreakAnnouncing, let tb = gs.tiebreakBoards.last {
            let stillEligible = tb.eligibleSeats.filter { seat in
                guard let p = gs.players.first(where: { $0.seat == seat }) else { return false }
                return p.forfeitFromBoard == nil && p.connected
            }
            let submitted = Set(tb.submissions.keys)
            if submitted.isSuperset(of: Set(stillEligible)) {
                await revealTiebreakBoard()
            }
        }
    }

    // MARK: - Host election + claim

    /// Quand l'host disparaît : on élit le candidat de plus petit seat (parmi
    /// les joueurs encore actifs + connectés). Si c'est moi → je prends la main.
    private func electNewHost() async {
        guard let myId = myUserIdCache, let current = room, let gs = current.gameState else { return }
        // 1) Priorité : un joueur actif et connecté (autre que l'ex-hôte).
        let active = gs.players
            .filter { $0.inManche && $0.connected && $0.userId != current.hostUserId }
            .sorted { $0.seat < $1.seat }
        // 2) Sinon : n'importe quel spectateur connecté (participant), pour
        //    éviter une partie figée si tous les joueurs actifs sont déco.
        let spectatorFallback = current.participants
            .filter { $0.userId != current.hostUserId }
            .map { p -> (UUID, String) in (p.userId, p.displayName) }
        let newHost: (userId: UUID, displayName: String)?
        if let a = active.first {
            newHost = (a.userId, a.displayName)
        } else if let s = spectatorFallback.first {
            newHost = s
        } else {
            newHost = nil
        }
        guard let newHost else {
            log("electNewHost: aucun candidat, partie en attente")
            // On est seul·e : informe l'UI pour éviter un état "figé sans raison".
            lastError = "Hôte déconnecté — aucun autre joueur disponible."
            return
        }
        log("electNewHost: candidate = \(newHost.displayName) (\(newHost.userId.uuidString.prefix(8)))")
        if newHost.userId == myId {
            await becomeHost(via: "election after host disconnect")
        }
        // Sinon : on attend que ce candidat broadcast le snapshot avec son
        // hostUserId, on switchera nos rôles en réception.
    }

    /// Prend explicitement le rôle hôte, broadcast un snapshot mettant à jour
    /// `hostUserId` et `participants.isHost`, et reprend la phase en cours.
    private func becomeHost(via reason: String) async {
        guard let myId = myUserIdCache, var current = room else { return }
        role = .host
        current.hostUserId = myId
        for i in 0..<current.participants.count {
            current.participants[i].isHost = (current.participants[i].userId == myId)
        }
        room = current
        log("becomeHost: \(reason)")
        await broadcastSnapshot()
        await resumeFromCurrentPhase()
    }

    /// Le nouvel hôte (élu ou reçu via snapshot) doit faire avancer la phase
    /// si on était au milieu d'une animation côté ex-hôte (community reveal,
    /// délai de boardReveal, etc.).
    private func resumeFromCurrentPhase() async {
        guard role == .host, let gs = room?.gameState else { return }
        log("resumeFromCurrentPhase: phase=\(gs.phase.rawValue)")
        switch gs.phase {
        case .dealing, .flop, .turn, .river:
            await revealCommunityProgressively()
        case .announcing, .tiebreakAnnouncing:
            // Le timer broadcast a une deadline absolue → on re-schedule local
            scheduleAnnounceTimerIfNeeded(gs.announceDeadline)
        case .boardReveal:
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            await advanceAfterReveal()
        case .tiebreakReveal:
            try? await Task.sleep(nanoseconds: 3_500_000_000)
            guard let tb = gs.tiebreakBoards.last, let result = tb.result else { return }
            if result.isSplit {
                await enterTiebreak(parentBoardIdx: tb.parentBoardIdx,
                                    eligibleSeats: result.splitterSeats,
                                    round: tb.round + 1)
            } else if let winner = result.winnerSeat {
                await finalizeParentBoard(parentBoardIdx: tb.parentBoardIdx, winnerSeat: winner)
            }
        case .mancheEnd:
            break // attendre que le nouvel hôte tape "Manche suivante"
        }
    }

    /// Avant de passer en spectateur, l'host transfère son rôle au prochain
    /// candidat actif. Le snapshot broadcast reflète le nouveau hostUserId →
    /// le candidat claim son rôle en réception.
    private func transferHostBeforeSpectating() async {
        guard role == .host, let myId = myUserIdCache, var current = room,
              let gs = current.gameState else { return }
        let candidates = gs.players
            .filter { $0.inManche && $0.connected && $0.userId != myId }
            .sorted { $0.seat < $1.seat }
        guard let newHost = candidates.first else {
            log("transferHostBeforeSpectating: aucun candidat, je reste hôte")
            return
        }
        current.hostUserId = newHost.userId
        for i in 0..<current.participants.count {
            current.participants[i].isHost = (current.participants[i].userId == newHost.userId)
        }
        room = current
        await broadcastSnapshot()
        role = .guest
        log("transferHostBeforeSpectating: rôle transféré à \(newHost.displayName)")
    }

    // MARK: - Persistance Supabase (record_manche RPC)

    /// Host uniquement : envoie la manche au RPC record_manche. Crée la game
    /// à la 1ère manche, ré-utilise cloudGameId ensuite. Le RPC dérive aussi
    /// les balances pairwise via le trigger _apply_balances_for_manche.
    private func recordMancheToSupabase() async {
        guard role == .host, var current = room, let gs = current.gameState else { return }
        guard gs.phase == .mancheEnd else { return }

        let numActive = gs.players.filter { $0.inManche }.count
        guard numActive >= 2 else { return }

        // Participants : on prend l'index dans `participants` comme seat.
        let participants = current.participants.enumerated().map { idx, p in
            RecordMancheParticipant(
                seat_index: idx,
                user_id: p.userId.uuidString,
                guest_name: nil
            )
        }

        // Board results : on sérialise les 3 boards + les tie-breaks groupés sous
        // la clé du parent (pour traçabilité). On garde un format simple jsonb.
        let boardResults: [RecordMancheBoardResult] = (0..<3).compactMap { i in
            guard let r = gs.boardResults[i] else {
                return RecordMancheBoardResult(board: i, winner_seat: nil,
                                                category_id: nil, multi: 1,
                                                is_split: false, abandoned: true)
            }
            return RecordMancheBoardResult(
                board: r.board,
                winner_seat: r.winnerSeat,
                category_id: r.winningCategoryId,
                multi: r.finalMulti,
                is_split: r.isSplit,
                abandoned: r.abandoned
            )
        }

        // Results per seat : delta = score actuel - score initial de la manche.
        let resultsPerSeat: [RecordMancheResultPerSeat] = gs.players.map { p in
            let initial = gs.initialScores[p.seat] ?? 0
            let delta = p.score - initial
            // Boards remportés par ce joueur cette manche
            let boardsWon = gs.boardResults.compactMap { r -> Int? in
                guard let r else { return nil }
                return r.winnerSeat == p.seat ? r.board : nil
            }
            return RecordMancheResultPerSeat(
                seat_index: p.seat,
                delta: delta,
                boards_won_json: boardsWon
            )
        }

        let settings = RecordMancheSettings(
            flash_mode: current.flashMode,
            announce_timer_seconds: current.announceTimerSeconds
        )

        let params = RecordMancheParams(
            p_game_id: current.cloudGameId?.uuidString,
            p_mode: "online",
            p_line_price: current.linePrice,
            p_currency: "EUR",
            p_settings_json: settings,
            p_participants: participants,
            p_manche_number: gs.mancheNumber,
            p_dealer_seat: gs.dealerSeat,
            p_num_active: numActive,
            p_board_results: boardResults,
            p_full_board_seat: gs.fullBoardWinnerSeat,
            p_results_per_seat: resultsPerSeat
        )

        do {
            log("record_manche RPC: manche=\(gs.mancheNumber) gameId=\(current.cloudGameId?.uuidString.prefix(8) ?? "new")")
            let response = try await client.rpc("record_manche", params: params).execute()
            // Le RPC renvoie un UUID. PostgREST le sérialise en string JSON.
            let returnedGameId = try JSONDecoder().decode(UUID.self, from: response.data)
            if current.cloudGameId == nil {
                current.cloudGameId = returnedGameId
                room = current
                await broadcastSnapshot()
            }
            log("record_manche OK gameId=\(returnedGameId.uuidString.prefix(8))")
        } catch {
            log("record_manche FAILED: \(error.localizedDescription)")
            // Pas de retry — la manche reste affichée localement, on tente la
            // prochaine manche normalement (cloudGameId reste nil, donc la
            // prochaine sauvegarde crée la game).
        }
    }

    /// Host : démarre la manche suivante. Rotation du donneur, conservation des scores.
    func startNextManche() async {
        guard role == .host, var current = room else { return }
        guard let gs = current.gameState else { return }
        guard gs.phase == .mancheEnd else {
            log("startNextManche: ignoré (phase=\(gs.phase.rawValue))")
            return
        }
        log("startNextManche: from manche \(gs.mancheNumber)")

        // Spectateurs : on récupère les préférences durables de chaque seat.
        let spectatorSeats = Set(gs.players.filter { $0.wantsToSpectate }.map { $0.seat })

        // Rotation du donneur : on passe au seat suivant, en sautant les
        // spectateurs. Si tout le monde sauf un est spectateur on stoppe.
        let n = gs.players.count
        var nextDealer = (gs.dealerSeat + 1) % n
        var safety = 0
        while spectatorSeats.contains(nextDealer) && safety < n {
            nextDealer = (nextDealer + 1) % n
            safety += 1
        }
        guard !spectatorSeats.contains(nextDealer) else {
            log("startNextManche: pas assez de joueurs actifs")
            return
        }

        // Construit le nouvel état avec les mêmes participants
        guard var newState = OnlineGameService.buildInitialGameState(
            mancheNumber: gs.mancheNumber + 1,
            participants: current.participants,
            dealerSeat: nextDealer,
            linePrice: current.linePrice,
            spectatorSeats: spectatorSeats
        ) else {
            log("startNextManche: build failed (peut-être pas assez de joueurs)")
            return
        }

        // Carry-over des scores depuis la manche précédente
        let oldScores = Dictionary(uniqueKeysWithValues: gs.players.map { ($0.seat, $0.score) })
        for i in 0..<newState.players.count {
            let seat = newState.players[i].seat
            newState.players[i].score = oldScores[seat] ?? 0
        }
        // Snapshot des scores au début de la manche (utilisé pour le delta de
        // record_manche).
        newState.initialScores = Dictionary(uniqueKeysWithValues: newState.players.map { ($0.seat, $0.score) })

        current.gameState = newState
        room = current
        await broadcastSnapshot()
        log("startNextManche: state broadcast, manche \(newState.mancheNumber) dealer=\(nextDealer)")

        // Pause dramatique puis reveal community
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        await revealCommunityProgressively()
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
        linePrice: Double,
        spectatorSeats: Set<Int> = []
    ) -> OnlineGameState? {
        // Players = participants triés par ordre de connexion, seat = index.
        // Les spectateurs sont marqués inManche=false, ne reçoivent pas de cartes.
        let players = participants.enumerated().map { idx, p in
            let isSpect = spectatorSeats.contains(idx)
            return GamePlayer(
                userId: p.userId, displayName: p.displayName,
                seat: idx, score: 0,
                inManche: !isSpect, connected: true, forfeitFromBoard: nil,
                wantsToSpectate: isSpect
            )
        }
        let activeSeats = players.filter { $0.inManche }.map { $0.seat }
        let target = OnlineDealer.cardsPerPlayer(activeCount: activeSeats.count)
        guard target > 0 else { return nil }

        // Ordre de distribution : seulement les seats actifs, en partant de
        // celui après le donneur (dealer servi en dernier).
        let n = players.count
        let dealOrderAll: [Int] = (1...n).map { (dealerSeat + $0) % n }
        let dealOrder = dealOrderAll.filter { activeSeats.contains($0) }

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
            excludedThisBoard: [],
            tiebreakBoards: []
        )
        // Note : on conserve community.flop séparément pour le passage à `.flop`
        //        (geré dans la fonction `revealFlop()` à venir Phase 2.2).
    }

    // MARK: - Channel lifecycle

    private func openChannel(code: String, myUserId: UUID, myDisplayName: String) async {
        phase = .connecting
        pendingChannelCode = code
        myUserIdCache = myUserId
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

            // Track sa propre presence : permet au host de détecter les
            // déconnexions des guests (via presenceChange leaves).
            do {
                let state: JSONObject = ["user_id": .string(myUserId.uuidString)]
                try await ch.track(state: state)
                log("presence: tracked self")
            } catch {
                log("presence: track failed: \(error.localizedDescription)")
            }

            // Listener presence — host only s'en sert pour le forfeit auto.
            presenceTask?.cancel()
            presenceTask = Task { [weak self] in
                guard let self else { return }
                for await action in ch.presenceChange() {
                    if !action.leaves.isEmpty {
                        await self.handlePresenceLeaves(action.leaves)
                    }
                }
            }

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
            // Côté host : on ajoute le guest à la liste, ou marque la reconnexion
            // si déjà connu.
            guard role == .host, var current = room else {
                log("hello ignored: role=\(String(describing: role)) room=\(room == nil ? "nil" : "set")")
                return
            }
            if current.participants.contains(where: { $0.userId == userId }) {
                log("hello reconnect: \(displayName)")
                // Marque comme reconnecté dans gs.players (s'il y est).
                if var gs = current.gameState,
                   let pIdx = gs.players.firstIndex(where: { $0.userId == userId }) {
                    if !gs.players[pIdx].connected {
                        gs.players[pIdx].connected = true
                    }
                    current.gameState = gs
                    room = current
                }
                await broadcastSnapshot()
            } else {
                log("hello new guest \(displayName) (\(userId.uuidString.prefix(8))), adding")
                current.participants.append(
                    OnlineParticipant(userId: userId, displayName: displayName, isHost: false)
                )
                // Si la partie est déjà en cours, on N'AJOUTE PAS au gs.players —
                // il reste spectateur jusqu'à la prochaine manche.
                room = current
                await broadcastSnapshot()
            }

        case .snapshot(let snapshot):
            // Côté guest (ou rejoin) : on prend le snapshot du host
            if role == .guest {
                let phaseStr = snapshot.gameState?.phase.rawValue ?? "—"
                log("snapshot received (\(snapshot.participants.count) participants, status=\(snapshot.status.rawValue), phase=\(phaseStr))")
                self.room = snapshot
                if snapshot.status == .playing {
                    self.phase = .playing
                }
                helloRetryTask?.cancel()
                // Si le snapshot désigne MON userId comme hôte → je claim le rôle
                // (cas typique : ex-hôte a déco / passé en spec, m'a transféré).
                if snapshot.hostUserId == myUserId {
                    log("snapshot transfers host to me — claiming")
                    await becomeHost(via: "host transfer via snapshot")
                }
            } else if role == .host {
                // Reçu mon propre broadcast OU un broadcast d'un autre client qui
                // pense être hôte. Si le snapshot ne me désigne PAS comme hôte,
                // je me démote.
                if snapshot.hostUserId != myUserId {
                    log("snapshot transfers host away from me — demoting to guest")
                    role = .guest
                    self.room = snapshot
                    announceTimerTask?.cancel()
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

        case .setSpectator(let seat, let wantsToSpectate):
            if role == .host {
                log("setSpectator request seat=\(seat) wants=\(wantsToSpectate)")
                await applySpectatorChange(seat: seat, wantsToSpectate: wantsToSpectate)
            }
        }
    }

    private func broadcastSnapshot() async {
        guard let snapshot = room else { return }
        log("broadcasting snapshot (status=\(snapshot.status.rawValue), \(snapshot.participants.count) participants)")
        try? await sendMessage(.init(kind: .roomSnapshot, payload: .snapshot(snapshot)))
        // Persistance locale du host pour la "Reprendre la partie" banner.
        if role == .host {
            persistHostState(snapshot)
        }
    }

    // MARK: - Resume banner — host state persisté en UserDefaults

    private static let resumeStorageKey = "online_host_resume_state"
    private static let resumeMaxAgeSec: TimeInterval = 60 * 60 // 1h

    private func persistHostState(_ room: OnlineRoom) {
        // On stocke un wrapper { room, savedAt }. Le room JSON inclut tout
        // (gameState, participants, scores) — ça permet une vraie reprise.
        guard room.status == .playing else { return }
        do {
            let snapshot = ResumeSnapshot(room: room, savedAt: Date())
            let data = try JSONEncoder().encode(snapshot)
            UserDefaults.standard.set(data, forKey: Self.resumeStorageKey)
        } catch {
            log("persistHostState failed: \(error.localizedDescription)")
        }
    }

    private func clearHostState() {
        UserDefaults.standard.removeObject(forKey: Self.resumeStorageKey)
    }

    /// API publique pour OnlineRootView : retourne le state persisté du host
    /// si présent et récent (< 1h). Sinon nil.
    static func loadResumableHostState() -> OnlineRoom? {
        guard let data = UserDefaults.standard.data(forKey: resumeStorageKey),
              let snapshot = try? JSONDecoder().decode(ResumeSnapshot.self, from: data) else {
            return nil
        }
        if Date().timeIntervalSince(snapshot.savedAt) > resumeMaxAgeSec {
            UserDefaults.standard.removeObject(forKey: resumeStorageKey)
            return nil
        }
        return snapshot.room
    }

    static func clearResumableHostState() {
        UserDefaults.standard.removeObject(forKey: resumeStorageKey)
    }

    /// Host : reprend une partie persistée. Ouvre le channel sur le code
    /// d'origine, restaure le room state, rebroadcast pour que les guests qui
    /// se reconnectent reçoivent l'état frais.
    func resumeAsHost(savedRoom: OnlineRoom, myUserId: UUID, myDisplayName: String) async {
        log("resumeAsHost: code=\(savedRoom.code) manche=\(savedRoom.gameState?.mancheNumber ?? 0)")
        self.role = .host
        self.room = savedRoom
        self.lastError = nil
        await openChannel(code: savedRoom.code, myUserId: myUserId, myDisplayName: myDisplayName)
        // Le snapshot est broadcasté automatiquement quand un guest envoie un hello.
        // On force aussi un broadcast immédiat pour rafraîchir les guests connectés.
        await broadcastSnapshot()
    }
}

/// Wrapper persisté pour le resume banner.
private struct ResumeSnapshot: Codable {
    let room: OnlineRoom
    let savedAt: Date
}

// MARK: - RPC record_manche payload types

private struct RecordMancheParticipant: Encodable {
    let seat_index: Int
    let user_id: String?
    let guest_name: String?
}

private struct RecordMancheBoardResult: Encodable {
    let board: Int
    let winner_seat: Int?
    let category_id: String?
    let multi: Int
    let is_split: Bool
    let abandoned: Bool
}

private struct RecordMancheResultPerSeat: Encodable {
    let seat_index: Int
    let delta: Double
    let boards_won_json: [Int]
}

private struct RecordMancheSettings: Encodable {
    let flash_mode: Bool
    let announce_timer_seconds: Int
}

private struct RecordMancheParams: Encodable {
    let p_game_id: String?
    let p_mode: String
    let p_line_price: Double
    let p_currency: String
    let p_settings_json: RecordMancheSettings
    let p_participants: [RecordMancheParticipant]
    let p_manche_number: Int
    let p_dealer_seat: Int
    let p_num_active: Int
    let p_board_results: [RecordMancheBoardResult]
    let p_full_board_seat: Int?
    let p_results_per_seat: [RecordMancheResultPerSeat]
}
