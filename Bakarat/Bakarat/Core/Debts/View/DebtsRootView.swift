//
//  DebtsRootView.swift
//  Bakarat
//
//  Depuis la fusion de l'onglet Dettes dans l'onglet "Comptes", ce fichier
//  conserve uniquement :
//   • PlayerDebtDetailView — push destination depuis la section "Dettes en
//     cours" du nouveau ledger : détail par-partie + actions (marquer payé,
//     tout marquer payé) pour un joueur donné.
//   • AvatarBubble / ProfileAvatar — composants partagés (toolbar, lignes).
//
//  L'ancienne `DebtsRootView` (page-tab) a été retirée.
//

import SwiftUI

// MARK: - Détail par joueur (push)

/// Détail d'une dette agrégée : liste des parties contribuantes, avec
/// possibilité de marquer/annuler chacune individuellement ou tout d'un coup.
struct PlayerDebtDetailView: View {
    @EnvironmentObject private var debts: DebtsService
    let aggregate: DebtAggregate
    let currency: String
    @State private var actionError: String?

    private var perGameRows: [GamePayment] {
        debts.perGame
            .flatMap { $0.payments }
            .filter { $0.otherUserId == aggregate.otherUserId }
            .sorted { lhs, rhs in
                // Open en premier, puis tri par game date desc (déduit du perGame)
                if lhs.isSettled != rhs.isSettled { return !lhs.isSettled }
                let lhsDate = debts.perGame.first(where: { $0.gameId == lhs.gameId })?.createdAt ?? .distantPast
                let rhsDate = debts.perGame.first(where: { $0.gameId == rhs.gameId })?.createdAt ?? .distantPast
                return lhsDate > rhsDate
            }
    }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text(aggregate.direction == .iOwe ? "You owe them" : "Owes you")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(format(aggregate.absAmount))
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                        .foregroundStyle(aggregate.direction == .iOwe ? Theme.systemRed : .green)
                }
                .padding(.vertical, 6)

                if aggregate.absAmount >= 0.005 {
                    Button {
                        Task { await markAllPaid() }
                    } label: {
                        HStack {
                            Image(systemName: "checkmark.circle.fill")
                            Text("Mark all as paid")
                        }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.green)
                        .frame(maxWidth: .infinity, alignment: .center)
                    }
                }
            }

            Section("Details by game") {
                ForEach(perGameRows) { p in
                    paymentRow(p)
                }
            }
        }
        .navigationTitle(aggregate.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .alert("Action unavailable", isPresented: Binding(
            get: { actionError != nil },
            set: { if !$0 { actionError = nil } })
        ) {
            Button("OK", role: .cancel) { actionError = nil }
        } message: { Text(actionError ?? "") }
    }

    private func paymentRow(_ p: GamePayment) -> some View {
        let game = debts.perGame.first(where: { $0.gameId == p.gameId })
        return HStack(spacing: 12) {
            Image(systemName: game?.mode == "online" ? "gamecontroller.fill" : "list.bullet.clipboard.fill")
                .foregroundStyle(Theme.brandRed)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(game?.mode == "online" ? "Online game" : "Counter")
                    .font(.subheadline.weight(.semibold))
                    .strikethrough(p.isSettled, color: .secondary)
                Text(game.map { $0.createdAt.formatted(.relative(presentation: .named)) } ?? "")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(format(p.amount))
                .font(.system(size: 16, weight: .semibold, design: .rounded))
                .foregroundStyle(p.isSettled ? .secondary : (p.direction == .iOwe ? Theme.systemRed : .green))
                .monospacedDigit()
                .strikethrough(p.isSettled, color: .secondary)

            Button {
                Task { await toggle(p) }
            } label: {
                Image(systemName: p.isSettled ? "arrow.uturn.backward.circle" : "checkmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(p.isSettled ? Color.secondary : Color.green)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 4)
    }

    private func markAllPaid() async {
        do { try await debts.markAllPaidForPlayer(aggregate) }
        catch { actionError = error.localizedDescription }
    }

    private func toggle(_ p: GamePayment) async {
        do {
            if p.isSettled {
                try await debts.markUnpaid(gameId: p.gameId, otherUserId: p.otherUserId)
            } else {
                try await debts.markPaid(gameId: p.gameId, otherUserId: p.otherUserId)
            }
        } catch { actionError = error.localizedDescription }
    }

    private func format(_ amount: Double) -> String {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = currency
        f.maximumFractionDigits = 2
        return f.string(from: NSNumber(value: amount)) ?? "\(amount)"
    }
}

// MARK: - Avatar bubble (initiales ou image)

/// Bulle d'avatar branchée sur le profil du user courant (toolbar).
struct AvatarBubble: View {
    let profile: UserProfile?
    var size: CGFloat = 40

    var body: some View {
        ProfileAvatar(
            name: profile?.displayName ?? "?",
            avatarUrl: profile?.avatarUrl,
            size: size
        )
    }
}

/// Avatar générique réutilisable (toolbar courant, lignes de dettes…). Cercle
/// dégradé brand + initiale en fallback, image si avatarUrl est fourni.
struct ProfileAvatar: View {
    let name: String
    let avatarUrl: String?
    var size: CGFloat = 40

    var body: some View {
        let initial = String(name.prefix(1)).uppercased()
        ZStack {
            Circle().fill(Theme.brandGradient)
            if let urlString = avatarUrl, let url = URL(string: urlString) {
                AsyncImage(url: url) { img in
                    img.resizable().scaledToFill()
                } placeholder: {
                    Text(initial)
                        .font(.system(size: size * 0.4, weight: .bold))
                        .foregroundStyle(.white)
                }
                .clipShape(Circle())
            } else {
                Text(initial)
                    .font(.system(size: size * 0.4, weight: .bold))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: size, height: size)
        .overlay(Circle().stroke(.white, lineWidth: 1.5))
        .shadow(color: Theme.brandRed.opacity(0.18), radius: 4, y: 2)
    }
}
