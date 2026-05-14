//
//  AnnouncePanel.swift (anciennement AnnounceSheet)
//  Bakarat
//
//  Panel d'annonce affiché en bas de l'OnlineGameView pendant la phase
//  `.announcing`. Présente la grille de catégories et le bouton de confirmation.
//  La sélection des cartes se fait dans la main (above this panel) — pas ici,
//  pour éviter d'afficher la main 2 fois.
//

import SwiftUI

struct AnnouncePanel: View {
    let alreadySubmitted: Bool
    /// Si non-nil, la catégorie est verrouillée (cas tie-break) — on cache la
    /// grille et on utilise cette catégorie pour la confirm.
    var lockedCategory: HandCategory? = nil
    /// Cartes du board (regular ou tie-break) pour la validation live.
    var boardCards: [Card] = []
    /// Main complète du joueur (pour computeNuts).
    var myHole: [Card] = []
    /// Toutes les cartes communautaires de la manche (pour exclure les cartes
    /// déjà-utilisées du compute nuts).
    var allCommunityCards: [[Card]] = []
    /// La catégorie choisie par le user (binding parent). Ignoré si lockedCategory.
    @Binding var selectedCategory: HandCategory?
    /// Les cartes sélectionnées dans la main au-dessus (read-only).
    let selectedCards: [Card]
    /// Confirme avec la submission construite à partir de category + cards.
    let onConfirm: () -> Void
    /// Skip ce board.
    let onSkip: () -> Void

    /// Catégorie effective : lockedCategory en priorité, sinon selectedCategory.
    private var effectiveCategory: HandCategory? {
        lockedCategory ?? selectedCategory
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if alreadySubmitted {
                submittedView
            } else {
                if let locked = lockedCategory {
                    lockedHeader(locked)
                } else {
                    Text("Choisis ton annonce")
                        .font(.subheadline.weight(.semibold))
                    categoriesGrid
                }
                hintLine
                actions
            }
        }
    }

    @ViewBuilder
    private func lockedHeader(_ cat: HandCategory) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "bolt.fill")
                .foregroundStyle(Theme.brandRed)
            VStack(alignment: .leading, spacing: 2) {
                Text("Tie-break — annonce verrouillée")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(cat.label)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(Theme.brandRed)
            }
            Spacer()
            if cat.multi > 1 {
                Text("×\(cat.multi)")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Theme.brandRed)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(Theme.brandRed.opacity(0.12)))
            }
        }
    }

    // MARK: - Submitted state

    @ViewBuilder
    private var submittedView: some View {
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
                .fill(Color(.tertiarySystemBackground))
        )
    }

    // MARK: - Categories grid

    @ViewBuilder
    private var categoriesGrid: some View {
        // 3 colonnes × 3 lignes — Hauteur retirée (= default auto si rien
        // n'est sélectionné). Labels raccourcis pour tenir sur 1 ligne.
        let cols = [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())]
        let categories = HandCategory.allCases.filter { $0 != .highcard }
        LazyVGrid(columns: cols, spacing: 6) {
            ForEach(categories, id: \.self) { cat in
                Button {
                    selectedCategory = cat
                } label: {
                    VStack(spacing: 2) {
                        Text(shortLabel(cat))
                            .font(.caption.weight(.semibold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                        if cat.multi > 1 {
                            Text("×\(cat.multi)")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(Theme.brandRed)
                        }
                    }
                    .padding(.horizontal, 4)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, minHeight: 40)
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

    /// Labels compacts pour la grille (les labels normaux passent en label de
    /// résultat dans les autres écrans).
    private func shortLabel(_ cat: HandCategory) -> String {
        switch cat {
        case .highcard:  return "Hauteur"
        case .pair:      return "Paire"
        case .twopair:   return "2 Paires"
        case .trips:     return "Brelan"
        case .straight:  return "Suite"
        case .flush:     return "Couleur"
        case .fullhouse: return "Full"
        case .quads:     return "Carré"
        case .sflush:    return "Q. Flush"
        case .royal:     return "Royale"
        }
    }

    // MARK: - Hint + actions

    @ViewBuilder
    private var hintLine: some View {
        let txt: String = {
            guard let cat = effectiveCategory else {
                return "Aucune catégorie → Hauteur auto avec tes 2 plus hautes cartes."
            }
            if cat == .highcard {
                return "Hauteur — pas besoin de toucher tes cartes."
            }
            switch selectedCards.count {
            case 0: return "Sélectionne 1 ou 2 cartes dans ta main."
            case 1: return "1 carte sélectionnée — tu peux en ajouter une 2e."
            default: return "\(selectedCards.count) cartes sélectionnées."
            }
        }()
        Text(txt)
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var actions: some View {
        VStack(spacing: 10) {
            Button(action: onConfirm) {
                Text(confirmLabel)
            }
            .modifier(PrimaryButtonStyle())
            .disabled(!canConfirm)
            .opacity(canConfirm ? 1 : 0.5)

            Button(action: onSkip) {
                Text("Skip ce board")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.plain)
        }
        .padding(.top, 6)
    }

    private var canConfirm: Bool {
        // Aucune catégorie sélectionnée → on autorise la confirmation (= Hauteur
        // auto avec les 2 plus hautes cartes). Si Hauteur explicite → toujours OK.
        // Sinon : au moins 1 carte sélectionnée requise.
        guard let cat = effectiveCategory else { return true }
        if cat == .highcard { return true }
        return selectedCards.count >= 1
    }

    private var confirmLabel: String {
        guard let cat = effectiveCategory else {
            return "Confirmer : Hauteur (auto)"
        }
        if cat == .highcard { return "Confirmer : Hauteur (auto)" }
        let n = selectedCards.count
        return "Confirmer : \(cat.label) (\(n) carte\(n > 1 ? "s" : ""))"
    }
}
