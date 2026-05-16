//
//  BrandLogo.swift
//  Bakarat
//
//  Logo officiel de l'app (joker + cartes) chargé depuis Assets.xcassets.
//  Fallback programmatique si l'asset est absent — pour ne jamais avoir un
//  trou visuel pendant le dev.
//

import SwiftUI

struct BrandLogo: View {
    var size: CGFloat = 96

    var body: some View {
        Image("BrandLogoAsset")
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
    }
}

#Preview {
    BrandLogo(size: 96)
}
