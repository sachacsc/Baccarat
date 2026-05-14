//
//  Card.swift
//  Baccarat
//
//  Représentation d'une carte. Sérialisée en string "RS" (ex. "TS" = 10 de pique)
//  pour rester compatible avec le format JSON utilisé côté web et côté Supabase
//  (board_results.winner_seat etc.).
//
//  Rangs : "2","3","4","5","6","7","8","9","T","J","Q","K","A"
//  Couleurs : "c" (clubs), "d" (diamonds), "h" (hearts), "s" (spades)
//

import Foundation

enum Suit: String, CaseIterable, Codable {
    case clubs    = "c"
    case diamonds = "d"
    case hearts   = "h"
    case spades   = "s"

    var symbol: String {
        switch self {
        case .clubs:    return "♣"
        case .diamonds: return "♦"
        case .hearts:   return "♥"
        case .spades:   return "♠"
        }
    }

    var isRed: Bool { self == .diamonds || self == .hearts }
}

enum Rank: String, CaseIterable, Codable {
    case two   = "2"
    case three = "3"
    case four  = "4"
    case five  = "5"
    case six   = "6"
    case seven = "7"
    case eight = "8"
    case nine  = "9"
    case ten   = "T"
    case jack  = "J"
    case queen = "Q"
    case king  = "K"
    case ace   = "A"

    /// Valeur numérique pour comparaisons (2..14)
    var value: Int {
        switch self {
        case .two: 2; case .three: 3; case .four: 4; case .five: 5; case .six: 6
        case .seven: 7; case .eight: 8; case .nine: 9; case .ten: 10
        case .jack: 11; case .queen: 12; case .king: 13; case .ace: 14
        }
    }

    var display: String {
        switch self {
        case .ten: return "10"
        case .jack: return "V"
        case .queen: return "D"
        case .king: return "R"
        default: return rawValue
        }
    }
}

struct Card: Hashable, Codable, CustomStringConvertible {
    let rank: Rank
    let suit: Suit

    /// "TS", "9H", "AC", etc.
    var description: String { rank.rawValue + suit.rawValue }

    init(rank: Rank, suit: Suit) {
        self.rank = rank
        self.suit = suit
    }

    /// Parse depuis le format string "RS". Renvoie nil si invalide.
    init?(_ string: String) {
        guard string.count == 2,
              let rank = Rank(rawValue: String(string.first!)),
              let suit = Suit(rawValue: String(string.last!))
        else { return nil }
        self.rank = rank
        self.suit = suit
    }

    // Codable as plain string for JSON interop
    init(from decoder: Decoder) throws {
        let s = try decoder.singleValueContainer().decode(String.self)
        guard let parsed = Card(s) else {
            throw DecodingError.dataCorruptedError(in: try decoder.singleValueContainer(),
                                                   debugDescription: "Invalid card \(s)")
        }
        self = parsed
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(description)
    }

    /// Nom de l'asset bundlé (Assets.xcassets/Cards/card_XX.imageset).
    /// Toutes les cartes xCards sont embarquées localement pour un rendu instantané
    /// sans dépendance réseau.
    var assetName: String { "card_\(rank.rawValue)\(suit.rawValue.uppercased())" }
    static var backAssetName: String { "card_back" }
}

enum Deck {
    /// 52 cartes dans l'ordre canonique.
    static let full: [Card] = Rank.allCases.flatMap { r in Suit.allCases.map { Card(rank: r, suit: $0) } }

    /// Fisher-Yates, non-mutant.
    static func shuffled(_ src: [Card] = full) -> [Card] {
        var a = src
        for i in stride(from: a.count - 1, to: 0, by: -1) {
            let j = Int.random(in: 0...i)
            a.swapAt(i, j)
        }
        return a
    }
}
