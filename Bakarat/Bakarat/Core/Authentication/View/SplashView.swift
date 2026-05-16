//
//  SplashView.swift
//  Bakarat
//
//  Écran de chargement affiché au boot, le temps que la session soit
//  restaurée. Évite le flash AuthGate → TabBar quand l'utilisateur a une
//  session valide en cache.
//

import SwiftUI

struct SplashView: View {
    var body: some View {
        VStack(spacing: 18) {
            Spacer()
            BrandLogo(size: 132)
            Text("Bakarat")
                .font(.system(size: 28, weight: .semibold, design: .rounded))
                .foregroundStyle(.primary)
            Spacer()
            ProgressView()
                .controlSize(.small)
                .padding(.bottom, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground).ignoresSafeArea())
    }
}

#Preview {
    SplashView()
}
