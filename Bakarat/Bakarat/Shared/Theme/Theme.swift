//
//  Theme.swift
//  Baccarat
//
//  Centralized colors and shared style modifiers. Avoid scattering raw hex
//  values across the project — add to this file when you need a new tint.
//

import SwiftUI

enum Theme {
    /// Bicycle red — the brand accent (gradient end is `brandRedDark`).
    static let brandRed     = Color(red: 0xC1 / 255, green: 0x26 / 255, blue: 0x2F / 255)
    static let brandRedDark = Color(red: 0x7E / 255, green: 0x12 / 255, blue: 0x19 / 255)

    static let brandGradient = LinearGradient(
        colors: [brandRed, brandRedDark],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    /// Danger button (matches iOS systemRed).
    static let systemRed = Color(red: 1.0, green: 0x3B / 255, blue: 0x30 / 255)
}

// MARK: - Reusable style modifiers

struct FormFieldStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(.subheadline)
            .padding(14)
            .background(Color(.systemGray6))
            .cornerRadius(10)
            .padding(.horizontal, 24)
            .padding(.vertical, 4)
    }
}

/// Style "CTA principal" : pilule rouge pleine largeur, hauteur 48pt, padding
/// horizontal 24pt. Implémenté comme ViewModifier (legacy) — applique le style
/// au CONTENU intérieur du Button (Text) pour garantir que toute la zone
/// visible soit tappable, pas uniquement le texte.
///
/// Usage : `Button { ... } label: { Text("X").modifier(PrimaryButtonStyle()) }`
struct PrimaryButtonStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 48)
            .background(Theme.brandGradient)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .shadow(color: Theme.brandRed.opacity(0.25), radius: 10, x: 0, y: 4)
            .padding(.horizontal, 24)
    }
}

struct DangerButtonStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 48)
            .background(Theme.systemRed)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
