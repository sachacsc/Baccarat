//
//  LiquidGlassPill.swift
//  Bakarat
//
//  Capsule "liquid glass" iOS 26+ avec fallback `.ultraThinMaterial` pour
//  les versions antérieures. Utilisé pour les barres clavier accessoires
//  (lobby online, sheet de création compteur, etc.).
//

import SwiftUI

struct LiquidGlassPill: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(.regular, in: Capsule())
        } else {
            content.background(
                Capsule(style: .continuous)
                    .fill(.ultraThinMaterial)
            )
        }
    }
}
