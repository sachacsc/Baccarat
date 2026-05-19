//
//  ShareCounterSheet.swift
//  Bakarat
//
//  Sheet hôte : affiche le share_code du compteur + liste live des seats avec
//  leur état (libre / revendiqué). Realtime sur game_participants → la liste
//  se met à jour automatiquement quand quelqu'un revendique son siège.
//

import SwiftUI
import Supabase
import Realtime
import UIKit

/// Wrapper SwiftUI autour de UIActivityViewController pour le bouton Partager.
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

struct ShareCounterSheet: View {
    @EnvironmentObject private var auth: AuthService
    @Environment(\.dismiss) private var dismiss

    /// game_id du compteur côté Supabase. La sheet ne s'ouvre que si on l'a
    /// (i.e. au moins une manche a été enregistrée).
    let cloudGameId: UUID

    @State private var shareCode: String?
    @State private var seats: [SharedGameSeat] = []
    @State private var loadError: String?
    @State private var isLoading = false
    @State private var realtimeChannel: RealtimeChannelV2?
    @State private var subscribeTask: Task<Void, Never>?
    @State private var claimError: String?
    @State private var pendingClaimSeatIndex: Int?

    private var iHaveASeat: Bool {
        guard let uid = auth.userId else { return false }
        return seats.contains(where: { $0.claimedByUserId == uid })
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Share")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Close") { dismiss() }
                            .tint(Theme.brandRed)
                    }
                }
        }
        .task { await bootstrap() }
        .onDisappear { Task { await teardownRealtime() } }
    }

    @ViewBuilder
    private var content: some View {
        if isLoading && shareCode == nil {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let err = loadError {
            ContentUnavailableView {
                Label("Sharing unavailable", systemImage: "exclamationmark.triangle")
            } description: {
                Text(err)
            } actions: {
                Button("Retry") { Task { await bootstrap() } }
            }
        } else {
            ScrollView {
                VStack(spacing: 16) {
                    codeCard
                    if !iHaveASeat && !seats.isEmpty {
                        ownerClaimBanner
                    }
                    seatsCard
                    helperText
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 24)
            }
            .alert("Action impossible", isPresented: Binding(
                get: { claimError != nil },
                set: { if !$0 { claimError = nil } }
            )) {
                Button("OK", role: .cancel) { claimError = nil }
            } message: { Text(claimError ?? "") }
        }
    }

    // MARK: - Owner claim banner

    private var ownerClaimBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: "person.fill.questionmark")
                .font(.title3)
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .background(Theme.brandRed)
                .clipShape(Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text("Which seat are you?")
                    .font(.subheadline.weight(.semibold))
                Text("Tap \"That's me\" on your seat so your rounds count towards your debts.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(12)
        .background(Color(.tertiarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    // MARK: - Code card (URL deep link)

    private var shareURL: URL? {
        guard let code = shareCode else { return nil }
        return CounterShareService.joinURL(forCode: code)
    }

    @State private var showShareSheet = false

    private var codeCard: some View {
        VStack(spacing: 10) {
            Text("Invitation link")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .tracking(0.5)

            Text(shareURL?.absoluteString ?? "—")
                .font(.system(size: 14, weight: .medium, design: .monospaced))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 8)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity)
                .background(Color(.tertiarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

            HStack(spacing: 10) {
                Button {
                    guard let url = shareURL else { return }
                    UIPasteboard.general.string = url.absoluteString
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "doc.on.doc")
                        Text("Copy")
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.brandRed)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 11)
                    .background(Theme.brandRed.opacity(0.10))
                    .clipShape(Capsule())
                }

                Button {
                    showShareSheet = true
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "square.and.arrow.up")
                        Text("Share")
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 11)
                    .background(Theme.brandGradient)
                    .clipShape(Capsule())
                }
                .disabled(shareURL == nil)
            }
            .buttonStyle(.plain)
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .sheet(isPresented: $showShareSheet) {
            if let url = shareURL {
                ShareSheet(items: [url])
            }
        }
    }

    // MARK: - Seats card

    private var seatsCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Players")
                    .font(.headline)
                Spacer()
                let claimed = seats.filter { $0.isClaimed }.count
                Text("\(claimed)/\(seats.count) claimed")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 10)

            VStack(spacing: 0) {
                ForEach(Array(seats.enumerated()), id: \.element.id) { idx, s in
                    seatRow(s)
                    if idx < seats.count - 1 {
                        Divider().padding(.leading, 60)
                    }
                }
            }
        }
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func seatRow(_ s: SharedGameSeat) -> some View {
        let isMine = s.claimedByUserId != nil && s.claimedByUserId == auth.userId
        // RPC `claim_seat` gère le seat-move : si je clique "C'est moi" sur un
        // seat libre alors que j'ai déjà un siège, l'ancien est libéré et le
        // nouveau pris en une transaction.
        let canClaim = !s.isClaimed
        return HStack(spacing: 12) {
            ProfileAvatar(
                name: s.claimedByDisplay ?? s.guestName ?? "?",
                avatarUrl: s.claimedByAvatar,
                size: 36
            )
            .opacity(s.isClaimed ? 1.0 : 0.55)

            VStack(alignment: .leading, spacing: 2) {
                Text(s.guestName ?? "Seat \(s.seatIndex + 1)")
                    .font(.system(size: 16, weight: .semibold))
                if isMine {
                    Text("You")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.brandRed)
                } else if let claimed = s.claimedByDisplay {
                    Text(claimed == s.guestName ? "Claimed" : "Claimed by \(claimed)")
                        .font(.caption)
                        .foregroundStyle(.green)
                } else {
                    Text("Waiting")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()

            if canClaim {
                Button {
                    Task { await claimSeat(seatIndex: s.seatIndex) }
                } label: {
                    Text(pendingClaimSeatIndex == s.seatIndex ? "…" : "That's me")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(Theme.brandGradient)
                        .clipShape(Capsule())
                }
                .disabled(pendingClaimSeatIndex != nil)
            } else {
                Image(systemName: s.isClaimed ? "checkmark.circle.fill" : "circle.dashed")
                    .font(.title3)
                    .foregroundStyle(s.isClaimed ? .green : .secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private func claimSeat(seatIndex: Int) async {
        guard let code = shareCode else { return }
        pendingClaimSeatIndex = seatIndex
        defer { pendingClaimSeatIndex = nil }
        do {
            _ = try await CounterShareService.claim(shareCode: code, seatIndex: seatIndex)
            await reloadSeats()
        } catch {
            claimError = error.localizedDescription
        }
    }

    private var helperText: some View {
        Text("Share this link with your players. Tapping it opens Bakarat (or App Store if not installed) and brings them straight to the seat picker. Once claimed, they show up in your debts instead of being counted as guests.")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4)
    }

    // MARK: - Bootstrap & realtime

    private func bootstrap() async {
        isLoading = true
        loadError = nil
        defer { isLoading = false }

        do {
            // 1) Génère (ou récupère) le code.
            let code = try await CounterShareService.getOrCreateShareCode(gameId: cloudGameId)
            shareCode = code
            // 2) Liste initiale des seats.
            seats = try await CounterShareService.lookup(shareCode: code)
            // 3) Realtime → reload sur tout changement de game_participants.
            await setupRealtime()
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func reloadSeats() async {
        guard let code = shareCode else { return }
        do { seats = try await CounterShareService.lookup(shareCode: code) }
        catch { /* silencieux, on garde l'état */ }
    }

    private func setupRealtime() async {
        await teardownRealtime()
        let client = SupabaseClientProvider.shared
        let ch = client.realtimeV2.channel("share-\(cloudGameId.uuidString.prefix(8))")
        realtimeChannel = ch
        let stream = ch.postgresChange(AnyAction.self, schema: "public", table: "game_participants")
        do { try await ch.subscribeWithError() }
        catch { return }
        subscribeTask = Task {
            for await _ in stream {
                await reloadSeats()
            }
        }
    }

    private func teardownRealtime() async {
        subscribeTask?.cancel()
        subscribeTask = nil
        if let ch = realtimeChannel { await ch.unsubscribe() }
        realtimeChannel = nil
    }
}
