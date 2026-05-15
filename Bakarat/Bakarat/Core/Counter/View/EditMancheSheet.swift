//
//  EditMancheSheet.swift
//  Bakarat
//
//  Édition d'une manche passée. Permet de :
//    - changer le gagnant / multi de chaque board
//    - inclure ou exclure un joueur de cette manche (cas d'erreur de saisie)
//
//  Au commit, les anciens deltas sont retirés des soldes et les nouveaux
//  appliqués. Le record CounterManche est mis à jour. Le dealer est conservé.
//

import SwiftUI
import SwiftData

struct EditMancheSheet: View {
    @Bindable var counter: Counter
    @Bindable var manche: CounterManche
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var mainBoards: [MainBoardState] = (0..<3).map { MainBoardState(id: $0) }
    /// Participants — chacun avec un seat réel (existant) ou temporaire négatif
    /// (nouveau joueur ajouté pendant l'édition). Une ligne vide en fin auto-révèle.
    @State private var participants: [ParticipantDraft] = []
    @State private var nextTempSeat: Int = -1
    @FocusState private var focusedParticipant: UUID?

    struct ParticipantDraft: Identifiable, Hashable {
        let id: UUID
        let existingPlayerId: UUID?
        var name: String
        let seat: Int
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Modifie les gagnants, multis ou la liste des joueurs participant à cette manche. Les soldes sont recalculés à la sauvegarde.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)

                    participantsCard
                    boardsCard

