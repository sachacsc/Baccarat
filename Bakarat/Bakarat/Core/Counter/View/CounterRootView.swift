//
//  CounterRootView.swift
//  Baccarat
//
//  Tab "Compteur" : liste de compteurs (Tricount-style). Tap un compteur →
//  push une vue détail (qui couvrira la tabbar via NavigationStack). Le
//  bouton ＋ en haut à droite ouvre une sheet de création.
//

import SwiftUI

struct CounterRootView: View {
    @State private var path = NavigationPath()
    @State private var showingCreate = false
    @State private var counters: [PlaceholderCounter] = PlaceholderCounter.sample

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if counters.isEmpty {
                    VStack(spacing: 14) {
                        Image(systemName: "list.bullet.clipboard")
                            .font(.system(size: 44))
                            .foregroundStyle(.tertiary)
                        Text("Pas encore de compteur")
                            .font(.headline)
                        Text("Crée-en un avec le bouton ＋ en haut à droite.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(40)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        ForEach(counters) { c in
                            NavigationLink(value: c.id) {
                                CounterRow(counter: c)
                            }
                            .listRowBackground(Color(.secondarySystemBackground))
                        }
                        .onDelete(perform: deleteCounter)
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                }
            }
            .navigationTitle("Compteurs")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingCreate = true
                    } label: {
                        Image(systemName: "plus")
                            .font(.body.weight(.semibold))
                    }
                }
            }
            .navigationDestination(for: UUID.self) { id in
                if let c = counters.first(where: { $0.id == id }) {
                    CounterDetailView(counter: c)
                }
            }
            .sheet(isPresented: $showingCreate) {
                CreateCounterSheet { name in
                    counters.insert(PlaceholderCounter(id: UUID(), name: name, lastUsedAt: .now, playerCount: 0, mancheCount: 0), at: 0)
                }
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
            }
        }
    }

    private func deleteCounter(at offsets: IndexSet) {
        counters.remove(atOffsets: offsets)
    }
}

// MARK: - Row

struct CounterRow: View {
    let counter: PlaceholderCounter

    var body: some View {
        HStack(spacing: 12) {
            Text(counter.initial)
                .font(.headline)
                .foregroundStyle(Theme.brandRed)
                .frame(width: 44, height: 44)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Theme.brandRed.opacity(0.10))
                )

            VStack(alignment: .leading, spacing: 2) {
                Text(counter.name).font(.subheadline.weight(.semibold))
                Text(counter.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 6)
    }
}

// MARK: - Create sheet

struct CreateCounterSheet: View {
    @Environment(\.dismiss) private var dismiss
    var onCreate: (String) -> Void
    @State private var name = ""
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section("Nom") {
                    TextField("Soirée chez Alex", text: $name)
                        .focused($focused)
                        .submitLabel(.go)
                        .onSubmit { commit() }
                }
                Section {
                    Text("Donne-lui un nom (soirée, week-end, voyage…). Tu pourras le retrouver depuis ta liste.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Nouveau compteur")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annuler") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Créer", action: commit)
                        .fontWeight(.semibold)
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear { focused = true }
        }
    }

    private func commit() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        onCreate(trimmed)
        dismiss()
    }
}

// MARK: - Detail placeholder

struct CounterDetailView: View {
    let counter: PlaceholderCounter

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "rectangle.stack.badge.play")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("Détail du compteur — à implémenter")
                .font(.headline)
            Text("Setup joueurs, scoreboard, validation des manches viendront ici.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 30)
            Spacer()
        }
        .padding(.top, 40)
        .navigationTitle(counter.name)
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Placeholder model (real one will live in Core/Counter/Model)

struct PlaceholderCounter: Identifiable, Hashable {
    let id: UUID
    var name: String
    var lastUsedAt: Date
    var playerCount: Int
    var mancheCount: Int

    var initial: String {
        guard let c = name.trimmingCharacters(in: .whitespaces).first else { return "?" }
        return String(c).uppercased()
    }

    var subtitle: String {
        var parts: [String] = []
        if mancheCount > 0 { parts.append("\(mancheCount) manche\(mancheCount > 1 ? "s" : "")") }
        if playerCount > 0 { parts.append("\(playerCount) joueur\(playerCount > 1 ? "s" : "")") }
        parts.append(lastUsedAt.formatted(.relative(presentation: .named)))
        return parts.joined(separator: " · ")
    }

    static let sample: [PlaceholderCounter] = []
}
