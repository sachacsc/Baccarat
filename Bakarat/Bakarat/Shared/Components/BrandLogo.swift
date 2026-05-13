//
//  BrandLogo.swift
//  Bakarat
//
//  Logo placeholder programmatique en attendant un vrai AppIcon dans Assets.
//  Cercle gradient rouge avec "B" centré, ombre légère.
//

import SwiftUI

struct BrandLogo: View {
    var size: CGFloat = 96

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                .fill(Theme.brandGradient)
                .shadow(color: Theme.brandRed.opacity(0.25), radius: size * 0.12, x: 0, y: size * 0.06)

            Text("B")
                .font(.system(size: size * 0.55, weight: .bold, design: .serif))
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
    }
}

#Preview {
    BrandLogo(size: 96)
}
