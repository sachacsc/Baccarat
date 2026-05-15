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
    @State private var currency: String = "€"

    @State private var actives: [Draft] = []
    @State private var inactives: [Draft] = []

    @FocusState private var focusedField: Field?

    enum Field: Hashable {
        case name, price, player(UUID)
    }

    struct Draft: Identifiable, Hashable {
        let id: UUID
        let existingPlayerId: UUID?
        var name: String
        var score: Double
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Nom du compteur") {
                    TextField("Soirée chez Alex", text: $name)
                        .focused($focusedField, equals: .name)
                        .submitLabel(.next)
                        .onSubmit { focusedField = .price }
                }

                Section("Prix d'une ligne") {
                    HStack {
                        TextField("1", text: $linePriceText)
                            .keyboardType(.decimalPad)
                            .focused($focusedField, equals: .price)
                        Picker("", selection: $currency) {
                            ForEach(["€", "$", "£", "CHF"], id: \.self) { c in
                                Text(c).tag(c)
                            }
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 180)
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
            .onAppear(perform: load)
        }
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
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 2
        linePriceText = formatter.string(from: NSNumber(value: counter.linePrice)) ?? "\(counter.linePrice)"
        currency = counter.currency
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
        counter.currency = currency

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
