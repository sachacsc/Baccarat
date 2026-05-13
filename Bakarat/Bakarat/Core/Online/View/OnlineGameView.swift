//
//  OnlineGameView.swift
//  Bakarat
//
//  Vue affichée pendant une partie en cours (room.status == .playing).
//  Phase 2.1 : affichage basique — nav title "Manche N", liste joueurs avec
//  scores, board status (Dealing / Flop / Board courant), ma main face up.
//
//  Phases ultérieures :
//   2.2 : phase d'annonce (sélection cartes + catégorie) + reveal
//   2.3 : tie-break + manche-end + scoring + persistance balance
//

import SwiftUI

struct OnlineGameView: View {
    @EnvironmentObject private var auth: AuthService
    @ObservedObject var service: OnlineGameService

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                if let gs = service.room?.gameState {
                    phaseBanner(gs)
                    communityBoards(gs)
                    if gs.phase == .announcing { announcePanel(gs) }
                    if gs.phase == .boardReveal { revealPanel(gs) }
                    if gs.phase == .mancheEnd { mancheEndPanel(gs) }
                    myHand(gs)
                    playersBar(gs)
                } else {
                    ProgressView().padding(.top, 60)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
        }
        .navigationTitle(navigationTitle)
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Announce panel (Phase 2.2)

    @ViewBuilder
    private func announcePanel(_ gs: OnlineGameState) -> some View {
        if let seat = mySeat(in: gs), let hand = gs.hands[seat] {
            AnnouncePanel(
                mySeat: seat,
                myHand: hand,
                alreadySubmitted: gs.submissions[seat] != nil,
                onSubmit: { submission in
                    Task { await service.submitAnnounce(submission: submission, mySeat: seat) }
                }
            )
        }
    }

    // MARK: - Reveal panel (Phase 2.2)

