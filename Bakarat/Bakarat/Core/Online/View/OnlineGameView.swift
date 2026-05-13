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
            if gs.phase != .dealing && gs.phase != .mancheEnd {
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
            Text("Tableau")
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 4)
            ForEach(0..<3, id: \.self) { boardIdx in
                let cards = gs.communityCards[boardIdx]
                HStack(spacing: 6) {
                    Text("B\(boardIdx + 1)")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 24)
                    ForEach(0..<5, id: \.self) { k in
                        if k < cards.count {
                            cardView(cards[k])
                        } else {
                            cardPlaceholder()
                        }
                    }
                    Spacer()
                }
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
                    ForEach(hand, id: \.self) { c in
                        cardView(c)
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
        case .dealing:     return "Distribution"
        case .flop:        return "Flop révélé"
        case .announcing:  return "Annonces"
        case .boardReveal: return "Reveal"
        case .turn:        return "Turn"
        case .river:       return "River"
        case .mancheEnd:   return "Fin de manche"
        }
    }

    private func phaseIcon(_ p: GamePhase) -> String {
        switch p {
        case .dealing:     return "rectangle.portrait.on.rectangle.portrait.angled"
        case .flop:        return "square.stack.3d.down.right"
        case .announcing:  return "hand.raised"
        case .boardReveal: return "eye"
        case .turn:        return "arrow.turn.right.up"
        case .river:       return "water.waves"
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