                    Button(action: commit) {
                        Text("Sauvegarder")
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .fill(canCommit ? Theme.brandRed : Theme.brandRed.opacity(0.35))
                            )
                    }
                    .buttonStyle(.plain)
                    .disabled(!canCommit)
                }
                .padding(16)
            }
            .background(Color(.systemGroupedBackground).ignoresSafeArea())
            .navigationTitle("Modifier manche \(manche.number)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annuler") { dismiss() }
                }
            }
            .onAppear(perform: load)
        }
    }

    // MARK: - Participants

    @ViewBuilder
    private var participantsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Joueurs de cette manche")
                .font(.subheadline.weight(.semibold))

            VStack(spacing: 8) {
                ForEach(Array($participants.enumerated()), id: \.element.id) { idx, $p in
                    participantRow($p)
                }
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
    }

    @ViewBuilder
    private func participantRow(_ p: Binding<ParticipantDraft>) -> some View {
        HStack(spacing: 8) {
            TextField("Prénom", text: p.name)
                .focused($focusedParticipant, equals: p.wrappedValue.id)
                .onChange(of: p.wrappedValue.name) { _, _ in
                    ensureTrailingEmpty()
                }
            // Bouton "retirer" : visible si row "remplie" (existante OU nom non vide
            // sur une row d'ajout). Pas sur la trailing empty row.
            if shouldShowRemove(p.wrappedValue) {
                Button {
                    removeParticipant(p.wrappedValue)
                } label: {
                    Image(systemName: "minus.circle.fill")
                        .foregroundStyle(.tertiary)
                        .font(.title3)
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(.tertiarySystemBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color(.systemGray4), lineWidth: 1)
        )
    }

    private func shouldShowRemove(_ p: ParticipantDraft) -> Bool {
        if p.existingPlayerId != nil { return true }
        return !p.name.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func removeParticipant(_ p: ParticipantDraft) {
        let seat = p.seat
        participants.removeAll { $0.id == p.id }
        // Retire le seat de tous les boards en cours.
        for i in mainBoards.indices {
            mainBoards[i].winners.remove(seat)
            for j in mainBoards[i].splits.indices {
                mainBoards[i].splits[j].winners.remove(seat)
            }
            syncSplits(forBoardIdx: i)
        }
        ensureTrailingEmpty()
    }

    private func ensureTrailingEmpty() {
        while participants.count > 1,
              participants[participants.count - 1].name.trimmingCharacters(in: .whitespaces).isEmpty,
              participants[participants.count - 2].name.trimmingCharacters(in: .whitespaces).isEmpty {
            participants.removeLast()
        }
        if participants.isEmpty ||
           !participants.last!.name.trimmingCharacters(in: .whitespaces).isEmpty {
            participants.append(ParticipantDraft(id: UUID(),
                                                  existingPlayerId: nil,
                                                  name: "",
                                                  seat: nextTempSeat))
            nextTempSeat -= 1
        }
    }

    /// Participants nommés (non-vides), triés par seat (réel d'abord puis tempo).
    private var namedParticipants: [ParticipantDraft] {
        participants
            .filter { !$0.name.trimmingCharacters(in: .whitespaces).isEmpty }
            .sorted { ($0.seat, $0.name) < ($1.seat, $1.name) }
    }

    private var participatingSeats: Set<Int> {
        Set(namedParticipants.map { $0.seat })
    }

    private func participantName(seat: Int) -> String {
        participants.first(where: { $0.seat == seat })?.name ?? "?"
    }

    // MARK: - Boards

    @ViewBuilder
    private var boardsCard: some View {
        VStack(spacing: 0) {
            ForEach(Array($mainBoards.enumerated()), id: \.element.id) { idx, $b in
                if idx > 0 {
                    Divider().padding(.vertical, 18)
                }
                boardBlock(label: "Board \($b.wrappedValue.id + 1)",
                           winners: $b.winners,
                           multi: $b.multi,
                           onChange: { syncSplits(forBoardIdx: $b.wrappedValue.id) })
            }

            ForEach(Array(allSplits.enumerated()), id: \.element.id) { idx, ref in
                Divider().padding(.vertical, 18)
                splitBlock(globalIndex: idx + 1, ref: ref)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
    }

    @ViewBuilder
    private func boardBlock(label: String,
                            winners: Binding<Set<Int>>,
                            multi: Binding<CounterMulti>,
                            onChange: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label)
                .font(.subheadline.weight(.semibold))

            let candidates = namedParticipants
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8),
                                GridItem(.flexible(), spacing: 8)],
                      spacing: 8) {
                ForEach(candidates) { p in
                    playerCell(name: p.name,
                               isSelected: winners.wrappedValue.contains(p.seat)) {
                        if winners.wrappedValue.contains(p.seat) {
                            winners.wrappedValue.remove(p.seat)
                        } else {
                            winners.wrappedValue.insert(p.seat)
                        }
                        onChange()
                    }
                }
            }

            multiPicker(multi)
        }
    }

    @ViewBuilder
    private func splitBlock(globalIndex: Int, ref: SplitRef) -> some View {
        let mainIdx = ref.mainBoardIdx
        let splitIdx = ref.splitIdx
        let allowed = allowedSeatsForSplit(mainIdx: mainIdx, splitIdx: splitIdx)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Self.goldDeep)
                Text("Split \(globalIndex)")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Self.goldDeep)
                Text("· Board \(mainIdx + 1)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            let candidates = namedParticipants.filter { allowed.contains($0.seat) }
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8),
                                GridItem(.flexible(), spacing: 8)],
                      spacing: 8) {
                ForEach(candidates) { p in
                    playerCell(name: p.name,
                               isSelected: mainBoards[mainIdx].splits[splitIdx].winners.contains(p.seat)) {
                        toggleSplitWinner(mainIdx: mainIdx, splitIdx: splitIdx, seat: p.seat)
                    }
                }
            }

            multiPicker(
                Binding(
                    get: { mainBoards[mainIdx].splits[splitIdx].multi },
                    set: { mainBoards[mainIdx].splits[splitIdx].multi = $0 }
                )
            )
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Self.goldLight)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Self.goldDeep.opacity(0.55), lineWidth: 1.2)
        )
    }

    fileprivate static let goldDeep = Color(red: 0.62, green: 0.46, blue: 0.05)
    fileprivate static let goldLight = Color(red: 0.96, green: 0.84, blue: 0.40).opacity(0.12)

    // MARK: - Cells (réutilise le look de CurrentMancheCard)

    @ViewBuilder
    private func playerCell(name: String,
                            isSelected: Bool,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            ZStack {
                Text(name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(isSelected ? .white : .primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .frame(maxWidth: .infinity)
                if isSelected {
                    HStack {
                        Spacer()
                        Image(systemName: "checkmark")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.white)
                    }
                    .padding(.trailing, 10)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isSelected ? Theme.brandRed : Color(.tertiarySystemBackground))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(isSelected ? Theme.brandRed : Color(.systemGray4),
                            lineWidth: isSelected ? 0 : 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func multiPicker(_ multi: Binding<CounterMulti>) -> some View {
        HStack(spacing: 4) {
            ForEach(CounterMulti.allCases) { m in
                Button {
                    multi.wrappedValue = m
                } label: {
                    let selected = multi.wrappedValue == m
                    VStack(spacing: 0) {
                        Text(m.displayLabel)
                            .font(.caption.weight(.bold))
                        Text(m.categoriesLabel)
                            .font(.system(size: 9))
                            .foregroundStyle(selected ? Theme.brandRed.opacity(0.85) : Color.secondary.opacity(0.7))
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(selected
                                  ? Theme.brandRed.opacity(0.14)
                                  : Color(.tertiarySystemBackground))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(selected ? Theme.brandRed : Color(.systemGray4),
                                    lineWidth: selected ? 1.5 : 1)
                    )
                    .foregroundStyle(selected ? Theme.brandRed : .secondary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Splits maintenance

    private struct SplitRef: Identifiable, Equatable {
        let id: UUID
        let mainBoardIdx: Int
        let splitIdx: Int
    }

    private var allSplits: [SplitRef] {
        var out: [SplitRef] = []
        for mb in mainBoards {
            for (si, sl) in mb.splits.enumerated() {
                out.append(SplitRef(id: sl.id, mainBoardIdx: mb.id, splitIdx: si))
            }
        }
        return out
    }

    private func allowedSeatsForSplit(mainIdx: Int, splitIdx: Int) -> Set<Int> {
        let mb = mainBoards[mainIdx]
        if splitIdx == 0 { return mb.winners }
        return mb.splits[splitIdx - 1].winners
    }

    private func toggleSplitWinner(mainIdx: Int, splitIdx: Int, seat: Int) {
        if mainBoards[mainIdx].splits[splitIdx].winners.contains(seat) {
            mainBoards[mainIdx].splits[splitIdx].winners.remove(seat)
        } else {
            mainBoards[mainIdx].splits[splitIdx].winners.insert(seat)
        }
        syncSplits(forBoardIdx: mainIdx)
    }

    private func syncSplits(forBoardIdx mainIdx: Int) {
        var mb = mainBoards[mainIdx]
        if mb.winners.count < 2 {
            mb.splits = []
            mainBoards[mainIdx] = mb
            return
        }
        if mb.splits.isEmpty {
            mb.splits = [SplitLevel()]
        }
        var allowedParent = mb.winners
        var i = 0
        while i < mb.splits.count {
            let clamped = mb.splits[i].winners.intersection(allowedParent)
            if clamped != mb.splits[i].winners {
                mb.splits[i].winners = clamped
            }
            let count = mb.splits[i].winners.count
            if count < 2 {
                if mb.splits.count > i + 1 {
                    mb.splits = Array(mb.splits.prefix(i + 1))
                }
                break
            }
            if i + 1 >= mb.splits.count {
                mb.splits.append(SplitLevel())
            }
            allowedParent = mb.splits[i].winners
            i += 1
        }
        mainBoards[mainIdx] = mb
    }

    // MARK: - Validation

    private var canCommit: Bool {
        guard namedParticipants.count >= 2 else { return false }
        for mb in mainBoards {
            if mb.winners.isEmpty { continue }
            if mb.winners.count == 1 { continue }
            guard let last = mb.splits.last else { return false }
            if last.winners.count != 1 { return false }
        }
        return true
    }

    // MARK: - Load / commit

    private func load() {
        // Participants : seats présents dans les deltas originaux.
        let originalSeats = Set(manche.perPlayerDeltas.keys)
        var ps: [ParticipantDraft] = []
        let activeSet = Set(counter.activePlayersOrdered.map { $0.seat })
        let pool = originalSeats.isEmpty ? activeSet : originalSeats
        for p in counter.playersOrdered where pool.contains(p.seat) {
            ps.append(ParticipantDraft(id: UUID(),
                                       existingPlayerId: p.id,
                                       name: p.name,
                                       seat: p.seat))
        }
        participants = ps
        ensureTrailingEmpty()

        // Reconstruit les mainBoards depuis manche.boardResults.
        var rebuilt: [MainBoardState] = (0..<3).map { MainBoardState(id: $0) }
        for b in manche.boardResults {
            guard b.board >= 0 && b.board < 3 else { continue }
            var mb = rebuilt[b.board]
            let splitters = b.splitterSeats ?? []
            let finalWinner = b.winnerSeat
            let multi = CounterMulti(rawValue: b.multi) ?? .x1

            if splitters.isEmpty {
                // Pas de split — single winner (ou abandonné si finalWinner nil).
                if let w = finalWinner {
                    mb.winners = [w]
                }
                mb.multi = multi
            } else {
                // Tie-break — main winners = original splitters.
                mb.winners = Set(splitters)
                mb.multi = .x1  // Le multi initial est inconnu, valeur arbitraire.
                // Un split avec le final winner.
                var split = SplitLevel()
                if let w = finalWinner {
                    split.winners = [w]
                }
                split.multi = multi
                mb.splits = [split]
            }
            rebuilt[b.board] = mb
        }
        mainBoards = rebuilt
    }

    private func commit() {
        guard canCommit else { return }

        // 1) Reverse les anciens deltas sur les soldes.
        let oldDeltas = manche.perPlayerDeltas
        for p in counter.players {
            if let d = oldDeltas[p.seat] {
                p.score -= d
            }
        }

        // 2) Crée les nouveaux CounterPlayer pour les drafts (temp seats négatifs).
        //    Et construit la table tempSeat → realSeat pour remap.
        var seatRemap: [Int: Int] = [:]
        let existingSeatsSorted = counter.players.map { $0.seat }.sorted()
        var nextRealSeat = (existingSeatsSorted.last ?? -1) + 1
        for draft in namedParticipants {
            if draft.existingPlayerId == nil {
                // Nouveau joueur — crée-le dans le counter avec un seat réel.
                let trimmed = draft.name.trimmingCharacters(in: .whitespaces)
                let p = CounterPlayer(seat: nextRealSeat, name: trimmed, isActive: true)
                p.counter = counter
                modelContext.insert(p)
                seatRemap[draft.seat] = nextRealSeat
                nextRealSeat += 1
            }
        }

        // 3) Remap les boards' winner seats (temp → real).
        func remapped(_ s: Int) -> Int { seatRemap[s] ?? s }
        for i in mainBoards.indices {
            mainBoards[i].winners = Set(mainBoards[i].winners.map(remapped))
            for j in mainBoards[i].splits.indices {
                mainBoards[i].splits[j].winners = Set(mainBoards[i].splits[j].winners.map(remapped))
            }
        }

        // 4) Recompute les deltas avec les seats réels.
        let newDeltas = computeNewDeltas()

        // 5) Apply.
        for p in counter.players {
            if let d = newDeltas[p.seat] {
                p.score += d
            }
        }

        // 6) Update le record CounterManche.
        var newResults: [CounterBoardResult] = []
        for mb in mainBoards {
            let r = resolveBoard(mb)
            newResults.append(CounterBoardResult(
                board: mb.id,
                winnerSeat: r.winner,
                multi: r.multi,
                isFullBoard: false,
                splitterSeats: r.splitters.isEmpty ? nil : r.splitters
            ))
        }
        let winners = newResults.map { $0.winnerSeat }
        if let w0 = winners[0], w0 == winners[1], w0 == winners[2] {
            for i in newResults.indices { newResults[i].isFullBoard = true }
        }

        manche.boardResults = newResults
        manche.perPlayerDeltas = newDeltas
        manche.validatedAt = .now
        counter.lastUsedAt = .now
        try? modelContext.save()
        dismiss()
    }

    private func resolveBoard(_ mb: MainBoardState) -> (winner: Int?, multi: Int, splitters: [Int]) {
        if mb.winners.isEmpty {
            return (nil, mb.multi.rawValue, [])
        }
        if mb.winners.count == 1 {
            return (mb.winners.first, mb.multi.rawValue, [])
        }
        let splitters = Array(mb.winners).sorted()
        if let last = mb.splits.last, last.winners.count == 1 {
            return (last.winners.first, last.multi.rawValue, splitters)
        }
        return (nil, mb.multi.rawValue, splitters)
    }

    private func computeNewDeltas() -> [Int: Double] {
        // Reconstruit la liste des seats participants APRÈS remap (commit l'a déjà fait).
        // À ce stade, participants contient encore les drafts ; on map via les players créés.
        var participatingNow: Set<Int> = []
        for draft in namedParticipants {
            if let id = draft.existingPlayerId,
               let p = counter.players.first(where: { $0.id == id }) {
                participatingNow.insert(p.seat)
            } else {
                // Trouve le player nouvellement créé via le nom (créé juste avant).
                let trimmed = draft.name.trimmingCharacters(in: .whitespaces)
                if let p = counter.players.first(where: { $0.name == trimmed && $0.seat >= 0 }) {
                    participatingNow.insert(p.seat)
                }
            }
        }

        var deltas: [Int: Double] = [:]
        for seat in participatingNow { deltas[seat] = 0 }

        let n = participatingNow.count
        guard n >= 2 else { return deltas }
        let price = counter.linePrice

        var finalWinners: [Int?] = []
        for mb in mainBoards {
            let r = resolveBoard(mb)
            finalWinners.append(r.winner)

            guard let winner = r.winner else { continue }

            if r.splitters.isEmpty {
                let payment = price * Double(r.multi)
                for seat in participatingNow {
                    if seat == winner {
                        deltas[seat, default: 0] += payment * Double(n - 1)
                    } else {
                        deltas[seat, default: 0] -= payment
                    }
                }
            } else {
                let splitterSet = Set(r.splitters)
                let multiPayment = price * Double(r.multi)
                let basePayment = price
                var winnerGains: Double = 0
                for seat in participatingNow where seat != winner {
                    if splitterSet.contains(seat) {
                        deltas[seat, default: 0] -= multiPayment
                        winnerGains += multiPayment
                    } else {
                        deltas[seat, default: 0] -= basePayment
                        winnerGains += basePayment
                    }
                }
                deltas[winner, default: 0] += winnerGains
            }
        }

        let allEqual = finalWinners.compactMap { $0 }.count == 3 &&
                       finalWinners[0] == finalWinners[1] &&
                       finalWinners[1] == finalWinners[2]
        if allEqual, let fb = finalWinners[0] {
            let bonus = price
            for seat in participatingNow {
                if seat == fb {
                    deltas[seat, default: 0] += bonus * Double(n - 1)
                } else {
                    deltas[seat, default: 0] -= bonus
                }
            }
        }

        return deltas
    }
}
