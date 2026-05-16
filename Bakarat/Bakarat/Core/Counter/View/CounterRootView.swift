//
//  CounterRootView.swift
//  Bakarat
//
//  Tab "Compteur" : liste des compteurs SwiftData (Tricount-style). Tap →
//  push CounterDetailView via NavigationStack. Le bouton ＋ ouvre la sheet
//  de création (nom + prix de la ligne + joueurs).
//

import SwiftUI
import SwiftData

struct CounterRootView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Counter.lastUsedAt, order: .reverse) private var counters: [Counter]

    @State private var path = NavigationPath()
    @State private var showingCreate = false

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if counters.isEmpty {
                    emptyState
                } else {
                    listView
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
                    .tint(Theme.brandRed)
                }
            }
            .navigationDestination(for: UUID.self) { id in
                if let c = counters.first(where: { $0.id == id }) {
                    CounterDetailView(counter: c)
                }
            }
            .sheet(isPresented: $showingCreate) {
                CreateCounterSheet()
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
            }
        }
    }

    // MARK: - Empty / list

    @ViewBuilder
    private var emptyState: some View {
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
    }

    @ViewBuilder
    private var listView: some View {
        List {
            ForEach(counters) { c in
                NavigationLink(value: c.id) {
                    CounterRow(counter: c)
                }
            }
            .onDelete(perform: deleteCounter)
        }
        .listStyle(.insetGrouped)
    }

    // MARK: - Mutations

    private func deleteCounter(at offsets: IndexSet) {
        for idx in offsets {
            modelContext.delete(counters[idx])
        }
        try? modelContext.save()
    }
}

// MARK: - Row

struct CounterRow: View {
    let counter: Counter

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
                Text(counter.name)
                    .font(.subheadline.weight(.semibold))
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

/// Brouillon de joueur dans le formulaire de création. id stable nécessaire
/// pour le drag-to-reorder de SwiftUI (sinon les rows se mélangent).
struct PlayerDraft: Identifiable, Hashable {
    let id: UUID
    var name: String
    /// Score initial — utilisé quand on importe un état via collage. 0 sinon.
    var initialScore: Double

    init(id: UUID = UUID(), name: String = "", initialScore: Double = 0) {
        self.id = id
        self.name = name
        self.initialScore = initialScore
    }
}

struct CreateCounterSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    @State private var name = ""
    @State private var linePriceText = "2,5"
    /// Actifs : toujours au moins 1 ligne vide en fin (auto-reveal).
    @State private var actives: [PlayerDraft] = [PlayerDraft()]
    @FocusState private var focusedField: Field?
    @FocusState private var priceFieldFocused: Bool

    enum Field: Hashable {
        case name, player(UUID)
    }

    // Prix : bornes et pas, alignés sur le lobby online.
    private static let minPrice: Double = 0.5
    private static let maxPrice: Double = 50
    private static let priceStep: Double = 0.5

