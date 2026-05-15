//
//  EditBalancesSheet.swift
//  Bakarat
//
//  Sheet de manipulation manuelle des soldes des joueurs. Utile pour
//  les ajustements hors-jeu (un joueur offre N euros à un autre, écart
//  constaté à la fin de soirée, etc.).
//
//  Avertissement live si la somme des soldes ne fait plus 0.
//

import SwiftUI
import SwiftData

struct EditBalancesSheet: View {
    @Bindable var counter: Counter
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    /// Brouillons de soldes pendant l'édition (un texte par joueur).
    @State private var balances: [UUID: String] = [:]

    var body: some View {
        NavigationStack {
            List {
                if !counter.activePlayersOrdered.isEmpty {
                    Section("Joueurs actifs") {
                        ForEach(counter.activePlayersOrdered) { p in
                            row(player: p, isInactive: false)
                        }
                    }
                }
                if !counter.inactivePlayersOrdered.isEmpty {
                    Section("Joueurs inactifs") {
                        ForEach(counter.inactivePlayersOrdered) { p in
                            row(player: p, isInactive: true)
                        }
                    }
                }
                balanceCheckSection
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Modifier les soldes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annuler") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("OK", action: commit)
                        .fontWeight(.semibold)
                }
            }
            .onAppear(perform: load)
        }
    }

    @ViewBuilder
    private func row(player: CounterPlayer, isInactive: Bool) -> some View {
        HStack(spacing: 10) {
            Circle()
                .fill(Theme.brandGradient)
                .frame(width: 22, height: 22)
                .overlay(
                    Text(initialOf(player.name))
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                )
                .opacity(isInactive ? 0.4 : 1)
            Text(player.name)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(isInactive ? .secondary : .primary)
            Spacer()
            HStack(spacing: 4) {
                TextField("0",
                          text: Binding(
                              get: { balances[player.id] ?? "" },
                              set: { balances[player.id] = $0 }
                          ))
                    .keyboardType(.numbersAndPunctuation)
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 90)
                    .font(.subheadline.weight(.bold).monospacedDigit())
                Text(counter.currency)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var balanceCheckSection: some View {
        Section {
            HStack {
                Text("Somme des soldes")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(formatSigned(currentSum))
                    .font(.subheadline.weight(.bold).monospacedDigit())
                    .foregroundStyle(isBalanced ? Color.secondary : Color.orange)
            }
            if !isBalanced {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text("La somme ne fait plus 0. Tu peux quand même valider — c'est normal en cas de transfert externe (un joueur paie un autre en cash).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Compute

    private var currentSum: Double {
        var total: Double = 0
        for p in counter.players {
            total += parsedScore(for: p.id) ?? p.score
        }
        return total
    }

    private var isBalanced: Bool { abs(currentSum) < 0.001 }

    private func parsedScore(for id: UUID) -> Double? {
        guard let s = balances[id] else { return nil }
        let normalized = s
            .replacingOccurrences(of: ",", with: ".")
            .replacingOccurrences(of: "−", with: "-")
            .trimmingCharacters(in: .whitespaces)
        if normalized.isEmpty { return 0 }
        return Double(normalized)
    }

    // MARK: - Load / commit

    private func load() {
        var dict: [UUID: String] = [:]
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 2
        formatter.minimumFractionDigits = 0
        for p in counter.players {
            dict[p.id] = formatter.string(from: NSNumber(value: p.score)) ?? "\(p.score)"
        }
        balances = dict
    }

    private func commit() {
        // Calcule les deltas par seat (différence entre nouvelle saisie et solde courant).
        var deltas: [Int: Double] = [:]
        for p in counter.players {
            guard let v = parsedScore(for: p.id) else { continue }
            let delta = v - p.score
            if abs(delta) > 0.001 {
                deltas[p.seat] = delta
            }
            p.score = v
        }

        // Si au moins un solde a réellement bougé → crée un record "ajustement"
        // dans l'historique. Annulable par swipe sur la row.
        if !deltas.isEmpty {
            let adjustment = CounterManche(
                number: 0,
                dealerSeat: counter.dealerIdx,
                validatedAt: .now,
                isManualAdjustment: true
            )
            adjustment.perPlayerDeltas = deltas
            adjustment.counter = counter
            modelContext.insert(adjustment)
        }

        counter.lastUsedAt = .now
        try? modelContext.save()
        dismiss()
    }

    // MARK: - Format

    private func formatSigned(_ value: Double) -> String {
        if abs(value) < 0.001 { return "0 \(counter.currency)" }
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 2
        let n = formatter.string(from: NSNumber(value: abs(value))) ?? "\(abs(value))"
        return value > 0 ? "+\(n) \(counter.currency)" : "−\(n) \(counter.currency)"
    }

    private func initialOf(_ s: String) -> String {
        guard let c = s.trimmingCharacters(in: .whitespaces).first else { return "?" }
        return String(c).uppercased()
    }
}
