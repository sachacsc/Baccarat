//
//  OnlineGameView.swift
//  Bakarat
//
//  Layout per-board :
//    1. Phase banner (3 dos de cartes brûlés au lieu de flammes)
//    2. 3 sections de board, chacune : 5 cartes + statut des joueurs en dessous
//       (soumis/attente pendant l'annonce, gagnant + bouton "Autres mains" après
//       reveal)
//    3. Ma main (drag-and-drop + tap-to-select pendant l'annonce)
//    4. Panel d'annonce (sans la sélection des cartes — faite dans la main)
//
//  Sizing : largeur des cartes calculée dynamiquement via GeometryReader.
//    - board : (width - paddings) / 5
//    - main  : (width - paddings) / 6
//
//  Swipe-back navigation désactivé une fois la partie lancée.
//

import SwiftUI

struct OnlineGameView: View {
    @EnvironmentObject private var auth: AuthService
    @ObservedObject var service: OnlineGameService

    // Paddings utilisés pour le sizing dynamique
    private let outerHPadding: CGFloat = 14
    private let boardInnerHPadding: CGFloat = 24 // 12pt * 2 (background padding)
    private let boardCardGap: CGFloat = 5
    private let handCardGap: CGFloat = 3
    // Layout de la bulle "ma main" pinnée en safeAreaInset(.bottom)
    private let handBubbleOuterMargin: CGFloat = 12   // marge écran → bulle
    private let handBubbleInnerPadding: CGFloat = 14  // bulle → cartes
    private let handBubbleCornerRadius: CGFloat = 26

    /// Ordre local des cartes en main pour drag-and-drop + tri d'affichage.
    @State private var handOrder: [Card] = []
    /// Catégorie d'annonce choisie (sélection live).
    @State private var selectedCategory: HandCategory? = nil
    /// Cartes sélectionnées pour l'annonce (depuis la main au-dessus).
    @State private var selectedCards: [Card] = []
    /// Board pour lequel on ouvre le sheet "Autres mains".
    @State private var sheetBoardIdx: Int? = nil
    /// Flash mode : cartes face-down peek-révélées localement (jamais broadcast).
    /// Reset à chaque nouvelle manche.
    @State private var localFlippedCards: Set<Card> = []
    /// Flash mode : les 2 dernières cartes distribuées (donc visibles publiquement
    /// dans la teaser section ET dans ma main). Capturé au moment de la
    /// distribution puisque c'est fixé par l'ordre du deal, pas par mon tri.
    @State private var publicCards: Set<Card> = []
    /// Affiche le sheet Solde & historique (toolbar trailing).
    @State private var showingBalanceSheet = false
    /// Affiche le sheet Réglages mi-partie (toolbar leading).
    @State private var showingSettingsSheet = false
    /// Affiche le popover de la liste des spectateurs (toolbar trailing).
    @State private var showingSpectatorsPopover = false

