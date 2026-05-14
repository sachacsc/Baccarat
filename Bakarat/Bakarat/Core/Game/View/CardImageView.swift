//
//  CardImageView.swift
//  Bakarat
//
//  Affiche une carte avec l'image xCards bundlée dans Assets.xcassets/Cards.
//  Rendu instantané (pas de cache réseau), ratio 5:7.
//
//    - card != nil + faceDown == false → face de la carte
//    - faceDown == true                → dos bicycle_blue
//    - card == nil + faceDown == false → slot vide (rectangle pointillé)
//

import SwiftUI
import UniformTypeIdentifiers

// MARK: - Drag & drop support

extension Card: Transferable {
    static var transferRepresentation: some TransferRepresentation {
        // Représentation via String ("AS", "TH", …) — pas de Codable pour éviter
        // les soucis Sendable en Swift 6 strict.
        DataRepresentation(contentType: .text) { card in
            card.description.data(using: .utf8) ?? Data()
        } importing: { data in
            guard let s = String(data: data, encoding: .utf8),
                  let c = Card(s) else {
                throw CocoaError(.coderInvalidValue)
            }
            return c
        }
    }
}

struct CardImageView: View {
    let card: Card?
    var faceDown: Bool = false
    let width: CGFloat

    private var height: CGFloat { (width * 7 / 5).rounded() }
    private var cornerRadius: CGFloat { max(4, width * 0.075) }

    var body: some View {
        if card == nil && !faceDown {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(Color(.separator),
                              style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
                .frame(width: width, height: height)
        } else {
            assetImage
                .resizable()
                .interpolation(.high)
                .aspectRatio(5.0 / 7.0, contentMode: .fill)
                .frame(width: width, height: height)
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .stroke(Color.black.opacity(0.10), lineWidth: 0.5)
                )
                .shadow(color: .black.opacity(0.08), radius: 1.5, x: 0, y: 1)
        }
    }

    /// Asset bundlé — pas d'AsyncImage, pas de cache, rendu instantané.
    private var assetImage: Image {
        if faceDown {
            return Image(Card.backAssetName)
        }
        if let card {
            return Image(card.assetName)
        }
        return Image(Card.backAssetName)
    }
}

#Preview {
    HStack(spacing: 6) {
        CardImageView(card: Card("AS"), width: 60)
        CardImageView(card: Card("TH"), width: 60)
        CardImageView(card: nil, faceDown: true, width: 60)
        CardImageView(card: nil, width: 60)
    }
    .padding()
}
