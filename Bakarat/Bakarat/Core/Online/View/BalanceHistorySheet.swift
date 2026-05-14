//
//  BalanceHistorySheet.swift
//  Bakarat
//
//  Sheet présenté depuis la toolbar de l'écran de jeu (haut à droite).
//  Deux sections nettes :
//    1. Solde courant de TOUS les joueurs (actifs + inactifs greyed out)
//    2. Historique des gains/pertes du JOUEUR COURANT, une row par manche.
//       Chaque row est cliquable → MancheDetailView pour voir les deltas
//       de tous les joueurs sur cette manche.
//

import SwiftUI

struct BalanceHistorySheet: View {
    @EnvironmentObject private var auth: AuthService
    let room: OnlineRoom
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                balancesSection
                myHistorySection
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Solde & historique")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Fermer") { dismiss() }
                        .tint(Theme.brandRed)
                }
            }
        }
    }

    // MARK: - Section 1 : solde courant de tous les joueurs

    @ViewBuilder
    private var balancesSection: some View {
        Section {
            ForEach(allRows) { row in
                balanceRow(row)
            }
        } header: {
            sectionHeader(icon: "creditcard.fill", title: "Solde courant", color: Theme.brandRed)
        }
    }

    @ViewBuilder
    private func balanceRow(_ row: PlayerRow) -> some View {
        HStack(spacing: 12) {
            Circle()
                .fill(Theme.brandGradient)
                .frame(width: 30, height: 30)
                .overlay(
                    Text(String(row.player.displayName.prefix(1)).uppercased())
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white)
                )
                .opacity(row.isInactive ? 0.4 : 1)
            VStack(alignment: .leading, spacing: 1) {
                Text(row.player.displayName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(row.isInactive ? .secondary : .primary)
                if row.isInactive {
                    HStack(spacing: 4) {
                        Image(systemName: row.player.connected ? "pause.circle" : "wifi.slash")
                            .font(.system(size: 9))
                        Text(row.player.connected ? "Spectateur" : "Déconnecté")
                            .font(.caption2)
                    }
                    .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Text(formatMoney(row.player.score))
                .font(.subheadline.weight(.bold).monospacedDigit())
                .foregroundStyle(row.isInactive
                                 ? Color.secondary
                                 : (row.player.score >= 0 ? Color.green : Color.red))
        }
    }

    private struct PlayerRow: Identifiable {
        let player: GamePlayer
        let isInactive: Bool
        var id: Int { player.seat }
    }

    private var allRows: [PlayerRow] {
        guard let gs = room.gameState else { return [] }
        return gs.players
            .sorted { $0.score > $1.score }
            .map { PlayerRow(player: $0, isInactive: !$0.inManche || !$0.connected) }
    }

    // MARK: - Section 2 : mes deltas par manche

    @ViewBuilder
    private var myHistorySection: some View {
        Section {
            if room.pastManches.isEmpty {
                Text("Aucune manche terminée pour l'instant.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(room.pastManches.reversed()) { archive in
                    NavigationLink {
                        MancheDetailView(room: room, archive: archive)
                    } label: {
                        myMancheRow(archive)
                    }
                }
            }
        } header: {
            sectionHeader(icon: "clock.arrow.circlepath",
                          title: "Tes manches",
                          color: .secondary)
        } footer: {
            if !room.pastManches.isEmpty {
                Text("Touche une manche pour voir les gains/pertes de tous les joueurs.")
                    .font(.caption)
            }
        }
    }

    @ViewBuilder
    private func myMancheRow(_ archive: MancheArchive) -> some View {
        let myDelta = mySeat.map { archive.perPlayerDelta[$0] ?? 0 } ?? 0
        let won = mySeat.flatMap { archive.boardsWon[$0] } ?? []
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Manche \(archive.mancheNumber)")
                    .font(.subheadline.weight(.semibold))
                HStack(spacing: 4) {
                    if !won.isEmpty {
                        Text(won.map { "B\($0 + 1)" }.joined(separator: " "))
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(Theme.brandRed)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Capsule().fill(Theme.brandRed.opacity(0.12)))
                    }
                    if let fb = archive.fullBoardWinnerSeat, fb == mySeat {
                        Text("🌟 Full board")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(Theme.brandRed)
                    }
                }
            }
            Spacer()
            Text(formatMoney(myDelta))
                .font(.subheadline.weight(.bold).monospacedDigit())
                .foregroundStyle(myDelta >= 0 ? Color.green : Color.red)
        }
    }

    private var mySeat: Int? {
        guard let uid = auth.userId else { return nil }
        return room.gameState?.players.first(where: { $0.userId == uid })?.seat
    }

    // MARK: - Section header style commun

    @ViewBuilder
    private func sectionHeader(icon: String, title: String, color: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.caption.weight(.bold))
            Text(title)
                .font(.caption.weight(.bold))
                .textCase(.uppercase)
                .tracking(1.2)
        }
        .foregroundStyle(color)
    }

    private func formatMoney(_ v: Double) -> String {
        let sign = v >= 0 ? "+" : ""
        return "\(sign)\(String(format: "%.2f", v)) €"
    }
}

// MARK: - Détail par manche (NavigationLink)

struct MancheDetailView: View {
    let room: OnlineRoom
    let archive: MancheArchive

    var body: some View {
        List {
            Section {
                ForEach(rankedRows) { entry in
                    HStack(spacing: 10) {
                        Circle()
                            .fill(Theme.brandGradient)
                            .frame(width: 26, height: 26)
                            .overlay(
                                Text(String(entry.name.prefix(1)).uppercased())
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundStyle(.white)
                            )
                        VStack(alignment: .leading, spacing: 1) {
                            Text(entry.name)
                                .font(.subheadline.weight(.semibold))
                            if !entry.boardsWon.isEmpty {
                                Text(entry.boardsWon.map { "B\($0 + 1)" }.joined(separator: " "))
                                    .font(.caption2.weight(.bold))
                                    .foregroundStyle(Theme.brandRed)
                            }
                        }
                        if entry.isFullBoardWinner {
                            Text("🌟")
                                .font(.caption)
                        }
                        Spacer()
                        Text(formatMoney(entry.delta))
                            .font(.subheadline.weight(.bold).monospacedDigit())
                            .foregroundStyle(entry.delta >= 0 ? Color.green : Color.red)
                    }
                }
            } header: {
                Text("Gains/pertes")
            } footer: {
                Text("Donneur : \(nameFor(seat: archive.dealerSeat) ?? "Seat \(archive.dealerSeat)")")
                    .font(.caption)
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Manche \(archive.mancheNumber)")
        .navigationBarTitleDisplayMode(.inline)
    }

    private struct DeltaRow: Identifiable {
        let seat: Int
        let name: String
        let delta: Double
        let boardsWon: [Int]
        let isFullBoardWinner: Bool
        var id: Int { seat }
    }

    private var rankedRows: [DeltaRow] {
        archive.perPlayerDelta
            .map { (seat, delta) -> DeltaRow in
                DeltaRow(
                    seat: seat,
                    name: nameFor(seat: seat) ?? "Seat \(seat)",
                    delta: delta,
                    boardsWon: archive.boardsWon[seat] ?? [],
                    isFullBoardWinner: archive.fullBoardWinnerSeat == seat
                )
            }
            .sorted { $0.delta > $1.delta }
    }

    private func nameFor(seat: Int) -> String? {
        room.gameState?.players.first(where: { $0.seat == seat })?.displayName
    }

    private func formatMoney(_ v: Double) -> String {
        let sign = v >= 0 ? "+" : ""
        return "\(sign)\(String(format: "%.2f", v)) €"
    }
}
