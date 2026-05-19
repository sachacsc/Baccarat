//
//  CloudSessionDetailView.swift
//  Bakarat
//
//  Détail d'une session cloud sans équivalent SwiftData local : parties
//  online que j'ai jouées, ou compteurs partagés par un autre host que j'ai
//  rejoint via share code.
//
//  Affiche : header (mode, owner, bilan perso), liste des dettes ouvertes /
//  réglées me concernant (issues de DebtsService.perGame), et la liste des
//  manches avec leur delta personnel. Tap sur une dette → toggle paid.
//

import SwiftUI

struct CloudSessionDetailView: View {
    @EnvironmentObject private var debts: DebtsService
    let session: CloudSession

    @State private var actionError: String?

    private var gameDebt: GameDebt? {
        debts.perGame.first(where: { $0.gameId == session.gameId })
    }

    private var currency: String { session.currency }

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                headerCard

                if let gd = gameDebt, !gd.payments.isEmpty {
                    debtsCard(gd)
                }

                shareInfoCard
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 24)
        }
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .alert("Action unavailable", isPresented: Binding(
            get: { actionError != nil },
            set: { if !$0 { actionError = nil } }
        )) {
            Button("OK", role: .cancel) { actionError = nil }
        } message: { Text(actionError ?? "") }
    }

    private var title: String {
        if session.mode == "online" { return "Online game" }
        if session.iAmOwner { return "Counter" }
        return session.ownerDisplay.map { "\($0)'s counter" } ?? "Shared counter"
    }

    // MARK: - Header

    private var headerCard: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: session.mode == "online" ? "gamecontroller.fill" : "list.bullet.clipboard.fill")
                    .font(.title3)
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(Theme.brandRed)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.mode == "online" ? "Online game" : "Counter")
                        .font(.subheadline.weight(.semibold))
                    if !session.iAmOwner, let owner = session.ownerDisplay {
                        Text("Host: \(owner)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if debts.settledGameIds.contains(session.gameId) {
                    Text("Paid")
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Capsule().fill(Color.secondary.opacity(0.18)))
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            VStack(spacing: 4) {
                Text("My balance")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                    .tracking(0.5)
                Text(formatMoney(session.myBalance))
                    .font(.system(size: 32, weight: .bold, design: .rounded))
                    .foregroundStyle(balanceColor(session.myBalance))
                    .monospacedDigit()
                HStack(spacing: 8) {
                    Text("\(session.numManches) round\(session.numManches > 1 ? "s" : "")")
                    Text("·")
                    Text("\(session.numParticipants) player\(session.numParticipants > 1 ? "s" : "")")
                    Text("·")
                    Text(formatPrice(session.linePrice) + "/line")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .padding(.top, 4)
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    // MARK: - Debts card

    private func debtsCard(_ gd: GameDebt) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Debts from this game")
                    .font(.headline)
                Spacer()
                let unpaid = gd.payments.filter { !$0.isSettled }.count
                if unpaid > 0 {
                    Text("\(unpaid) to settle")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Capsule().fill(Theme.systemRed.opacity(0.15)))
                        .foregroundStyle(Theme.systemRed)
                } else {
                    Text("All settled")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.green)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 8)

            VStack(spacing: 0) {
                ForEach(Array(gd.payments.enumerated()), id: \.element.id) { idx, p in
                    paymentRow(p)
                    if idx < gd.payments.count - 1 {
                        Divider().padding(.leading, 60)
                    }
                }
            }
        }
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func paymentRow(_ p: GamePayment) -> some View {
        let prof = debts.profilesById[p.otherUserId]
        return HStack(spacing: 12) {
            ProfileAvatar(name: prof?.display_name ?? "Player", avatarUrl: prof?.avatar_url, size: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(prof?.display_name ?? "Player")
                    .font(.system(size: 16, weight: .semibold))
                    .strikethrough(p.isSettled, color: .secondary)
                Text(p.direction == .iOwe ? "You owe them" : "Owes you")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(format(p.amount))
                .font(.system(size: 17, weight: .semibold, design: .rounded))
                .foregroundStyle(p.isSettled ? .secondary : (p.direction == .iOwe ? Theme.systemRed : .green))
                .monospacedDigit()
                .strikethrough(p.isSettled, color: .secondary)

            Button {
                Task { await togglePaid(p) }
            } label: {
                Image(systemName: p.isSettled ? "arrow.uturn.backward.circle" : "checkmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(p.isSettled ? Color.secondary : Color.green)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(p.isSettled ? "Undo payment" : "Mark as paid")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private func togglePaid(_ p: GamePayment) async {
        do {
            if p.isSettled {
                try await debts.markUnpaid(gameId: p.gameId, otherUserId: p.otherUserId)
            } else {
                try await debts.markPaid(gameId: p.gameId, otherUserId: p.otherUserId)
            }
        } catch {
            actionError = error.localizedDescription
        }
    }

    // MARK: - Share info card

    private var shareInfoCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "info.circle")
                Text(infoTitle)
                    .font(.subheadline.weight(.semibold))
            }
            .foregroundStyle(.secondary)
            Text(infoBody)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color(.tertiarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var infoTitle: String {
        session.iAmOwner ? "You're the host" : "You're playing"
    }
    private var infoBody: String {
        if session.iAmOwner {
            return "This game is synced to the cloud. To manage individual rounds, use the \(session.mode == "online" ? "Online" : "Counters") tab."
        }
        return "This game was shared by \(session.ownerDisplay ?? "the host"). You only see your debts here. The full round history stays with the host."
    }

    // MARK: - Helpers

    private func format(_ amount: Double) -> String {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = currency
        f.maximumFractionDigits = 2
        return f.string(from: NSNumber(value: amount)) ?? "\(amount)"
    }

    private func formatMoney(_ v: Double) -> String {
        if abs(v) < 0.005 { return format(0) }
        let sign = v > 0 ? "+" : "−"
        return "\(sign)\(format(abs(v)))"
    }

    private func formatPrice(_ v: Double) -> String {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = currency
        f.maximumFractionDigits = 2
        return f.string(from: NSNumber(value: v)) ?? "\(v)"
    }

    private func balanceColor(_ v: Double) -> Color {
        if abs(v) < 0.005 { return .secondary }
        return v > 0 ? .green : Theme.systemRed
    }
}
