//
//  CounterHistoryView.swift
//  Bakarat
//
//  Push destination depuis le menu "…" : "Solde & Historique". Même design
//  que la version online (BalanceHistorySheet) :
//    1. Soldes courants de tous les joueurs (inactifs greyed-out)
//    2. Manches passées avec deltas du joueur courant — touche une row pour
//       voir les deltas de tous les joueurs sur cette manche.
//  Le bouton Copier (toolbar leading) recopie l'état du compteur dans le
//  presse-papier.
//

import SwiftUI
import SwiftData
import UIKit

struct CounterHistoryView: View {
    @Bindable var counter: Counter
    @Environment(\.modelContext) private var modelContext

    @State private var justCopied = false
    @State private var showingEditBalances = false

    var body: some View {
        List {
            balancesSection
            mancheHistorySection
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Solde & Historique")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        showingEditBalances = true
                    } label: {
                        Label("Modifier les soldes", systemImage: "pencil")
                    }
                    Button {
                        copyState()
                    } label: {
                        Label(justCopied ? "Copié !" : "Copier les comptes",
                              systemImage: justCopied
                              ? "checkmark.circle.fill"
                              : "doc.on.clipboard")
                    }
                } label: {
                    Image(systemName: "line.3.horizontal")
                        .foregroundStyle(Color.primary)
                }
                .tint(.primary)
                .accessibilityLabel("Options")
            }
        }
        .sheet(isPresented: $showingEditBalances) {
            EditBalancesSheet(counter: counter)
                .presentationDetents([.large])
        }
    }

    // MARK: - Section 1 : soldes

    @ViewBuilder
    private var balancesSection: some View {
        Section {
            ForEach(allRows) { row in
                CounterPlayerRow(
                    name: row.player.name,
                    isDeemphasized: row.isInactive,
                    inlineBadge: { EmptyView() },
                    subtitle: {
                        if row.isInactive {
                            Text("Inactif")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    },
                    trailing: {
                        Text(formatMoney(row.player.score))
                            .font(.subheadline.weight(.bold).monospacedDigit())
                            .foregroundStyle(row.isInactive
                                             ? Color.secondary
                                             : scoreColor(score: row.player.score))
                    }
                )
                .listRowInsets(EdgeInsets(top: 6, leading: 0, bottom: 6, trailing: 0))
            }
        } header: {
            sectionHeader(icon: "creditcard.fill",
                          title: "Solde courant",
                          color: Theme.brandRed)
        }
    }

    private struct PlayerRow: Identifiable {
        let player: CounterPlayer
        let isInactive: Bool
        var id: UUID { player.id }
    }

    private var allRows: [PlayerRow] {
        counter.players
            .sorted { $0.score > $1.score }
            .map { PlayerRow(player: $0, isInactive: !$0.isActive) }
    }

    // MARK: - Section 2 : historique des manches

    @ViewBuilder
    private var mancheHistorySection: some View {
        Section {
            if counter.manches.isEmpty {
                Text("Aucune manche validée.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(counter.manchesOrdered) { m in
                    NavigationLink {
                        CounterMancheDetailView(manche: m, counter: counter)
                    } label: {
                        mancheRow(m)
                    }
                    .listRowInsets(EdgeInsets(top: 18, leading: 16, bottom: 18, trailing: 16))
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            deleteManche(m)
                        } label: {
                            Label("Annuler", systemImage: "arrow.uturn.backward")
                        }
                    }
                }
            }
        } header: {
            sectionHeader(icon: "clock.arrow.circlepath",
                          title: "Manches passées",
                          color: .secondary)
        } footer: {
            if !counter.manches.isEmpty {
                Text("Touche une manche pour voir les gains/pertes de tous les joueurs. Glisse à gauche pour annuler.")
                    .font(.caption)
            }
        }
    }

    @ViewBuilder
    private func mancheRow(_ m: CounterManche) -> some View {
        if m.isManualAdjustment {
            adjustmentRow(m)
        } else {
            let boards = m.boardResults.sorted { $0.board < $1.board }
            let isFullBoard = boards.contains(where: { $0.isFullBoard })
            HStack(spacing: 8) {
                winnersSummary(boards: boards, isFullBoard: isFullBoard)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                if isFullBoard {
                    Text("Full Board")
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(Color.yellow.opacity(0.25)))
                        .foregroundStyle(Self.goldDeep)
                }
                Spacer()
                Text("Manche \(m.number)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func adjustmentRow(_ m: CounterManche) -> some View {
        let deltas = m.perPlayerDeltas
        let nonZero = deltas.filter { abs($0.value) > 0.001 }
        HStack(spacing: 8) {
            adjustmentNames(deltas: nonZero)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Spacer()
            Text("Ajustement")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        }
    }

    private func adjustmentNames(deltas: [Int: Double]) -> Text {
        let sorted = deltas.sorted { abs($0.value) > abs($1.value) }
        var combined = Text("")
        for (idx, (seat, _)) in sorted.enumerated() {
            if idx > 0 {
                combined = combined + Text(", ").foregroundColor(.secondary)
            }
            let name = counter.players.first(where: { $0.seat == seat })?.name ?? "?"
            combined = combined + Text(name).foregroundColor(.primary)
        }
        return combined.font(.subheadline.weight(.semibold))
    }

    /// "Hannah×8, Antho, Hannah" — un seul Text concaténé (la virgule colle
    /// au caractère précédent, pas d'espace avant).
    private func winnersSummary(boards: [CounterBoardResult], isFullBoard: Bool) -> Text {
        let multiColor: Color = isFullBoard ? Self.goldDeep : Theme.brandRed
        var combined = Text("")
        for (idx, b) in boards.enumerated() {
            if idx > 0 {
                combined = combined + Text(", ").foregroundColor(.secondary)
            }
            if let seat = b.winnerSeat,
               let name = counter.players.first(where: { $0.seat == seat })?.name {
                combined = combined + Text(name).foregroundColor(.primary)
                if b.multi > 1 {
                    combined = combined + Text(" ×\(b.multi)").foregroundColor(multiColor)
                }
            } else {
                combined = combined + Text("—").foregroundColor(.secondary)
            }
        }
        return combined
            .font(.subheadline.weight(.semibold))
    }

    // MARK: - Section header

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

    // MARK: - Actions

    private func deleteManche(_ m: CounterManche) {
        let deltas = m.perPlayerDeltas
        for p in counter.players {
            if let d = deltas[p.seat] {
                p.score -= d
            }
        }
        modelContext.delete(m)
        counter.lastUsedAt = .now
        try? modelContext.save()
    }

    private func copyState() {
        let text = CounterStateExporter.export(counter: counter)
        UIPasteboard.general.string = text
        withAnimation { justCopied = true }
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            await MainActor.run { justCopied = false }
        }
    }

    // MARK: - Format

    private func formatMoney(_ v: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 2
        let n = formatter.string(from: NSNumber(value: abs(v))) ?? "\(abs(v))"
        if abs(v) < 0.001 { return "0 \(counter.currency)" }
        return v > 0 ? "+\(n) \(counter.currency)" : "−\(n) \(counter.currency)"
    }

    private func initialOf(_ s: String) -> String {
        guard let c = s.trimmingCharacters(in: .whitespaces).first else { return "?" }
        return String(c).uppercased()
    }

    fileprivate static let goldDeep = Color(red: 0.62, green: 0.46, blue: 0.05)
}

