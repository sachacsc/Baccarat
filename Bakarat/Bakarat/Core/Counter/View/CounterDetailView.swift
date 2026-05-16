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
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var showingDeleteConfirm = false
    @State private var showingSettings = false

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                PlayersCard(counter: counter)
                CurrentMancheCard(counter: counter)
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 24)
        }
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .navigationTitle(counter.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                menu
            }
        }
        .alert("Supprimer ce compteur ?",
               isPresented: $showingDeleteConfirm) {
            Button("Supprimer", role: .destructive) {
                modelContext.delete(counter)
                try? modelContext.save()
                dismiss()
            }
            Button("Annuler", role: .cancel) { }
        } message: {
            Text("L'historique sera également supprimé. Cette action est irréversible.")
        }
        .sheet(isPresented: $showingSettings) {
            CounterSettingsSheet(counter: counter)
                .presentationDetents([.large])
        }
    }

    // MARK: - Toolbar : menu

    @ViewBuilder
    private var menu: some View {
        Menu {
            // Items non-destructives : icônes noires comme le texte.
            Group {
                Button {
                    showingSettings = true
                } label: {
                    Label("Réglages du compteur", systemImage: "gear")
                }
                NavigationLink {
                    CounterHistoryView(counter: counter)
                } label: {
                    Label("Solde & Historique", systemImage: "clock.arrow.circlepath")
                }
            }
            .tint(.primary)

            Divider()

            // Destructive : laissé sans tint → iOS rend automatiquement texte
            // ET icône en rouge système (role .destructive).
            Button(role: .destructive) {
                showingDeleteConfirm = true
            } label: {
                Label("Supprimer le compteur", systemImage: "trash")
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
            Text("Joueurs")
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
                                Text("Donne")
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
                    Text("Aucun joueur actif. Ajoute-en via le menu “…”.")
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
