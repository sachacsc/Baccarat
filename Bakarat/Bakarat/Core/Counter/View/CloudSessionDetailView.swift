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
    @StateObject private var editService = OnlineGameEditService()
    @State private var editingManche: OnlineMancheRow?
    @State private var showAdjustment = false
    @State private var pendingDelete: OnlineMancheRow?
    @State private var deleteError: String?

    private var gameDebt: GameDebt? {
        debts.perGame.first(where: { $0.gameId == session.gameId })
    }

    private var currency: String { session.currency }

    /// L'édition + ajustement online sont réservés à l'owner.
    private var canEditOnline: Bool {
        session.mode == "online" && session.iAmOwner
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                headerCard

                if let gd = gameDebt, !gd.payments.isEmpty {
                    debtsCard(gd)
                }

                if canEditOnline {
                    manchesCard
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
        .toolbar {
            if canEditOnline {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            showAdjustment = true
                        } label: {
                            Label("Ajustement", systemImage: "slider.horizontal.3")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
        }
        .alert("Action unavailable", isPresented: Binding(
            get: { actionError != nil },
            set: { if !$0 { actionError = nil } }
        )) {
            Button("OK", role: .cancel) { actionError = nil }
        } message: { Text(actionError ?? "") }
        .alert("Supprimer cette manche ?", isPresented: Binding(
            get: { pendingDelete != nil },
            set: { if !$0 { pendingDelete = nil } }
        )) {
            Button("Annuler", role: .cancel) { pendingDelete = nil }
            Button("Supprimer", role: .destructive) {
                if let m = pendingDelete {
                    Task { await deleteManche(m) }
                }
            }
        } message: {
            Text("Les soldes seront recalculés sans cette manche.")
        }
        .alert("Erreur", isPresented: Binding(
            get: { deleteError != nil },
            set: { if !$0 { deleteError = nil } }
        )) {
            Button("OK", role: .cancel) { deleteError = nil }
        } message: { Text(deleteError ?? "") }
        .task {
            if canEditOnline { await editService.load(gameId: session.gameId) }
        }
        .sheet(item: $editingManche) { m in
            EditOnlineMancheSheet(service: editService, manche: m) {
                Task { await editService.load(gameId: session.gameId) }
            }
        }
        .sheet(isPresented: $showAdjustment) {
            OnlineAdjustmentSheet(service: editService, gameId: session.gameId) {
                Task { await editService.load(gameId: session.gameId) }
            }
        }
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

    // MARK: - Manches card (owner only, online)

    private var manchesCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Manches")
                    .font(.headline)
                Spacer()
                if editService.isLoading {
                    ProgressView().controlSize(.small)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 8)

            if editService.manches.isEmpty && !editService.isLoading {
                Text("Aucune manche enregistrée.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 14)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(editService.manches.enumerated()), id: \.element.id) { idx, m in
                        mancheRow(m)
                            .contentShape(Rectangle())
                            .onTapGesture { editingManche = m }
                            .contextMenu {
                                Button("Modifier", systemImage: "pencil") {
                                    editingManche = m
                                }
                                Button("Supprimer", systemImage: "trash", role: .destructive) {
                                    pendingDelete = m
                                }
                            }
                        if idx < editService.manches.count - 1 {
                            Divider().padding(.leading, 16)
                        }
                    }
                }
                .padding(.bottom, 6)
            }
        }
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    @ViewBuilder
    private func mancheRow(_ m: OnlineMancheRow) -> some View {
        let myDelta = session.mySeatIndex.flatMap { m.perSeatDeltas[$0] } ?? 0
        HStack(spacing: 12) {
            Image(systemName: m.isAdjustment ? "slider.horizontal.3" : "rectangle.stack.fill")
                .foregroundStyle(m.isAdjustment ? Color.orange : Theme.brandRed)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(m.isAdjustment ? "Ajustement" : "Manche \(m.mancheNumber)")
                    .font(.subheadline.weight(.semibold))
                Text(m.createdAt, style: .date)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(formatMoney(myDelta))
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(balanceColor(myDelta))
                .monospacedDigit()
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func deleteManche(_ m: OnlineMancheRow) async {
        do {
            try await editService.deleteManche(mancheId: m.id)
            await editService.load(gameId: session.gameId)
        } catch {
            deleteError = error.localizedDescription
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
