//
//  CounterDetailView.swift
//  Bakarat
//
//  Détail d'un compteur. Layout en deux cards :
//    1. Joueurs · soldes (avec indicateur "au service" pour le dealer)
//    2. Manche en cours (3 boards + picker multi + valider)
//
//  Le menu "…" en haut à droite donne accès à l'historique, à l'édition des
//  joueurs, au renommage, à la remise à zéro, et à la suppression.
//

import SwiftUI
import SwiftData

struct CounterDetailView: View {
    @Bindable var counter: Counter
    @EnvironmentObject private var auth: AuthService
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var showingDeleteConfirm = false
    @State private var showingSettings = false
    @State private var showingShare = false
    @State private var noCloudGameAlert = false

    // Anchor pour ScrollViewReader → scroll-to-top après validation manche.
    private static let topAnchor = "counter-top"

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 16) {
                    Color.clear
                        .frame(height: 0)
                        .id(Self.topAnchor)
                    PlayersCard(counter: counter)
                    CurrentMancheCard(counter: counter) { manche in
                        // Scroll en haut + sync cloud (fire-and-forget).
                        withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) {
                            proxy.scrollTo(Self.topAnchor, anchor: .top)
                        }
                        cloudSync(manche: manche)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 24)
            }
        }
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .navigationTitle(counter.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                menu
            }
        }
        .alert("Delete this counter?",
               isPresented: $showingDeleteConfirm) {
            Button("Delete", role: .destructive) {
                modelContext.delete(counter)
                try? modelContext.save()
                dismiss()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("All rounds and balances will be removed. This cannot be undone.")
        }
        .sheet(isPresented: $showingSettings) {
            CounterSettingsSheet(counter: counter)
                .presentationDetents([.large])
        }
        .sheet(isPresented: $showingShare) {
            if let gid = counter.cloudGameId {
                ShareCounterSheet(cloudGameId: gid)
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
            }
        }
        .alert("Sharing unavailable", isPresented: $noCloudGameAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("Play at least one round to sync the counter to the cloud. Then you'll be able to generate a share link.")
        }
        .task {
            // Rattrape les manches jouées offline si on a maintenant du réseau.
            guard let uid = auth.userId else { return }
            await CounterCloudSync.resyncPending(
                counter: counter,
                authUserId: uid,
                authDisplayName: auth.profile?.displayName,
                modelContext: modelContext
            )
        }
    }

    // MARK: - Cloud sync

    /// Pousse la manche vers Supabase. Fire-and-forget : on logue les erreurs
    /// en debug mais on ne bloque pas l'UI. Le `counter.cloudGameId` est mis
    /// à jour par le service à la première sync réussie.
    private func cloudSync(manche: CounterManche) {
        guard let uid = auth.userId else { return }
        let display = auth.profile?.displayName
        Task {
            do {
                _ = try await CounterCloudSync.pushManche(
                    counter: counter,
                    manche: manche,
                    authUserId: uid,
                    authDisplayName: display,
                    modelContext: modelContext
                )
            } catch {
                #if DEBUG
                print("[CounterCloudSync] pushManche failed: \(error)")
                #endif
            }
        }
    }

    // MARK: - Toolbar : menu

    @ViewBuilder
    private var menu: some View {
        Menu {
            // Items non-destructives : icônes noires comme le texte.
            Group {
                Button {
                    if counter.cloudGameId != nil {
                        showingShare = true
                    } else {
                        noCloudGameAlert = true
                    }
                } label: {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
                Button {
                    showingSettings = true
                } label: {
                    Label("Settings", systemImage: "gear")
                }
                NavigationLink {
                    CounterHistoryView(counter: counter)
                } label: {
                    Label("History", systemImage: "clock.arrow.circlepath")
                }
            }
            .tint(.primary)

            Divider()

            // Destructive : laissé sans tint → iOS rend automatiquement texte
            // ET icône en rouge système (role .destructive).
            Button(role: .destructive) {
                showingDeleteConfirm = true
            } label: {
                Label("Delete", systemImage: "trash")
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.body.weight(.medium))
                .foregroundStyle(Theme.brandRed)
        }
    }
}

// MARK: - Players card

private struct PlayersCard: View {
    @Bindable var counter: Counter

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Players")
                .font(.title3.weight(.bold))
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 12)

            VStack(spacing: 0) {
                let active = counter.activePlayersOrdered
                ForEach(Array(active.enumerated()), id: \.element.id) { idx, p in
                    CounterPlayerRow(
                        name: p.name,
                        inlineBadge: {
                            if p.seat == counter.dealerIdx {
                                Text("Dealer")
                                    .font(.caption2.weight(.bold))
                                    .padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(Capsule().fill(Theme.brandRed.opacity(0.14)))
                                    .foregroundStyle(Theme.brandRed)
                            }
                        },
                        subtitle: { EmptyView() },
                        trailing: {
                            Text(scoreLabel(score: p.score, currency: counter.currency))
                                .font(.subheadline.weight(.bold))
                                .monospacedDigit()
                                .foregroundStyle(scoreColor(score: p.score))
                        }
                    )
                    if idx < active.count - 1 {
                        Divider().padding(.leading, 56)
                    }
                }
                if active.isEmpty {
                    Text("No active players. Add some from the “…” menu.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16).padding(.vertical, 10)
                }
            }
            .padding(.bottom, 12)
        }
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
    }

}

// MARK: - Score helpers (partagés)

func scoreLabel(score: Double, currency: String) -> String {
    let formatter = NumberFormatter()
    formatter.numberStyle = .decimal
    formatter.minimumFractionDigits = 0
    formatter.maximumFractionDigits = 2
    let n = formatter.string(from: NSNumber(value: abs(score))) ?? "\(abs(score))"
    if score > 0 { return "+\(n) \(currency)" }
    if score < 0 { return "−\(n) \(currency)" }
    return "0 \(currency)"
}

func scoreColor(score: Double) -> Color {
    if score > 0 { return .green }
    if score < 0 { return .red }
    return .secondary
}
