//
//  CounterSettingsSheet.swift
//  Bakarat
//
//  Page Réglages d'un compteur : nom + prix + monnaie + joueurs (actifs +
//  inactifs avec Sortir / Réintégrer). Même layout que la sheet de création.
//  Réorganisation par drag (handles iOS) OU par boutons flèches ↑↓.
//

import SwiftUI
import SwiftData

struct CounterSettingsSheet: View {
    @Bindable var counter: Counter
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var name: String = ""
    @State private var linePriceText: String = ""

    @State private var actives: [Draft] = []
    @State private var inactives: [Draft] = []

    @FocusState private var focusedField: Field?
    @FocusState private var priceFieldFocused: Bool

    enum Field: Hashable {
        case name, player(UUID)
    }

    // Prix : bornes alignées sur la sheet de création + le lobby online.
    private static let minPrice: Double = 0.5
    private static let maxPrice: Double = 50
    private static let priceStep: Double = 0.5

    struct Draft: Identifiable, Hashable {
        let id: UUID
        let existingPlayerId: UUID?
        var name: String
        var score: Double
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
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

                activeSection
                if !inactives.isEmpty {
                    inactiveSection
                }
            }
            .listStyle(.insetGrouped)
            .environment(\.editMode, .constant(.active))
            .navigationTitle("Réglages")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annuler") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("OK", action: commit)
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
            .onAppear(perform: load)
        }
    }

    // MARK: - Price keyboard bar (style identique à CreateCounterSheet)

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

    // MARK: - Active section

    @ViewBuilder
    private var activeSection: some View {
        Section {
            ForEach(Array($actives.enumerated()), id: \.element.id) { idx, $d in
                HStack(spacing: 6) {
                    arrowButtons(index: idx)

                    TextField("Prénom", text: $d.name)
                        .focused($focusedField, equals: .player(d.id))
                        .submitLabel(.next)
                        .onSubmit { focusNext(after: d.id) }
                        .onChange(of: d.name) { _, _ in
                            ensureTrailingEmpty()
                        }

                    if shouldShowExitButton(d) {
                        Button("Sortir") {
                            excludePlayer(d)
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.orange)
                        .font(.subheadline.weight(.semibold))
                    }
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button(role: .destructive) {
                        deleteActiveDraft(d)
                    } label: {
                        Label("Supprimer", systemImage: "trash")
                    }
                }
            }
            .onMove(perform: moveActives)
        } header: {
            Text("Joueurs actifs")
        } footer: {
            Text("Réorganise avec les flèches ↑↓ ou en draggant la poignée à droite. Une ligne vide reste disponible — tape-la pour ajouter un joueur.")
        }
    }

    @ViewBuilder
    private func arrowButtons(index: Int) -> some View {
        VStack(spacing: 0) {
            Button {
                moveActiveUp(at: index)
            } label: {
                Image(systemName: "chevron.up")
                    .font(.system(size: 10, weight: .bold))
                    .frame(width: 22, height: 14)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .foregroundStyle(index == 0 ? .tertiary : .secondary)
            .disabled(index == 0)

            Button {
                moveActiveDown(at: index)
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .bold))
                    .frame(width: 22, height: 14)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .foregroundStyle(isLastReorderable(index: index) ? .tertiary : .secondary)
            .disabled(isLastReorderable(index: index))
        }
    }

    private func isLastReorderable(index: Int) -> Bool {
        // Ne pas pouvoir descendre une ligne en dessous de la dernière ligne
        // "réelle" (i.e. excluant la trailing empty).
        let trailingEmptyIdx = actives.lastIndex { !$0.name.trimmingCharacters(in: .whitespaces).isEmpty }
        guard let lastFilled = trailingEmptyIdx else { return true }
        return index >= lastFilled
    }

    // MARK: - Inactive section

    @ViewBuilder
    private var inactiveSection: some View {
        Section {
            ForEach(inactives) { d in
                HStack(spacing: 8) {
                    Text(d.name)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Réintégrer") {
                        reintegrate(d)
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.green)
                    .font(.subheadline.weight(.semibold))
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button(role: .destructive) {
                        deleteInactiveDraft(d)
                    } label: {
                        Label("Supprimer", systemImage: "trash")
                    }
                }
            }
        } header: {
            Text("Joueurs inactifs")
        } footer: {
            Text("Soldes sauvegardés. Le joueur ne participe pas aux nouvelles manches tant qu'il n'est pas réintégré.")
        }
    }

    // MARK: - Load / commit

    private func load() {
        name = counter.name
        linePriceText = formatPriceForField(counter.linePrice)
        actives = counter.activePlayersOrdered.map {
            Draft(id: UUID(),
                  existingPlayerId: $0.id,
                  name: $0.name,
                  score: $0.score)
        }
        inactives = counter.inactivePlayersOrdered.map {
            Draft(id: UUID(),
                  existingPlayerId: $0.id,
                  name: $0.name,
                  score: $0.score)
        }
        ensureTrailingEmpty()
    }

    private var canCommit: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty &&
        cleanedActives.count >= 2 &&
        parsedLinePrice != nil
    }

    private var cleanedActives: [Draft] {
        actives.filter { !$0.name.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    private var parsedLinePrice: Double? {
        let normalized = linePriceText.replacingOccurrences(of: ",", with: ".")
        guard let value = Double(normalized), value > 0 else { return nil }
        return value
    }

    private func commit() {
        guard canCommit, let price = parsedLinePrice else { return }

        counter.name = name.trimmingCharacters(in: .whitespaces)
        counter.linePrice = price

        let activesClean = cleanedActives
        let allDrafts = activesClean + inactives
        let keptIds = Set(allDrafts.compactMap { $0.existingPlayerId })

        for p in counter.players where !keptIds.contains(p.id) {
            modelContext.delete(p)
        }

        for (idx, d) in activesClean.enumerated() {
            let trimmed = d.name.trimmingCharacters(in: .whitespaces)
            if let existingId = d.existingPlayerId,
               let p = counter.players.first(where: { $0.id == existingId }) {
                p.name = trimmed
                p.seat = idx
                p.isActive = true
            } else {
                let p = CounterPlayer(seat: idx, name: trimmed, isActive: true)
                p.counter = counter
                modelContext.insert(p)
            }
        }

        let activeCount = activesClean.count
        for (offset, d) in inactives.enumerated() {
            if let existingId = d.existingPlayerId,
               let p = counter.players.first(where: { $0.id == existingId }) {
                p.name = d.name.trimmingCharacters(in: .whitespaces)
                p.seat = activeCount + offset
                p.isActive = false
            }
        }

        let activeSeats = Array(0..<activeCount)
        if !activeSeats.contains(counter.dealerIdx) {
            counter.dealerIdx = activeSeats.first ?? 0
        }

        counter.lastUsedAt = .now
        try? modelContext.save()
        dismiss()
    }

    // MARK: - Active list management

    private func shouldShowExitButton(_ d: Draft) -> Bool {
        d.existingPlayerId != nil || !d.name.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func ensureTrailingEmpty() {
        while actives.count > 1,
              actives[actives.count - 1].name.trimmingCharacters(in: .whitespaces).isEmpty,
              actives[actives.count - 2].name.trimmingCharacters(in: .whitespaces).isEmpty {
            actives.removeLast()
        }
        if actives.isEmpty || !actives.last!.name.trimmingCharacters(in: .whitespaces).isEmpty {
            actives.append(Draft(id: UUID(), existingPlayerId: nil, name: "", score: 0))
        }
    }

    private func moveActives(from source: IndexSet, to destination: Int) {
        actives.move(fromOffsets: source, toOffset: destination)
        ensureTrailingEmpty()
    }

    private func moveActiveUp(at index: Int) {
        guard index > 0 else { return }
        actives.swapAt(index, index - 1)
    }

    private func moveActiveDown(at index: Int) {
        guard index < actives.count - 1 else { return }
        let next = actives[index + 1]
        // Ne pas swap avec la trailing empty (sinon elle remonte au milieu).
        if next.name.trimmingCharacters(in: .whitespaces).isEmpty {
            return
        }
        actives.swapAt(index, index + 1)
    }

    private func deleteActiveDraft(_ d: Draft) {
        actives.removeAll { $0.id == d.id }
        ensureTrailingEmpty()
    }

    private func deleteInactiveDraft(_ d: Draft) {
        inactives.removeAll { $0.id == d.id }
    }

    // MARK: - Toggle active / inactive

    private func excludePlayer(_ d: Draft) {
        let trimmed = d.name.trimmingCharacters(in: .whitespaces)
        actives.removeAll { $0.id == d.id }
        ensureTrailingEmpty()
        if d.existingPlayerId != nil, !trimmed.isEmpty {
            inactives.append(Draft(id: UUID(),
                                   existingPlayerId: d.existingPlayerId,
                                   name: trimmed,
                                   score: d.score))
        }
    }

    private func reintegrate(_ d: Draft) {
        inactives.removeAll { $0.id == d.id }
        let insertIdx = actives.firstIndex(where: {
            $0.name.trimmingCharacters(in: .whitespaces).isEmpty
        }) ?? actives.count
        actives.insert(Draft(id: UUID(),
                             existingPlayerId: d.existingPlayerId,
                             name: d.name,
                             score: d.score),
                       at: insertIdx)
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
}