    @ViewBuilder
    private func revealPanel(_ gs: OnlineGameState) -> some View {
        if let result = gs.boardResults[gs.currentBoard] {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Image(systemName: "eye.fill")
                        .foregroundStyle(Theme.brandRed)
                    Text("Reveal Board \(gs.currentBoard + 1)")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                }
                if result.abandoned {
                    Text("Board abandonné — aucun gagnant valide.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else if let winnerSeat = result.winnerSeat,
                          let winner = gs.players.first(where: { $0.seat == winnerSeat }),
                          let catId = result.winningCategoryId,
                          let cat = HandCategory.from(id: catId) {
                    HStack(spacing: 6) {
                        Text(result.isSplit ? "⚡ Split" : "🏆 Gagnant")
                            .font(.subheadline.weight(.bold))
                        Text(winner.displayName)
                            .font(.subheadline)
                        Text("· \(cat.label)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        if cat.multi > 1 {
                            Text("×\(cat.multi)")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(Theme.brandRed)
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(Capsule().fill(Theme.brandRed.opacity(0.12)))
                        }
                    }
                }
                Divider()
                ForEach(result.perPlayer, id: \.userId) { row in
                    revealRow(gs: gs, row: row)
                }
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(.secondarySystemBackground))
            )
        }
    }

    @ViewBuilder
    private func revealRow(gs: OnlineGameState, row: PlayerBoardResult) -> some View {
        let player = gs.players.first(where: { $0.userId == row.userId })
        HStack(spacing: 8) {
            Text(player?.displayName ?? "—")
                .font(.subheadline.weight(.semibold))
                .frame(minWidth: 80, alignment: .leading)
            HStack(spacing: 3) {
                ForEach(row.cards, id: \.self) { c in
                    miniCard(c)
                }
            }
            Spacer()
            statusTag(row)
        }
    }

    @ViewBuilder
    private func statusTag(_ row: PlayerBoardResult) -> some View {
        let (txt, color): (String, Color) = {
            if row.isExcluded { return ("Hors-jeu", .gray) }
            if row.isForfeit  { return ("Forfait", .gray) }
            if row.isSkip     { return ("Skip", .gray) }
            if row.isValid    { return ("Valide", .green) }
            if row.isBluff    { return ("Bluff", .red) }
            return ("—", .gray)
        }()
        Text(txt)
            .font(.caption2.weight(.bold))
            .foregroundStyle(color)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.12)))
    }

    @ViewBuilder
    private func miniCard(_ c: Card) -> some View {
        VStack(spacing: 0) {
            Text(c.rank.display).font(.system(size: 11, weight: .bold))
            Text(c.suit.symbol).font(.system(size: 12))
        }
        .frame(width: 24, height: 34)
        .background(Color.white)
        .foregroundStyle(c.suit.isRed ? .red : .black)
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.black.opacity(0.12), lineWidth: 0.5))
    }

    // MARK: - Manche end (Phase 2.3 ajoutera le scoring détaillé)

    @ViewBuilder
    private func mancheEndPanel(_ gs: OnlineGameState) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("Manche \(gs.mancheNumber) terminée")
                    .font(.subheadline.weight(.bold))
                Spacer()
            }
            Text("Le scoring détaillé et le passage à la manche suivante arrivent en Phase 2.3.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(.secondarySystemBackground))
        )
    }

    private var navigationTitle: String {
        guard let gs = service.room?.gameState else { return "Partie en cours" }
        return "Manche \(gs.mancheNumber)"
    }

    // MARK: - Sections

    @ViewBuilder
    private func phaseBanner(_ gs: OnlineGameState) -> some View {
        HStack(spacing: 8) {
            Image(systemName: phaseIcon(gs.phase))
                .foregroundStyle(Theme.brandRed)
            Text(phaseLabel(gs.phase))
                .font(.subheadline.weight(.semibold))
            Spacer()
            // Le badge "Board X / 3" ne fait sens que pendant les annonces /
            // reveal — pendant la révélation initiale les cartes tombent sur
            // les 3 boards en même temps.
            if gs.phase == .announcing || gs.phase == .boardReveal {
                Text("Board \(gs.currentBoard + 1) / 3")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Capsule().fill(Color(.tertiarySystemBackground)))
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(.secondarySystemBackground))
        )
    }

    @ViewBuilder
    private func communityBoards(_ gs: OnlineGameState) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Tableau")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                burnsIndicator(gs.burnsRevealed)
            }
            .padding(.horizontal, 4)
            ForEach(0..<3, id: \.self) { boardIdx in
                let cards = gs.communityCards[boardIdx]
                HStack(spacing: 6) {
                    Text("B\(boardIdx + 1)")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 24)
                    ForEach(0..<5, id: \.self) { k in
                        Group {
                            if k < cards.count {
                                cardView(cards[k])
                                    .transition(.asymmetric(
                                        insertion: .scale(scale: 0.3).combined(with: .opacity),
                                        removal: .opacity
                                    ))
                            } else {
                                cardPlaceholder()
                            }
                        }
                        .animation(.spring(response: 0.45, dampingFraction: 0.7),
                                   value: cards.count)
                    }
                    Spacer()
                }
            }
        }
    }

    @ViewBuilder
    private func burnsIndicator(_ count: Int) -> some View {
        HStack(spacing: 3) {
            ForEach(0..<3, id: \.self) { i in
                Image(systemName: "flame.fill")
                    .font(.caption2)
                    .foregroundStyle(i < count ? Theme.brandRed : Color(.tertiaryLabel))
            }
        }
    }

    @ViewBuilder
    private func myHand(_ gs: OnlineGameState) -> some View {
        if let mySeat = mySeat(in: gs), let hand = gs.hands[mySeat] {
            VStack(alignment: .leading, spacing: 8) {
                Text("Tes cartes")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 4)
                HStack(spacing: 6) {
                    ForEach(Array(hand.enumerated()), id: \.element) { idx, c in
                        cardView(c)
                            .transition(.scale(scale: 0.3).combined(with: .opacity))
                            .animation(
                                .spring(response: 0.5, dampingFraction: 0.7)
                                    .delay(Double(idx) * 0.18),
                                value: hand.count
                            )
                    }
                    Spacer()
                }
            }
            .padding(.top, 6)
        }
    }

    @ViewBuilder
    private func playersBar(_ gs: OnlineGameState) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Joueurs")
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 4)
            ForEach(gs.players) { p in
                HStack(spacing: 10) {
                    Circle()
                        .fill(Theme.brandGradient)
                        .frame(width: 28, height: 28)
                        .overlay(
                            Text(String(p.displayName.prefix(1)).uppercased())
                                .font(.caption.weight(.bold))
                                .foregroundStyle(.white)
                        )
                    Text(p.displayName)
                        .font(.subheadline)
                    if p.seat == gs.dealerSeat {
                        Text("DONNEUR")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(Theme.brandRed)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().fill(Theme.brandRed.opacity(0.1)))
                    }
                    Spacer()
                    Text(formatScore(p.score))
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(p.score >= 0 ? .green : .red)
                }
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color(.secondarySystemBackground))
                )
            }
        }
    }

    // MARK: - Helpers

    private func mySeat(in gs: OnlineGameState) -> Int? {
        guard let uid = auth.userId else { return nil }
        return gs.players.first(where: { $0.userId == uid })?.seat
    }

    private func formatScore(_ v: Double) -> String {
        let sign = v >= 0 ? "+" : ""
        return "\(sign)\(String(format: "%.2f", v))€"
    }

    private func phaseLabel(_ p: GamePhase) -> String {
        switch p {
        case .dealing:     return "Le donneur distribue…"
        case .flop:        return "Brûle + Flop"
        case .turn:        return "Brûle + Turn"
        case .river:       return "Brûle + River"
        case .announcing:  return "Annonces"
        case .boardReveal: return "Reveal"
        case .mancheEnd:   return "Fin de manche"
        }
    }

    private func phaseIcon(_ p: GamePhase) -> String {
        switch p {
        case .dealing:     return "rectangle.portrait.on.rectangle.portrait.angled"
        case .flop:        return "square.stack.3d.down.right"
        case .turn:        return "arrow.turn.right.up"
        case .river:       return "water.waves"
        case .announcing:  return "hand.raised"
        case .boardReveal: return "eye"
        case .mancheEnd:   return "checkmark.circle"
        }
    }

    // MARK: - Card rendering (placeholder visuel — sera remplacé par les cartes Xadeck Phase 2.2)

    @ViewBuilder
    private func cardView(_ card: Card) -> some View {
        VStack(spacing: 0) {
            Text(card.rank.display)
                .font(.system(size: 14, weight: .bold))
            Text(card.suit.symbol)
                .font(.system(size: 16))
        }
        .frame(width: 36, height: 50)
        .background(Color.white)
        .foregroundStyle(card.suit.isRed ? .red : .black)
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.black.opacity(0.15), lineWidth: 0.5))
    }

    @ViewBuilder
    private func cardPlaceholder() -> some View {
        RoundedRectangle(cornerRadius: 5, style: .continuous)
            .strokeBorder(Color(.separator), style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
            .frame(width: 36, height: 50)
    }
}
