//
//  OnlineAdjustmentSheet.swift
//  Bakarat
//
//  Ajustement manuel des soldes pour une partie online. Calque
//  EditBalancesSheet du compteur, mais le commit passe par le RPC
//  record_online_adjustment qui crée une "manche ajustement" (kind=
//  adjustment, board_results vide) + applique les transferts pairwise.
//

import SwiftUI

struct OnlineAdjustmentSheet: View {
    @ObservedObject var service: OnlineGameEditService
    let gameId: UUID
    var onSaved: () -> Void = {}

    @Environment(\.dismiss) private var dismiss

    /// Brouillon de delta par seat (string pour permettre +/- intermédiaire).
    @State private var deltaTexts: [Int: String] = [:]
    @State private var isSaving = false
    @State private var saveError: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Ajoute un delta par joueur (positif si tu lui dois, négatif s'il te doit). La somme devrait faire 0, sauf si un joueur reçoit un transfert externe.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if !loggedParticipants.isEmpty {
                    Section("Joueurs") {
                        ForEach(loggedParticipants) { p in
                            row(participant: p)
                        }
                    }
                }

                Section {
                    HStack {
                        Text("Somme des deltas")
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
                            Text("La somme ne fait pas 0. Valider quand même peut être normal (transfert externe — un joueur règle un autre en cash).")
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
            .navigationTitle("Ajustement")
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
    private func row(participant p: OnlineGameParticipant) -> some View {
        HStack(spacing: 10) {
            ProfileAvatar(name: p.displayName, avatarUrl: p.avatarUrl, size: 28)
            Text(p.displayName)
                .font(.subheadline.weight(.semibold))
            Spacer()
            HStack(spacing: 4) {
                TextField("0",
                          text: Binding(
                              get: { deltaTexts[p.seat] ?? "" },
                              set: { deltaTexts[p.seat] = $0 }
                          ))
                    .keyboardType(.numbersAndPunctuation)
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 90)
                    .font(.subheadline.weight(.bold).monospacedDigit())
                Text(service.currency)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Data

    private var loggedParticipants: [OnlineGameParticipant] {
        service.participants.filter { $0.userId != nil }
    }

    private func parsedDelta(seat: Int) -> Double {
        guard let s = deltaTexts[seat] else { return 0 }
        let normalized = s
            .replacingOccurrences(of: ",", with: ".")
            .replacingOccurrences(of: "−", with: "-")
            .trimmingCharacters(in: .whitespaces)
        if normalized.isEmpty { return 0 }
        return Double(normalized) ?? 0
    }

    private var currentSum: Double {
        loggedParticipants.reduce(0) { $0 + parsedDelta(seat: $1.seat) }
    }

    private var isBalanced: Bool { abs(currentSum) < 0.001 }

    private var canCommit: Bool {
        // Au moins un delta non nul + 2 joueurs loggués
        loggedParticipants.count >= 2 &&
        loggedParticipants.contains(where: { abs(parsedDelta(seat: $0.seat)) > 0.001 })
    }

    private func load() {
        // Préfill à zéro
        var dict: [Int: String] = [:]
        for p in service.participants { dict[p.seat] = "" }
        deltaTexts = dict
    }

    // MARK: - Commit

    private func commit() {
        guard !isSaving else { return }
        isSaving = true
        saveError = nil
        Task {
            do {
                let deltas: [Int: Double] = Dictionary(uniqueKeysWithValues:
                    loggedParticipants.map { ($0.seat, parsedDelta(seat: $0.seat)) }
                )
                let transfers = Self.pairwiseTransfers(deltas: deltas)
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

    /// Algo Tricount-style pour transformer un vecteur de deltas signés
    /// (par seat) en transferts pairwise. Produit ≤ N-1 transferts.
    static func pairwiseTransfers(deltas: [Int: Double], epsilon: Double = 0.005) -> [AdjustmentTransfer] {
        var creditors = deltas.filter { $0.value > epsilon }
            .map { (seat: $0.key, amount: $0.value) }
        var debtors = deltas.filter { $0.value < -epsilon }
            .map { (seat: $0.key, amount: -$0.value) }
        creditors.sort { $0.amount > $1.amount }
        debtors.sort   { $0.amount > $1.amount }

        var out: [AdjustmentTransfer] = []
        var i = 0, j = 0
        while i < creditors.count && j < debtors.count {
            let amt = min(creditors[i].amount, debtors[j].amount)
            out.append(AdjustmentTransfer(
                from_seat: debtors[j].seat,
                to_seat: creditors[i].seat,
                amount: amt
            ))
            creditors[i].amount -= amt
            debtors[j].amount -= amt
            if creditors[i].amount <= epsilon { i += 1 }
            if debtors[j].amount <= epsilon { j += 1 }
        }
        return out
    }

    // MARK: - Format

    private func formatSigned(_ value: Double) -> String {
        if abs(value) < 0.001 { return "0 \(service.currency)" }
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.minimumFractionDigits = 0
        f.maximumFractionDigits = 2
        let n = f.string(from: NSNumber(value: abs(value))) ?? "\(abs(value))"
        return value > 0 ? "+\(n) \(service.currency)" : "−\(n) \(service.currency)"
    }
}