    var body: some View {
        NavigationStack {
            List {
                Section{
                    TextField("Nom du compteur", text: $name)
                        .focused($focusedField, equals: .name)
                        .submitLabel(.next)
                    
                    HStack {
                        Text("Prix de la ligne")
                        Spacer()
                        HStack(spacing: 6) {
                            TextField("2,5", text: $linePriceText)
                                .keyboardType(.decimalPad)
                                .multilineTextAlignment(.center)
                                .font(.system(size: 17, weight: .semibold))
                                .focused($priceFieldFocused)
                                .frame(width: 64)
                                .padding(.vertical, 8)
                                .background(Color(.systemGray6))
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                .onChange(of: linePriceText) { _, new in
                                    sanitizePriceText(new)
                                }
                                .onChange(of: priceFieldFocused) { _, focused in
                                    if !focused { syncPriceTextFromParsed() }
                                }
                            Text("€")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Section {
                    ForEach($actives) { $p in
                        HStack {
                            Text("\(playerIndex(p) + 1)")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .frame(width: 22, alignment: .leading)
                                .monospacedDigit()
                            TextField("Prénom", text: $p.name)
                                .focused($focusedField, equals: .player(p.id))
                                .submitLabel(.next)
                                .onSubmit { focusNext(after: p.id) }
                                .onChange(of: p.name) { _, _ in
                                    ensureTrailingEmpty()
                                }
                        }
                    }
                    .onMove(perform: moveActives)
                    .onDelete(perform: deleteActive)
                } header: {
                    Text("Joueurs")
                } footer: {
                    Text("Glisse pour réorganiser. Une nouvelle ligne s'ajoute automatiquement quand tu remplis la dernière.")
                }
            }
            .listStyle(.insetGrouped)
            .environment(\.editMode, .constant(.active))
            .navigationTitle("Nouveau compteur")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annuler") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Créer", action: commit)
                        .fontWeight(.semibold)
                        .disabled(!canCommit)
                }
            }
            .safeAreaInset(edge: .bottom) {
                if priceFieldFocused {
                    priceKeyboardBar
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.easeInOut(duration: 0.2), value: priceFieldFocused)
            .onAppear { focusedField = .name }
        }
    }

    // MARK: - Price keyboard bar (style lobby online)

    @ViewBuilder
    private var priceKeyboardBar: some View {
        let cur = parsedLinePrice ?? 2.5
        let canDec = cur > Self.minPrice
        let canInc = cur < Self.maxPrice
        HStack(spacing: 8) {
            Button {
                let new = min(Self.maxPrice, cur + Self.priceStep)
                linePriceText = formatPriceForField(new)
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(canInc ? .primary : .secondary.opacity(0.4))
                    .frame(width: 36, height: 36)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(!canInc)

            Button {
                let new = max(Self.minPrice, cur - Self.priceStep)
                linePriceText = formatPriceForField(new)
            } label: {
                Image(systemName: "minus")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(canDec ? .primary : .secondary.opacity(0.4))
                    .frame(width: 36, height: 36)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(!canDec)

            Spacer()

            Button {
                syncPriceTextFromParsed()
                priceFieldFocused = false
            } label: {
                Image(systemName: "checkmark")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(Theme.brandRed)
                    .frame(width: 36, height: 36)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .modifier(LiquidGlassPill())
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    private func sanitizePriceText(_ raw: String) {
        var seenSep = false
        var filtered = ""
        for c in raw {
            if c.isNumber {
                filtered.append(c)
            } else if (c == "," || c == ".") && !seenSep {
                seenSep = true
                filtered.append(",")
            }
        }
        if filtered != raw { linePriceText = filtered }
    }

    private func syncPriceTextFromParsed() {
        if let v = parsedLinePrice {
            linePriceText = formatPriceForField(v)
        } else {
            linePriceText = "2,5"
        }
    }

    private func formatPriceForField(_ p: Double) -> String {
        if p.truncatingRemainder(dividingBy: 1) == 0 {
            return String(format: "%.0f", p)
        }
        return String(format: "%.1f", p).replacingOccurrences(of: ".", with: ",")
    }

    // MARK: - Players list management

    private func playerIndex(_ p: PlayerDraft) -> Int {
        actives.firstIndex(where: { $0.id == p.id }) ?? 0
    }

    private func ensureTrailingEmpty() {
        while actives.count > 1,
              actives[actives.count - 1].name.trimmingCharacters(in: .whitespaces).isEmpty,
              actives[actives.count - 2].name.trimmingCharacters(in: .whitespaces).isEmpty {
            actives.removeLast()
        }
        if actives.isEmpty || !actives.last!.name.trimmingCharacters(in: .whitespaces).isEmpty {
            actives.append(PlayerDraft())
        }
    }

    private func moveActives(from source: IndexSet, to destination: Int) {
        actives.move(fromOffsets: source, toOffset: destination)
        ensureTrailingEmpty()
    }

    private func deleteActive(at offsets: IndexSet) {
        actives.remove(atOffsets: offsets)
        ensureTrailingEmpty()
    }

    private func focusNext(after id: UUID) {
        guard let idx = actives.firstIndex(where: { $0.id == id }) else { return }
        if idx < actives.count - 1 {
            focusedField = .player(actives[idx + 1].id)
        } else {
            ensureTrailingEmpty()
            if let last = actives.last {
                focusedField = .player(last.id)
            }
        }
    }

    // MARK: - Commit

    private var canCommit: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty &&
        validNamesCount >= 2 &&
        parsedLinePrice != nil
    }

    private var validNamesCount: Int {
        actives
            .map { $0.name.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .count
    }

    private var parsedLinePrice: Double? {
        let normalized = linePriceText.replacingOccurrences(of: ",", with: ".")
        guard let value = Double(normalized), value > 0 else { return nil }
        return value
    }

    private func commit() {
        guard canCommit, let price = parsedLinePrice else { return }
        let cleanName = name.trimmingCharacters(in: .whitespaces)
        let cleanActives = actives.filter {
            !$0.name.trimmingCharacters(in: .whitespaces).isEmpty
        }

        let counter = Counter(name: cleanName,
                              linePrice: price,
                              currency: "€",
                              dealerIdx: 0,
                              configured: true)
        modelContext.insert(counter)

        for (i, p) in cleanActives.enumerated() {
            let player = CounterPlayer(seat: i,
                                       name: p.name.trimmingCharacters(in: .whitespaces),
                                       score: 0,
                                       isActive: true)
            player.counter = counter
            modelContext.insert(player)
        }

        try? modelContext.save()
        dismiss()
    }
}
