//
//  CounterPlayerRow.swift
//  Bakarat
//
//  Composant partagé : row "avatar + nom + (badge inline) + (sous-titre) +
//  (trailing)". Utilisé dans tous les endroits du compteur où on affiche un
//  joueur avec son solde, ses boards gagnés, son statut dealer, etc.
//
//  Caler tous les lieux d'affichage sur ce composant garantit un sizing
//  parfaitement homogène (avatar 30×30, padding H16 V8, nom subheadline.semibold).
//

import SwiftUI

struct CounterPlayerRow<Inline: View, Sub: View, Trailing: View>: View {
    let name: String
    /// Si true, l'avatar et le nom sont grisés (joueur inactif).
    var isDeemphasized: Bool = false
    @ViewBuilder var inlineBadge: () -> Inline
    @ViewBuilder var subtitle: () -> Sub
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(Theme.brandGradient)
                    .frame(width: 30, height: 30)
                Text(initial)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white)
            }
            .opacity(isDeemphasized ? 0.4 : 1)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(isDeemphasized ? .secondary : .primary)
                    inlineBadge()
                }
                subtitle()
            }

            Spacer()

            trailing()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private var initial: String {
        guard let c = name.trimmingCharacters(in: .whitespaces).first else { return "?" }
        return String(c).uppercased()
    }
}