// MARK: - Detail d'une manche (deltas de tous les joueurs)

struct CounterMancheDetailView: View {
    @Bindable var manche: CounterManche
    @Bindable var counter: Counter

    @State private var showingEdit = false

    var body: some View {
        List {
            deltasSection
        }
        .listStyle(.insetGrouped)
        .navigationTitle(manche.isManualAdjustment ? "Ajustement" : "Manche \(manche.number)")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !manche.isManualAdjustment {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Modifier") {
                        showingEdit = true
                    }
                    .tint(Theme.brandRed)
                }
            }
        }
        .sheet(isPresented: $showingEdit) {
            EditMancheSheet(counter: counter, manche: manche)
                .presentationDetents([.large])
        }
    }

    // MARK: - Gains / pertes

    @ViewBuilder
    private var deltasSection: some View {
        Section {
            ForEach(rankedRows) { row in
                deltaRow(row)
                    .listRowInsets(EdgeInsets(top: 6, leading: 0, bottom: 6, trailing: 0))
            }
        } header: {
            Text("Gains / pertes")
        } footer: {
            if !manche.isManualAdjustment {
                Text("Donneur : \(nameFor(seat: manche.dealerSeat) ?? "Seat \(manche.dealerSeat)")")
                    .font(.caption)
            }
        }
    }

    @ViewBuilder
    private func deltaRow(_ row: DeltaRow) -> some View {
        CounterPlayerRow(
            name: row.name,
            inlineBadge: {
                if !row.boardsWon.isEmpty {
                    boardsPill(row: row)
                }
            },
            subtitle: {
                if !row.splitBoardsWon.isEmpty {
                    Text(splitSubtitle(row: row))
                        .font(.caption2)
                        .foregroundStyle(CounterHistoryView.goldDeep)
                }
            },
            trailing: {
                Text(formatMoney(row.delta))
                    .font(.subheadline.weight(.bold).monospacedDigit())
                    .foregroundStyle(scoreColor(score: row.delta))
            }
        )
    }

    @ViewBuilder
    private func boardsPill(row: DeltaRow) -> some View {
        let label = row.boardsWon.map { idx -> String in
            let m = row.boardMultis[idx] ?? 1
            return m > 1 ? "B\(idx + 1)×\(m)" : "B\(idx + 1)"
        }.joined(separator: " ")
        let textColor: Color = row.isFullBoardWinner ? CounterHistoryView.goldDeep : Theme.brandRed
        let bgColor: Color = row.isFullBoardWinner
            ? Color(red: 0.96, green: 0.84, blue: 0.40).opacity(0.35)
            : Theme.brandRed.opacity(0.12)
        Text(label)
            .font(.caption2.weight(.bold))
            .foregroundStyle(textColor)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(Capsule().fill(bgColor))
    }

    private struct DeltaRow: Identifiable {
        let seat: Int
        let name: String
        let delta: Double
        let boardsWon: [Int]
        let boardMultis: [Int: Int]
        let isFullBoardWinner: Bool
        /// Boards où ce joueur a gagné après un tie-break (split).
        let splitBoardsWon: [Int]
        /// Pour chaque split board gagné : noms des autres splitters.
        let splitPartnersByBoard: [Int: [String]]
        var id: Int { seat }
    }

    private var rankedRows: [DeltaRow] {
        let deltas = manche.perPlayerDeltas
        let results = manche.boardResults

        var wonBy: [Int: [Int]] = [:]
        var splitWonBy: [Int: [Int]] = [:]
        var splitPartnersByBoardPerSeat: [Int: [Int: [String]]] = [:]
        var multiBy: [Int: Int] = [:]
        for b in results {
            if let s = b.winnerSeat {
                wonBy[s, default: []].append(b.board)
                multiBy[b.board] = b.multi
                if let splitters = b.splitterSeats, !splitters.isEmpty {
                    splitWonBy[s, default: []].append(b.board)
                    let partnerNames = splitters
                        .filter { $0 != s }
                        .compactMap { nameFor(seat: $0) }
                    splitPartnersByBoardPerSeat[s, default: [:]][b.board] = partnerNames
                }
            }
        }
        var fbWinner: Int? = nil
        if results.contains(where: { $0.isFullBoard }) {
            fbWinner = results.first?.winnerSeat
        }

        let allSeats = Set(deltas.keys).union(counter.players.map { $0.seat })
        return allSeats
            .compactMap { seat -> DeltaRow? in
                guard let name = nameFor(seat: seat) else { return nil }
                return DeltaRow(
                    seat: seat,
                    name: name,
                    delta: deltas[seat] ?? 0,
                    boardsWon: wonBy[seat]?.sorted() ?? [],
                    boardMultis: multiBy,
                    isFullBoardWinner: fbWinner == seat,
                    splitBoardsWon: splitWonBy[seat]?.sorted() ?? [],
                    splitPartnersByBoard: splitPartnersByBoardPerSeat[seat] ?? [:]
                )
            }
            .sorted { $0.delta > $1.delta }
    }

    private func nameFor(seat: Int) -> String? {
        counter.players.first(where: { $0.seat == seat })?.name
    }

    /// Construit la ligne "Split sur B1 avec Hugo · B3 avec Lola, Antho".
    /// Une seule ligne, segments séparés par " · " si plusieurs boards.
    private func splitSubtitle(row: DeltaRow) -> String {
        row.splitBoardsWon.map { boardIdx -> String in
            let partners = row.splitPartnersByBoard[boardIdx] ?? []
            if partners.isEmpty {
                return "Split sur B\(boardIdx + 1)"
            }
            return "Split sur B\(boardIdx + 1) avec \(partners.joined(separator: ", "))"
        }.joined(separator: " · ")
    }

    private func formatMoney(_ v: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 2
        let n = formatter.string(from: NSNumber(value: abs(v))) ?? "\(abs(v))"
        if abs(v) < 0.001 { return "0 \(counter.currency)" }
        return v > 0 ? "+\(n) \(counter.currency)" : "−\(n) \(counter.currency)"
    }

    private func initialOf(_ s: String) -> String {
        guard let c = s.trimmingCharacters(in: .whitespaces).first else { return "?" }
        return String(c).uppercased()
    }
}
