//
//  OnlineEditBalancesSheet.swift
//  Bakarat
//
//  Pendant online du EditBalancesSheet du compteur manuel.
//
//  Affiche la liste des joueurs avec leur solde courant (absolu) dans un
//  TextField. À la sauvegarde, calcule delta = nouvelle valeur - solde
//  courant et appelle record_online_adjustment (qui crée une manche
//  kind=adjustment + applique les transferts pairwise).
//

import SwiftUI

struct OnlineEditBalancesSheet: View {
    @ObservedObject var service: OnlineGameEditService
    let gameId: UUID
    /// Score courant par seat — la source de vérité au moment du sheet open.
    /// Pour une partie en cours, c'est `gs.players[i].score`. Pour
    /// CloudSessionDetailView, c'est l'agrégat des manches.
    let currentScores: [Int: Double]
    /// Devise affichée (généralement service.currency).
    var currency: String { service.currency }
    var onSaved: () -> Void = {}

    @Environment(\.dismiss) private var dismiss

    @State private var balances: [Int: String] = [:]
    @State private var isSaving = false
    @State private var saveError: String?

    var body: some View {
        NavigationStack {
            List {
                if !loggedParticipants.isEmpty {
                    Section("Joueurs") {
                        ForEach(loggedParticipants) { p in
                            row(p)
                        }
                    }
                }

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

                if let err = saveError {
                    Section { Text(err).foregroundStyle(.red).font(.footnote) }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Modifier les soldes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annuler") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(action: commit) {
                        if isSaving { ProgressView() }
                        else { Text("OK").fontWeight(.semibold) }
                    }
                    .disabled(!canCommit || isSaving)
                }
            }
            .onAppear(perform: load)
        }
    }

    @ViewBuilder
    private func row(_ p: OnlineGameParticipant) -> some View {
        HStack(spacing: 10) {
            ProfileAvatar(name: p.displayName, avatarUrl: p.avatarUrl, size: 28)
            Text(p.displayName)
                .font(.subheadline.weight(.semibold))
            Spacer()
            HStack(spacing: 4) {
                TextField("0",
                          text: Binding(
                              get: { balances[p.seat] ?? "" },
                              set: { balances[p.seat] = $0 }
                          ))
                    .keyboardType(.numbersAndPunctuation)
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 100)
                    .font(.subheadline.weight(.bold).monospacedDigit())
                Text(currency)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Compute

    private var loggedParticipants: [OnlineGameParticipant] {
        service.participants.filter { $0.userId != nil }
    }

    private func parsed(seat: Int) -> Double? {
        guard let s = balances[seat] else { return nil }
        let normalized = s
            .replacingOccurrences(of: ",", with: ".")
            .replacingOccurrences(of: "−", with: "-")
            .trimmingCharacters(in: .whitespaces)
        if normalized.isEmpty { return 0 }
        return Double(normalized)
    }

    private var currentSum: Double {
        loggedParticipants.reduce(0) { $0 + (parsed(seat: $1.seat) ?? currentScores[$1.seat] ?? 0) }
    }

    private var isBalanced: Bool { abs(currentSum) < 0.001 }

    private var canCommit: Bool {
        // Au moins un solde doit avoir bougé
        loggedParticipants.contains { p in
            let old = currentScores[p.seat] ?? 0
            let new = parsed(seat: p.seat) ?? old
            return abs(new - old) > 0.001
        }
    }

    // MARK: - Load / commit

    private func load() {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 2
        formatter.minimumFractionDigits = 0
        var dict: [Int: String] = [:]
        for p in service.participants {
            let v = currentScores[p.seat] ?? 0
            dict[p.seat] = formatter.string(from: NSNumber(value: v)) ?? "\(v)"
        }
        balances = dict
    }

    private func commit() {
        guard !isSaving else { return }
        isSaving = true
        saveError = nil
        Task {
            do {
                var deltas: [Int: Double] = [:]
                for p in loggedParticipants {
                    let old = currentScores[p.seat] ?? 0
                    let new = parsed(seat: p.seat) ?? old
                    let delta = new - old
                    if abs(delta) > 0.001 { deltas[p.seat] = delta }
                }
                let transfers = OnlineAdjustmentSheet.pairwiseTransfers(deltas: deltas)
                _ = try await service.recordAdjustment(
                    gameId: gameId,
                    transfers: transfers,
                    perSeatDeltas: deltas
                )
                await MainActor.run {
                    isSaving = false
                    onSaved()
                    dismiss()
                }
            } catch {
                await MainActor.run {
                    isSaving = false
                    saveError = "Erreur : \(error.localizedDescription)"
                }
            }
        }
    }

    // MARK: - Format

    private func formatSigned(_ value: Double) -> String {
        if abs(value) < 0.001 { return "0 \(currency)" }
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.minimumFractionDigits = 0
        f.maximumFractionDigits = 2
        let n = f.string(from: NSNumber(value: abs(value))) ?? "\(abs(value))"
        return value > 0 ? "+\(n) \(currency)" : "−\(n) \(currency)"
    }
}