    var body: some View {
        GeometryReader { geo in
            let availableW = geo.size.width
            ScrollView {
                VStack(spacing: 14) {
                    if let gs = service.room?.gameState {
                        phaseBanner(gs)
                        // Flash mode : les 2 dernières cartes de chaque joueur
                        // sont public et affichées au-dessus du Board 1 jusqu'à
                        // ce qu'on passe au Board 2.
                        if (service.room?.flashMode == true) && gs.currentBoard == 0 {
                            flashTeaserSection(gs)
                        }
                        ForEach(0..<3, id: \.self) { idx in
                            boardSection(gs, idx: idx, availableW: availableW)
                        }
                        ForEach(gs.tiebreakBoards) { tb in
                            tiebreakBoardSection(gs, tb: tb, availableW: availableW)
                        }
                        if (gs.phase == .announcing || gs.phase == .tiebreakAnnouncing),
                           let mySeat = mySeat(in: gs),
                           gs.players.first(where: { $0.seat == mySeat })?.inManche == true {
                            announcePanel(gs)
                        } else if gs.phase == .mancheEnd {
                            mancheEndPanel(gs)
                        }
                    } else {
                        ProgressView().padding(.top, 60)
                    }
                }
                .padding(.horizontal, outerHPadding)
                .padding(.top, 8)
                .padding(.bottom, 12)
            }
            // Timer pinné en haut (sous la nav). Visible pour TOUT LE MONDE
            // tant qu'un timer d'annonce est actif. Animé in/out à l'apparition.
            .safeAreaInset(edge: .top) {
                topTimerBar
            }
            .animation(.easeInOut(duration: 0.2), value: shouldShowTopTimer)
            // Ma main pinnée en bas (toujours visible). Bulle flottante en
            // rounded rect liquid glass — rien ne touche les bords de l'écran.
            .safeAreaInset(edge: .bottom) {
                if let gs = service.room?.gameState,
                   let seat = mySeat(in: gs),
                   gs.hands[seat] != nil,
                   gs.players.first(where: { $0.seat == seat })?.inManche == true {
                    myHand(gs, availableW: availableW)
                        .padding(.horizontal, handBubbleInnerPadding)
                        .padding(.top, 12)
                        .padding(.bottom, 10)
                        .modifier(HandBubbleLiquidGlass(cornerRadius: handBubbleCornerRadius))
                        .padding(.horizontal, handBubbleOuterMargin)
                        .padding(.bottom, 8)
                }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true) // pas de retour accidentel en partie
        .toolbar(.hidden, for: .tabBar)      // masque la tabbar pendant la partie
        .toolbar {
            ToolbarItem(placement: .principal) {
                codeNavPill
            }
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    showingSettingsSheet = true
                } label: {
                    Image(systemName: "slider.horizontal.3")
                }
                .tint(Theme.brandRed)
            }
            // Spectator count : visible UNIQUEMENT s'il y a au moins 1 spectateur
            // ou joueur en attente pour la prochaine manche. Chiffre AVANT l'œil.
            if spectatorCount > 0 {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingSpectatorsPopover = true
                    } label: {
                        HStack(spacing: 3) {
                            Text("\(spectatorCount)")
                                .font(.subheadline.weight(.semibold).monospacedDigit())
                            Image(systemName: "eye")
                        }
                    }
                    .tint(Theme.brandRed)
                    .popover(isPresented: $showingSpectatorsPopover) {
                        spectatorsPopover
                            .presentationCompactAdaptation(.popover)
                    }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showingBalanceSheet = true
                } label: {
                    Image(systemName: "eurosign.circle")
                }
                .tint(Theme.brandRed)
            }
        }
        .sheet(isPresented: $showingBalanceSheet) {
            if let room = service.room {
                BalanceHistorySheet(room: room)
            }
        }
        .sheet(isPresented: $showingSettingsSheet) {
            MidGameSettingsSheet(service: service)
        }
        .task(id: service.room?.gameState?.hands[mySeat() ?? -1]) {
            let h = service.room?.gameState?.hands[mySeat() ?? -1] ?? []
            // Les 2 dernières cartes du deal sont publiques en Flash mode.
            publicCards = Set(h.suffix(2))
            await dealHandAnimated(target: h)
        }
        .onChange(of: service.room?.gameState?.currentBoard) {
            // Reset la sélection à chaque changement de board (ou phase non-announce).
            selectedCategory = nil
            selectedCards = []
        }
        .onChange(of: service.room?.gameState?.phase) { _, newPhase in
            if newPhase != .announcing && newPhase != .tiebreakAnnouncing {
                selectedCategory = nil
                selectedCards = []
            }
        }
        .onChange(of: service.room?.gameState?.mancheNumber) {
            // Nouvelle manche → reset les cartes flippées localement (Flash mode).
            localFlippedCards = []
        }
        .sheet(isPresented: Binding(
            get: { sheetBoardIdx != nil },
            set: { newValue in if !newValue { sheetBoardIdx = nil } }
        )) {
            if let idx = sheetBoardIdx, let gs = service.room?.gameState {
                AllHandsSheet(gs: gs, boardIdx: idx)
            }
        }
    }

    // MARK: - Sizing helpers

    /// Largeur d'une carte board pour 5 cartes par row, padding inclus.
    private func boardCardW(_ availableW: CGFloat) -> CGFloat {
        let usable = availableW - 2 * outerHPadding - boardInnerHPadding
        let gaps = boardCardGap * 4
        return max(20, floor((usable - gaps) / 5))
    }

    /// Largeur d'une carte de la main pour 6 cartes — la main est dans une bulle
    /// rounded-rect flottante au safeAreaInset bottom, on retire donc la marge
    /// extérieure + le padding interne de la bulle de la largeur dispo.
    private func handCardW(_ availableW: CGFloat) -> CGFloat {
        let usable = availableW - 2 * (handBubbleOuterMargin + handBubbleInnerPadding)
        let gaps = handCardGap * 5
        return max(20, floor((usable - gaps) / 6))
    }

    // MARK: - Phase banner

    @ViewBuilder
    private func phaseBanner(_ gs: OnlineGameState) -> some View {
        HStack(spacing: 10) {
            Image(systemName: phaseIcon(gs.phase))
                .foregroundStyle(Theme.brandRed)
            Text(phaseLabel(gs.phase))
                .font(.subheadline.weight(.semibold))
            Spacer()
            burnsRow(gs.burnsRevealed)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(.secondarySystemBackground))
        )
    }

    /// Barre timer pinnée en safeAreaInset(.top) — toujours visible (sous la
    /// navbar, au-dessus du scroll) tant qu'un timer d'annonce est actif.
    @ViewBuilder
    private var topTimerBar: some View {
        if shouldShowTopTimer, let deadline = service.room?.gameState?.announceDeadline {
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                let now = ctx.date.timeIntervalSince1970
                let remaining = max(0, Int(ceil(deadline - now)))
                let color: Color = remaining <= 5 ? .red : .orange
                HStack(spacing: 6) {
                    Image(systemName: "timer")
                        .font(.caption.weight(.bold))
                    Text("Annonces · \(remaining)s")
                        .font(.subheadline.weight(.bold).monospacedDigit())
                }
                .foregroundStyle(color)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(
                    Capsule()
                        .fill(color.opacity(0.14))
                        .overlay(Capsule().stroke(color.opacity(0.30), lineWidth: 1))
                )
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    private var shouldShowTopTimer: Bool {
        guard let gs = service.room?.gameState else { return false }
        return gs.announceDeadline != nil
            && (gs.phase == .announcing || gs.phase == .tiebreakAnnouncing)
    }

    /// Section Flash mode : 2 cartes publiques de chaque joueur en jeu,
    /// affichée au-dessus du Board 1 jusqu'à la fin de ce board.
    @ViewBuilder
    private func flashTeaserSection(_ gs: OnlineGameState) -> some View {
        let active = gs.players.filter { $0.inManche && (gs.hands[$0.seat]?.count ?? 0) >= 2 }
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "eye.fill")
                    .foregroundStyle(Theme.brandRed)
                Text("Cartes ouvertes")
                    .font(.subheadline.weight(.bold))
                    .textCase(.uppercase)
                    .tracking(0.6)
                Spacer()
                Text("Visible jusqu'à fin du Board 1")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            VStack(spacing: 6) {
                ForEach(active) { p in
                    HStack(spacing: 10) {
                        Circle()
                            .fill(Theme.brandGradient)
                            .frame(width: 26, height: 26)
                            .overlay(
                                Text(String(p.displayName.prefix(1)).uppercased())
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(.white)
                            )
                        Text(p.displayName)
                            .font(.subheadline)
                        Spacer()
                        HStack(spacing: 4) {
                            ForEach(Array((gs.hands[p.seat] ?? []).suffix(2)), id: \.self) { c in
                                CardImageView(card: c, width: 30)
                            }
                        }
                    }
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(.secondarySystemBackground))
        )
    }

    @ViewBuilder
    private func burnsRow(_ count: Int) -> some View {
        HStack(spacing: 3) {
            ForEach(0..<3, id: \.self) { i in
                Group {
                    if i < count {
                        CardImageView(card: nil, faceDown: true, width: 22)
                    } else {
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .strokeBorder(Color(.tertiaryLabel),
                                          style: StrokeStyle(lineWidth: 1, dash: [2, 1.5]))
                            .frame(width: 22, height: 31)
                    }
                }
            }
        }
    }

    // MARK: - Board section

    @ViewBuilder
    private func boardSection(_ gs: OnlineGameState, idx: Int, availableW: CGFloat) -> some View {
        let cards = gs.communityCards[idx]
        let result = gs.boardResults[idx]
        let isActive = (gs.phase == .announcing || gs.phase == .boardReveal)
                       && gs.currentBoard == idx
        let cardW = boardCardW(availableW)

        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Board \(idx + 1)")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(isActive ? Theme.brandRed : .primary)
                if isActive && gs.phase == .announcing {
                    Text("· annonces en cours")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            HStack(spacing: boardCardGap) {
                ForEach(0..<5, id: \.self) { k in
                    Group {
                        if k < cards.count {
                            CardImageView(card: cards[k], width: cardW)
                                .transition(.asymmetric(
                                    insertion: .scale(scale: 0.3).combined(with: .opacity),
                                    removal: .opacity
                                ))
                        } else {
                            CardImageView(card: nil, width: cardW)
                        }
                    }
                    .animation(.spring(response: 0.45, dampingFraction: 0.7),
                               value: cards.count)
                }
            }

            statusFooter(gs: gs, boardIdx: idx, result: result, isActive: isActive)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(.secondarySystemBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(isActive ? Theme.brandRed.opacity(0.35) : Color.clear, lineWidth: 1.5)
        )
    }

    @ViewBuilder
    private func statusFooter(gs: OnlineGameState,
                              boardIdx: Int,
                              result: BoardResult?,
                              isActive: Bool) -> some View {
        if let result {
            revealedFooter(gs: gs, boardIdx: boardIdx, result: result)
        } else if isActive && gs.phase == .announcing {
            submissionRow(gs)
        } else {
            playerNamesRow(gs: gs, dimmed: true)
        }
    }

    @ViewBuilder
    private func submissionRow(_ gs: OnlineGameState) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(gs.players) { p in
                    statusChip(name: p.displayName,
                               iconName: gs.submissions[p.seat] != nil ? "checkmark.circle.fill" : "hourglass",
                               iconColor: gs.submissions[p.seat] != nil ? .green : .orange)
                }
            }
        }
    }

    @ViewBuilder
    private func playerNamesRow(gs: OnlineGameState, dimmed: Bool) -> some View {
        HStack(spacing: 6) {
            ForEach(gs.players) { p in
                Text(p.displayName)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(dimmed ? .tertiary : .secondary)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(
                        Capsule().fill(Color(.tertiarySystemBackground).opacity(dimmed ? 0.5 : 1))
                    )
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private func revealedFooter(gs: OnlineGameState,
                                boardIdx: Int,
                                result: BoardResult) -> some View {
        if result.abandoned {
            HStack(spacing: 6) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.gray)
                Text("Board abandonné")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                autresMainsButton(boardIdx: boardIdx)
            }
        } else if let winnerSeat = result.winnerSeat,
                  let winner = gs.players.first(where: { $0.seat == winnerSeat }),
                  let catId = result.winningCategoryId,
                  let cat = HandCategory.from(id: catId) {
            // On affiche UNIQUEMENT les cartes que le gagnant a annoncées, pas
            // toute sa main. Si annonce auto (Hauteur, cards vides) → autoPick.
            let winnerRow = result.perPlayer.first(where: { $0.seat == winnerSeat })
            let displayedCards: [Card] = {
                if let row = winnerRow, !row.cards.isEmpty { return row.cards }
                if let hole = gs.hands[winnerSeat] {
                    return HandEvaluator.autoPickCards(announced: cat,
                                                       hole: hole,
                                                       board: gs.communityCards[boardIdx]) ?? []
                }
                return []
            }()
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Text(result.isSplit ? "⚡" : "🏆")
                    Text(winner.displayName)
                        .font(.subheadline.weight(.bold))
                    Text(cat.label)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.brandRed)
                    if cat.multi > 1 {
                        Text("×\(cat.multi)")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(Theme.brandRed)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Capsule().fill(Theme.brandRed.opacity(0.15)))
                    }
                    Spacer()
                }
                HStack(spacing: 6) {
                    HStack(spacing: 4) {
                        ForEach(displayedCards, id: \.self) { c in
                            CardImageView(card: c, width: 32)
                        }
                    }
                    Spacer()
                    autresMainsButton(boardIdx: boardIdx)
                }
            }
        }
    }

    @ViewBuilder
    private func autresMainsButton(boardIdx: Int) -> some View {
        Button {
            sheetBoardIdx = boardIdx
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "rectangle.stack.fill")
                    .font(.caption2)
                Text("Autres mains")
                    .font(.caption.weight(.semibold))
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Capsule().fill(Color(.tertiarySystemBackground)))
            .foregroundStyle(.primary)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func statusChip(name: String, iconName: String, iconColor: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: iconName)
                .font(.system(size: 11))
                .foregroundStyle(iconColor)
            Text(name)
                .font(.caption2.weight(.semibold))
                .lineLimit(1)
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(Capsule().fill(Color(.tertiarySystemBackground)))
    }

    // MARK: - My hand (drag-drop + tap-to-select)

    @ViewBuilder
    private func myHand(_ gs: OnlineGameState, availableW: CGFloat) -> some View {
        if let seat = mySeat(in: gs), gs.hands[seat] != nil {
            let cardW = handCardW(availableW)
            // Sélection libre pendant l'annonce (announce normale OU tie-break).
            // Confirmer reste bloqué tant que catégorie + cartes ne sont pas faits.
            let canSelect: Bool = {
                if gs.phase == .announcing && gs.submissions[seat] == nil {
                    return true
                }
                if gs.phase == .tiebreakAnnouncing,
                   let tb = gs.tiebreakBoards.last,
                   tb.eligibleSeats.contains(seat),
                   tb.submissions[seat] == nil {
                    return true
                }
                return false
            }()

            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Text("Ta main")
                        .font(.subheadline.weight(.semibold))
                    if seat == gs.dealerSeat {
                        Text("DONNEUR")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(Theme.brandRed)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().fill(Theme.brandRed.opacity(0.10)))
                    }
                    Spacer()
                    if let me = gs.players.first(where: { $0.seat == seat }) {
                        Text(formatScore(me.score))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(me.score >= 0 ? .green : .red)
                    }
                }
                .padding(.horizontal, 4)

                let flashMode = service.room?.flashMode ?? false
                HStack(spacing: handCardGap) {
                    ForEach(Array(handOrder.enumerated()), id: \.element) { idx, c in
                        // Flash mode : seules les cartes du set `publicCards`
                        // (= les 2 dernières dealt) sont face-up. Les autres
                        // sont face-down jusqu'à click-to-flip local.
                        let isFaceDown = flashMode
                                         && !publicCards.contains(c)
                                         && !localFlippedCards.contains(c)
                        handCardView(c, width: cardW, idx: idx,
                                     canSelect: canSelect, faceDown: isFaceDown)
                    }
                }
            }
            .padding(.top, 2)
        }
    }

    @ViewBuilder
    private func handCardView(_ c: Card, width: CGFloat, idx: Int,
                              canSelect: Bool, faceDown: Bool) -> some View {
        let isSelected = selectedCards.contains(c)
        CardImageView(card: c, faceDown: faceDown, width: width)
            .overlay(
                RoundedRectangle(cornerRadius: max(4, width * 0.075), style: .continuous)
                    .stroke(isSelected ? Theme.brandRed : Color.clear,
                            lineWidth: 2.5)
            )
            .offset(y: isSelected ? -10 : 0)
            .animation(.easeOut(duration: 0.15), value: isSelected)
            .onTapGesture {
                if faceDown {
                    // Flash mode peek : flippe localement (persisté pour la manche)
                    localFlippedCards.insert(c)
                } else if canSelect {
                    toggleSelection(c)
                }
            }
            .draggable(c)
            .dropDestination(for: Card.self) { droppedCards, _ in
                handleDrop(droppedCards, atIndex: idx)
            }
            .transition(.scale(scale: 0.3).combined(with: .opacity))
            .animation(.spring(response: 0.5, dampingFraction: 0.7),
                       value: handOrder.count)
    }

    // MARK: - Announce panel

    @ViewBuilder
    private func announcePanel(_ gs: OnlineGameState) -> some View {
        if let seat = mySeat(in: gs) {
            let isTiebreak = gs.phase == .tiebreakAnnouncing
            let lockedCat: HandCategory? = isTiebreak ? tiebreakLockedCategory(gs) : nil
            let activeTb = gs.tiebreakBoards.last
            let alreadySubmitted: Bool = isTiebreak
                ? (activeTb?.submissions[seat] != nil)
                : (gs.submissions[seat] != nil)
            let isEligible: Bool = isTiebreak
                ? (activeTb?.eligibleSeats.contains(seat) ?? false)
                : true

            if isTiebreak && !isEligible {
                // Spectateur sur ce tie-break (n'était pas dans les splitters)
                HStack(spacing: 8) {
                    Image(systemName: "eye").foregroundStyle(.secondary)
                    Text("Tu n'es pas concerné par ce tie-break.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color(.secondarySystemBackground))
                )
            } else {
                let boardCardsForAnnounce = isTiebreak
                    ? (activeTb?.cards ?? [])
                    : gs.communityCards[gs.currentBoard]
                AnnouncePanel(
                    alreadySubmitted: alreadySubmitted,
                    lockedCategory: lockedCat,
                    boardCards: boardCardsForAnnounce,
                    myHole: gs.hands[seat] ?? [],
                    allCommunityCards: gs.communityCards,
                    selectedCategory: $selectedCategory,
                    selectedCards: selectedCards,
                    onConfirm: {
                        // Si pas de catégorie : auto-Hauteur avec les 2 plus hautes
                        // cartes de la main (top by rank desc).
                        let cat = lockedCat ?? selectedCategory ?? .highcard
                        let cards: [Card] = {
                            if cat == .highcard && selectedCards.isEmpty {
                                let hole = gs.hands[seat] ?? []
                                return Array(
                                    hole.sorted { $0.rank.value > $1.rank.value }.prefix(2)
                                )
                            }
                            return selectedCards
                        }()
                        let submission = BoardSubmission(categoryId: cat.id, cards: cards)
                        Task { await service.submitAnnounce(submission: submission, mySeat: seat) }
                    },
                    onSkip: {
                        let submission = BoardSubmission(categoryId: "skip", cards: [])
                        Task { await service.submitAnnounce(submission: submission, mySeat: seat) }
                    }
                )
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color(.secondarySystemBackground))
                )
            }
        }
    }

    private func tiebreakLockedCategory(_ gs: OnlineGameState) -> HandCategory? {
        guard let tb = gs.tiebreakBoards.last,
              let parent = gs.boardResults[tb.parentBoardIdx],
              let catId = parent.winningCategoryId else { return nil }
        return HandCategory.from(id: catId)
    }

    // MARK: - Tie-break board section

    @ViewBuilder
    private func tiebreakBoardSection(_ gs: OnlineGameState, tb: TiebreakBoard, availableW: CGFloat) -> some View {
        let cardW = boardCardW(availableW)
        let isActive = (gs.phase == .tiebreakAnnouncing || gs.phase == .tiebreakReveal)
                       && gs.tiebreakBoards.last?.id == tb.id

        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "bolt.fill")
                    .foregroundStyle(Theme.brandRed)
                    .font(.caption)
                Text("Tie-break Board \(tb.parentBoardIdx + 1)")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(isActive ? Theme.brandRed : .primary)
                Text("round \(tb.round + 1)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
            }

            HStack(spacing: 5) {
                ForEach(Array(tb.cards.enumerated()), id: \.offset) { _, c in
                    CardImageView(card: c, width: cardW)
                }
            }

            if let result = tb.result {
                tiebreakResultFooter(gs: gs, result: result)
            } else if isActive && gs.phase == .tiebreakAnnouncing {
                tiebreakSubmissionRow(gs: gs, tb: tb)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(.secondarySystemBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(isActive ? Theme.brandRed.opacity(0.45) : Color.clear, lineWidth: 1.5)
        )
    }

    @ViewBuilder
    private func tiebreakSubmissionRow(gs: OnlineGameState, tb: TiebreakBoard) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(tb.eligibleSeats, id: \.self) { seat in
                    if let p = gs.players.first(where: { $0.seat == seat }) {
                        statusChip(name: p.displayName,
                                   iconName: tb.submissions[seat] != nil ? "checkmark.circle.fill" : "hourglass",
                                   iconColor: tb.submissions[seat] != nil ? .green : .orange)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func tiebreakResultFooter(gs: OnlineGameState, result: BoardResult) -> some View {
        if result.isSplit {
            HStack(spacing: 6) {
                Image(systemName: "bolt.fill").foregroundStyle(.orange)
                Text("Re-split — nouveau round nécessaire")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.orange)
                Spacer()
            }
        } else if let winnerSeat = result.winnerSeat,
                  let winner = gs.players.first(where: { $0.seat == winnerSeat }) {
            HStack(spacing: 6) {
                Text("🏆")
                Text(winner.displayName)
                    .font(.subheadline.weight(.bold))
                Text("remporte le tie-break")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
    }

    // MARK: - Manche end

    @ViewBuilder
    private func mancheEndPanel(_ gs: OnlineGameState) -> some View {
        VStack(spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("Manche \(gs.mancheNumber) terminée")
                    .font(.subheadline.weight(.bold))
                Spacer()
            }

            if let fbSeat = gs.fullBoardWinnerSeat,
               let fbWinner = gs.players.first(where: { $0.seat == fbSeat }) {
                HStack(spacing: 8) {
                    Text("🌟")
                    Text("Full board pour \(fbWinner.displayName) !")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.brandRed)
                    Spacer()
                }
                .padding(.horizontal, 10).padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Theme.brandRed.opacity(0.10))
                )
            }

            // Scores
            VStack(spacing: 6) {
                ForEach(gs.players.sorted { $0.score > $1.score }) { p in
                    HStack(spacing: 10) {
                        Circle()
                            .fill(Theme.brandGradient)
                            .frame(width: 24, height: 24)
                            .overlay(
                                Text(String(p.displayName.prefix(1)).uppercased())
                                    .font(.caption2.weight(.bold))
                                    .foregroundStyle(.white)
                            )
                        Text(p.displayName).font(.subheadline)
                        Spacer()
                        Text(formatScore(p.score))
                            .font(.subheadline.monospacedDigit().weight(.semibold))
                            .foregroundStyle(p.score >= 0 ? .green : .red)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color(.tertiarySystemBackground))
                    )
                }
            }

            if service.role == .host {
                Button {
                    Task { await service.startNextManche() }
                } label: {
                    Text("Manche suivante")
                }
                .modifier(PrimaryButtonStyle())
            } else {
                Label("En attente que l'hôte démarre la suivante…", systemImage: "hourglass")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(.secondarySystemBackground))
        )
    }

    // MARK: - Selection helpers

    private func toggleSelection(_ card: Card) {
        if let i = selectedCards.firstIndex(of: card) {
            selectedCards.remove(at: i)
        } else if selectedCards.count < 2 {
            selectedCards.append(card)
        } else {
            // Max 2 : remplace la 1ère
            selectedCards.removeFirst()
            selectedCards.append(card)
        }
    }

    // MARK: - Drag & drop helpers

    @discardableResult
    private func handleDrop(_ droppedCards: [Card], atIndex targetIdx: Int) -> Bool {
        guard let dropped = droppedCards.first,
              let fromIdx = handOrder.firstIndex(of: dropped),
              fromIdx != targetIdx else { return false }
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
            handOrder.remove(at: fromIdx)
            handOrder.insert(dropped, at: min(targetIdx, handOrder.count))
        }
        return true
    }

    /// Distribue la main visible 2 cartes à la fois avec un petit suspense
    /// entre chaque paire. Si toutes les cartes sont déjà présentes, no-op
    /// (juste reorder). Garde l'ordre utilisateur pour les cartes déjà en main
    /// (drag-drop préservé).
    @MainActor
    private func dealHandAnimated(target: [Card]) async {
        let targetSet = Set(target)
        // Cartes qu'on garde dans leur ordre actuel (encore en main)
        let kept = handOrder.filter { targetSet.contains($0) }
        let keptSet = Set(kept)
        // Nouvelles cartes à ajouter, triées par rang desc + couleur
        let added = target.filter { !keptSet.contains($0) }
            .sorted { sortKey($0) > sortKey($1) }

        // Aucune nouvelle carte → on aligne juste l'ordre (cas où le sync
        // suit une simple mutation, ou cas dégénéré).
        if added.isEmpty {
            if kept != handOrder { handOrder = kept }
            return
        }

        // Reset à `kept` (le plus souvent vide pour une nouvelle manche),
        // puis on push les paires de cartes avec un délai entre chaque.
        handOrder = kept
        var remaining = added
        while !remaining.isEmpty {
            let take = min(2, remaining.count)
            let pair = Array(remaining.prefix(take))
            remaining.removeFirst(take)
            try? await Task.sleep(nanoseconds: 700_000_000) // 0.7s entre paires
            withAnimation(.spring(response: 0.55, dampingFraction: 0.72)) {
                handOrder.append(contentsOf: pair)
            }
        }
    }

    private func sortKey(_ card: Card) -> Int {
        // Rang en priorité (descendant), couleur en tiebreak.
        card.rank.value * 10 + suitOrder(card.suit)
    }

    private func suitOrder(_ suit: Suit) -> Int {
        switch suit {
        case .spades:   4
        case .hearts:   3
        case .diamonds: 2
        case .clubs:    1
        }
    }

    // MARK: - Code pill (nav principal)

    @ViewBuilder
    private var codeNavPill: some View {
        if let code = service.room?.code {
            Text(code)
                .font(.system(size: 14, weight: .bold, design: .monospaced))
                .tracking(2.5)
                .foregroundStyle(Color(.systemBackground))
                .padding(.horizontal, 12).padding(.vertical, 5)
                .background(Capsule().fill(Color.primary))
        }
    }

    // MARK: - Spectator popover

    /// Tous ceux qui ne jouent PAS sur la manche courante : soit déjà dans
    /// gs.players avec inManche=false (spectateurs explicites ou déconnectés),
    /// soit des participants qui ont rejoint en cours de partie et qui n'ont
    /// donc pas encore de seat.
    private struct SpectatorEntry: Identifiable {
        let userId: UUID
        let displayName: String
        let connected: Bool
        let isMidGameJoiner: Bool
        var id: UUID { userId }
    }

    private var spectatorEntries: [SpectatorEntry] {
        guard let room = service.room else { return [] }
        let gs = room.gameState
        let activeIds = Set(gs?.players.filter { $0.inManche }.map { $0.userId } ?? [])

        return room.participants.compactMap { p -> SpectatorEntry? in
            if activeIds.contains(p.userId) { return nil }
            // S'il est dans gs.players, on sait si connecté ; sinon c'est un
            // mid-game joiner (toujours connecté par construction puisqu'il vient
            // d'envoyer hello).
            if let inState = gs?.players.first(where: { $0.userId == p.userId }) {
                return SpectatorEntry(
                    userId: p.userId,
                    displayName: p.displayName,
                    connected: inState.connected,
                    isMidGameJoiner: false
                )
            }
            return SpectatorEntry(
                userId: p.userId,
                displayName: p.displayName,
                connected: true,
                isMidGameJoiner: true
            )
        }
    }

    private var spectatorCount: Int { spectatorEntries.count }

    @ViewBuilder
    private var spectatorsPopover: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Spectateurs")
                .font(.subheadline.weight(.bold))
            if spectatorEntries.isEmpty {
                Text("Aucun spectateur pour l'instant.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(spectatorEntries) { entry in
                    HStack(spacing: 8) {
                        Circle()
                            .fill(Theme.brandGradient)
                            .frame(width: 22, height: 22)
                            .overlay(
                                Text(String(entry.displayName.prefix(1)).uppercased())
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(.white)
                            )
                        Text(entry.displayName)
                            .font(.subheadline)
                            .foregroundStyle(entry.connected ? .primary : .secondary)
                        if !entry.connected {
                            Image(systemName: "wifi.slash")
                                .font(.caption2)
                                .foregroundStyle(.orange)
                        }
                        if entry.isMidGameJoiner {
                            Text("Nouveau")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(Capsule().fill(Color(.tertiarySystemBackground)))
                        }
                        Spacer()
                    }
                }
            }
            if isCurrentUserSpectator {
                Divider()
                Button {
                    showingSpectatorsPopover = false
                    Task { await service.setSelfSpectator(false) }
                } label: {
                    Label("Rejoindre la partie", systemImage: "arrow.uturn.left.circle")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(Capsule().fill(Theme.brandRed.opacity(0.12)))
                        .foregroundStyle(Theme.brandRed)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(14)
        .frame(minWidth: 240)
    }

    private var isCurrentUserSpectator: Bool {
        guard let uid = auth.userId else { return false }
        // Soit pas encore dans gs.players (mid-game joiner), soit présent mais inManche=false
        if let gs = service.room?.gameState {
            if let me = gs.players.first(where: { $0.userId == uid }) {
                return !me.inManche
            }
            // Pas dans gs.players → mid-game joiner = spectateur de fait
            return service.room?.participants.contains(where: { $0.userId == uid }) ?? false
        }
        return false
    }

    // MARK: - Helpers

    private var navigationTitle: String {
        guard let gs = service.room?.gameState else { return "Partie en cours" }
        return "Manche \(gs.mancheNumber)"
    }

    private func mySeat(in gs: OnlineGameState) -> Int? {
        guard let uid = auth.userId else { return nil }
        return gs.players.first(where: { $0.userId == uid })?.seat
    }

    private func mySeat() -> Int? {
        guard let gs = service.room?.gameState else { return nil }
        return mySeat(in: gs)
    }

    private func formatScore(_ v: Double) -> String {
        let sign = v >= 0 ? "+" : ""
        return "\(sign)\(String(format: "%.2f", v))€"
    }

    private func phaseLabel(_ p: GamePhase) -> String {
        switch p {
        case .dealing:             return "Distribution…"
        case .flop:                return "Brûle + Flop"
        case .turn:                return "Brûle + Turn"
        case .river:               return "Brûle + River"
        case .announcing:          return "Annonces"
        case .boardReveal:         return "Reveal"
        case .tiebreakAnnouncing:  return "Tie-break — annonces"
        case .tiebreakReveal:      return "Tie-break — reveal"
        case .mancheEnd:           return "Fin de manche"
        }
    }

    private func phaseIcon(_ p: GamePhase) -> String {
        switch p {
        case .dealing:             return "rectangle.portrait.on.rectangle.portrait.angled"
        case .flop:                return "square.stack.3d.down.right"
        case .turn:                return "arrow.turn.right.up"
        case .river:               return "water.waves"
        case .announcing:          return "hand.raised"
        case .boardReveal:         return "eye"
        case .tiebreakAnnouncing:  return "bolt"
        case .tiebreakReveal:      return "bolt.fill"
        case .mancheEnd:           return "checkmark.circle"
        }
    }
}

/// Bulle flottante en rounded rect avec liquid glass (iOS 26+) ou
/// `.ultraThinMaterial` en fallback. Légère shadow pour le détacher du fond.
private struct HandBubbleLiquidGlass: ViewModifier {
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        Group {
            if #available(iOS 26.0, *) {
                content.glassEffect(.regular, in: shape)
            } else {
                content
                    .background(shape.fill(.ultraThinMaterial))
                    .overlay(shape.stroke(Color.primary.opacity(0.06), lineWidth: 0.5))
            }
        }
        .compositingGroup()
        .shadow(color: .black.opacity(0.18), radius: 14, x: 0, y: 4)
    }
}
