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
                .listRowBackground(Color(.secondarySystemBackground))
            }
            .onDelete(perform: deleteCounter)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
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
    @State private var linePriceText = "1"
    @State private var currency = "€"
    /// Actifs : toujours au moins 1 ligne vide en fin (auto-reveal).
    @State private var actives: [PlayerDraft] = [PlayerDraft()]
    /// Inactifs : peuplé uniquement par paste/import. Pas d'édition manuelle ici.
    @State private var inactives: [PlayerDraft] = []
    /// Nom de joueur à utiliser comme dealer initial (depuis paste, sinon nil).
    @State private var importedDealerName: String? = nil
    /// État après tentative de paste. Affiche un bandeau confirmation/erreur.
    @State private var pasteFeedback: PasteFeedback? = nil
    @FocusState private var focusedField: Field?

    enum Field: Hashable {
        case name, price, player(UUID)
    }

    enum PasteFeedback: Equatable {
        case success(activeCount: Int, inactiveCount: Int)
        case failure
    }

    var body: some View {
        NavigationStack {
            List {
                pasteSection

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
                            if abs(p.initialScore) > 0.001 {
                                Text(formatSignedScore(p.initialScore))
                                    .font(.caption.weight(.semibold))
                                    .monospacedDigit()
                                    .foregroundStyle(p.initialScore > 0 ? .green : .red)
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

                if !inactives.isEmpty {
                    Section {
                        ForEach(inactives) { p in
                            HStack {
                                Text(p.name)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                if abs(p.initialScore) > 0.001 {
                                    Text(formatSignedScore(p.initialScore))
                                        .font(.caption.weight(.semibold))
                                        .monospacedDigit()
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .onDelete(perform: deleteInactive)
                    } header: {
                        Text("Joueurs inactifs")
                    } footer: {
                        Text("Importés depuis le presse-papier — soldes conservés. Tu pourras les réintégrer depuis les Réglages.")
                    }
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
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
            .onAppear { focusedField = .name }
        }
    }

    // MARK: - Paste section

    @ViewBuilder
    private var pasteSection: some View {
        Section {
            Button(action: pasteFromClipboard) {
                HStack(spacing: 12) {
                    Image(systemName: "doc.on.clipboard")
                        .foregroundStyle(.white)
                        .frame(width: 28, height: 28)
                        .background(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(Theme.brandRed)
                        )
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Coller un état existant")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                        Text("Reprend des comptes notés à la main ou exportés depuis un autre compteur.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
            }
            .buttonStyle(.plain)
            if let pasteFeedback {
                pasteFeedbackRow(pasteFeedback)
            }
        }
    }

    @ViewBuilder
    private func pasteFeedbackRow(_ feedback: PasteFeedback) -> some View {
        switch feedback {
        case .success(let a, let i):
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("État importé : \(a) actif\(a > 1 ? "s" : "")\(i > 0 ? " + \(i) inactif\(i > 1 ? "s" : "")" : ""). Donne-lui un nom puis tape Créer.")
                    .font(.caption)
            }
        case .failure:
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text("Format non reconnu. Le presse-papier doit contenir au moins 2 lignes “Nom : montant”.")
                    .font(.caption)
            }
        }
    }

    private func pasteFromClipboard() {
        guard let raw = UIPasteboard.general.string,
              !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            pasteFeedback = .failure
            return
        }
        guard let parsed = CounterStateExporter.parse(raw) else {
            pasteFeedback = .failure
            return
        }
        if let n = parsed.name { name = n }
        linePriceText = String(parsed.linePrice).replacingOccurrences(of: ".0", with: "")
        currency = parsed.currency
        actives = parsed.activePlayers.map {
            PlayerDraft(name: $0.name, initialScore: $0.score)
        }
        inactives = parsed.inactivePlayers.map {
            PlayerDraft(name: $0.name, initialScore: $0.score)
        }
        importedDealerName = parsed.dealerName
        ensureTrailingEmpty()
        pasteFeedback = .success(activeCount: actives.filter {
            !$0.name.trimmingCharacters(in: .whitespaces).isEmpty
        }.count,
                                  inactiveCount: inactives.count)
        if name.isEmpty {
            focusedField = .name
        }
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

    private func deleteInactive(at offsets: IndexSet) {
        inactives.remove(atOffsets: offsets)
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
                              currency: currency,
                              dealerIdx: 0,
                              configured: true)
        modelContext.insert(counter)

        // Actifs : seats 0..N-1
        for (i, p) in cleanActives.enumerated() {
            let player = CounterPlayer(seat: i,
                                       name: p.name.trimmingCharacters(in: .whitespaces),
                                       score: p.initialScore,
                                       isActive: true)
            player.counter = counter
            modelContext.insert(player)
        }
        // Inactifs (depuis paste) : seats N..N+M-1
        let activeCount = cleanActives.count
        for (offset, p) in inactives.enumerated() {
            let player = CounterPlayer(seat: activeCount + offset,
                                       name: p.name,
                                       score: p.initialScore,
                                       isActive: false)
            player.counter = counter
            modelContext.insert(player)
        }

        // Dealer initial : si paste a indiqué un nom, on le retrouve dans les actifs.
        if let dn = importedDealerName,
           let idx = cleanActives.firstIndex(where: { $0.name.caseInsensitiveCompare(dn) == .orderedSame }) {
            counter.dealerIdx = idx
        }

        try? modelContext.save()
        dismiss()
    }

    private func formatSignedScore(_ v: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 2
        let n = formatter.string(from: NSNumber(value: abs(v))) ?? "\(abs(v))"
        return v > 0 ? "+\(n) \(currency)" : "−\(n) \(currency)"
    }
}
