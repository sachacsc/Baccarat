//
//  AnnounceSheet.swift
//  Bakarat
//
//  Vue inline montrée dans OnlineGameView pendant la phase .announcing.
//  - Permet de choisir une catégorie (grille 2 colonnes)
//  - Permet de toggler 1 ou 2 cartes parmi sa main (Hauteur ne nécessite rien)
//  - Bouton Confirmer envoie l'annonce au host
//  - Bouton Skip à part
//

import SwiftUI

struct AnnouncePanel: View {
    let mySeat: Int
    let myHand: [Card]
    let alreadySubmitted: Bool
    let onSubmit: (BoardSubmission) -> Void

    @State private var selectedCategory: HandCategory? = nil
    @State private var selectedCards: [Card] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if alreadySubmitted {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text("Annonce envoyée — en attente des autres joueurs.")
                        .font(.subheadline)
                }
                .padding(.vertical, 14)
                .padding(.horizontal, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color(.secondarySystemBackground))
                )
            } else {
                Text("Ton annonce")
                    .font(.subheadline.weight(.semibold))

                categoriesGrid
                handSelector
                actions
            }
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private var categoriesGrid: some View {
        let cols = [GridItem(.flexible()), GridItem(.flexible())]
        LazyVGrid(columns: cols, spacing: 8) {
            ForEach(HandCategory.allCases, id: \.self) { cat in
                Button {
                    selectedCategory = cat
                } label: {
                    HStack {
                        Text(cat.label)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                        Spacer()
                        if cat.multi > 1 {
                            Text("×\(cat.multi)")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(Theme.brandRed)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(selectedCategory == cat
                                  ? Theme.brandRed.opacity(0.16)
                                  : Color(.tertiarySystemBackground))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(selectedCategory == cat ? Theme.brandRed : .clear,
                                    lineWidth: 1.5)
                    )
                }
                .buttonStyle(.plain)
                .foregroundStyle(.primary)
            }
        }
    }

    @ViewBuilder
    private var handSelector: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Tes cartes")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(selectionHint)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                ForEach(myHand, id: \.self) { c in
                    Button {
                        toggle(c)
                    } label: {
                        miniCard(c, selected: selectedCards.contains(c))
                    }
                    .buttonStyle(.plain)
                    .disabled(selectedCategory == .highcard) // Hauteur = auto
                }
                Spacer()
            }
        }
        .padding(.top, 6)
    }

    @ViewBuilder
    private func miniCard(_ c: Card, selected: Bool) -> some View {
        VStack(spacing: 0) {
            Text(c.rank.display)
                .font(.system(size: 14, weight: .bold))
            Text(c.suit.symbol)
                .font(.system(size: 16))
        }
        .frame(width: 36, height: 50)
        .background(Color.white)
        .foregroundStyle(c.suit.isRed ? .red : .black)
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 5)
                .stroke(selected ? Theme.brandRed : Color.black.opacity(0.15),
                        lineWidth: selected ? 2.5 : 0.5)
        )
        .offset(y: selected ? -8 : 0)
        .animation(.easeOut(duration: 0.15), value: selected)
    }

    @ViewBuilder
    private var actions: some View {
        VStack(spacing: 10) {
            Button {
                guard let cat = selectedCategory else { return }
                onSubmit(BoardSubmission(categoryId: cat.id, cards: selectedCards))
            } label: {
                Text(confirmLabel)
            }
            .modifier(PrimaryButtonStyle())
            .disabled(!canConfirm)
            .opacity(canConfirm ? 1 : 0.5)

            Button {
                onSubmit(BoardSubmission(categoryId: "skip", cards: []))
            } label: {
                Text("Skip ce board")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.plain)
        }
        .padding(.top, 8)
    }

    // MARK: - Helpers

    private func toggle(_ c: Card) {
        if let idx = selectedCards.firstIndex(of: c) {
            selectedCards.remove(at: idx)
        } else if selectedCards.count < 2 {
            selectedCards.append(c)
        } else {
            // Max 2 : remplace la 1ère
            selectedCards.removeFirst()
            selectedCards.append(c)
        }
    }

    private var canConfirm: Bool {
        guard let cat = selectedCategory else { return false }
        if cat == .highcard { return true }
        // Pour les autres : 1 ou 2 cartes sélectionnées (RULES.md)
        return selectedCards.count >= 1
    }

    private var confirmLabel: String {
        guard let cat = selectedCategory else { return "Choisis une annonce" }
        if cat == .highcard { return "Confirmer : Hauteur (auto)" }
        return "Confirmer : \(cat.label) (\(selectedCards.count) carte\(selectedCards.count > 1 ? "s" : ""))"
    }

    private var selectionHint: String {
        guard let cat = selectedCategory else { return "Choisis d'abord une annonce" }
        if cat == .highcard { return "Auto-pick — pas besoin de sélectionner" }
        return "Choisis 1 ou 2 cartes"
    }
}
