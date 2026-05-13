//
//  HandEvaluator.swift
//  Baccarat
//
//  Port direct de src/game/eval.js. Évalue 5 cartes en (catégorie + tie-break ranks).
//  Pour > 5 cartes, on cherche la meilleure combinaison.
//
//  Aucune dépendance UI, async ou réseau — pure logique métier.
//

import Foundation

/// Résultat d'évaluation d'une main de 5 cartes.
struct HandValue: Equatable {
    let category: HandCategory
    /// Kickers, de la plus signifiante à la moins (pour départager à catégorie égale).
    let ranks: [Int]
}

enum HandEvaluator {

    /// Évalue exactement 5 cartes.
    static func evaluate5(_ cards: [Card]) -> HandValue {
        precondition(cards.count == 5, "evaluate5 expects 5 cards")
        let ranks = cards.map(\.rank.value).sorted(by: >)
        let isFlush = Set(cards.map(\.suit)).count == 1

        // Compte de chaque rang
        var counts: [Int: Int] = [:]
        for r in ranks { counts[r, default: 0] += 1 }
        // Liste (rang, count) triée par count DESC puis rang DESC
        let countArr = counts.map { ($0.key, $0.value) }.sorted {
            if $0.1 != $1.1 { return $0.1 > $1.1 }
            return $0.0 > $1.0
        }
        let uniq = Array(Set(ranks)).sorted(by: >)

        var straightHigh = 0
        if uniq.count == 5 {
            if uniq[0] - uniq[4] == 4 { straightHigh = uniq[0] }
            // Wheel : A-2-3-4-5
            if uniq[0] == 14 && uniq[1] == 5 && uniq[2] == 4 && uniq[3] == 3 && uniq[4] == 2 {
                straightHigh = 5
            }
        }
        let isStraight = straightHigh > 0

        if isStraight && isFlush {
            if straightHigh == 14 { return HandValue(category: .royal, ranks: [14]) }
            return HandValue(category: .sflush, ranks: [straightHigh])
        }
        if countArr[0].1 == 4 {
            return HandValue(category: .quads, ranks: [countArr[0].0, countArr[1].0])
        }
        if countArr[0].1 == 3 && countArr[1].1 == 2 {
            return HandValue(category: .fullhouse, ranks: [countArr[0].0, countArr[1].0])
        }
        if isFlush    { return HandValue(category: .flush, ranks: ranks) }
        if isStraight { return HandValue(category: .straight, ranks: [straightHigh]) }
        if countArr[0].1 == 3 {
            return HandValue(category: .trips, ranks: [countArr[0].0, countArr[1].0, countArr[2].0])
        }
        if countArr[0].1 == 2 && countArr[1].1 == 2 {
            return HandValue(category: .twopair, ranks: [countArr[0].0, countArr[1].0, countArr[2].0])
        }
        if countArr[0].1 == 2 {
            return HandValue(category: .pair,
                             ranks: [countArr[0].0, countArr[1].0, countArr[2].0, countArr[3].0])
        }
        return HandValue(category: .highcard, ranks: ranks)
    }

    /// Meilleure combinaison de 5 cartes parmi n ≥ 5.
    static func evaluateBest(_ cards: [Card]) -> HandValue? {
        guard cards.count >= 5 else { return nil }
        if cards.count == 5 { return evaluate5(cards) }
        var best: HandValue?
        let n = cards.count
        for a in 0..<(n-4) {
            for b in (a+1)..<(n-3) {
                for c in (b+1)..<(n-2) {
                    for d in (c+1)..<(n-1) {
                        for e in (d+1)..<n {
                            let v = evaluate5([cards[a], cards[b], cards[c], cards[d], cards[e]])
                            if let cur = best {
                                if compare(v, cur) > 0 { best = v }
                            } else {
                                best = v
                            }
                        }
                    }
                }
            }
        }
        return best
    }

    /// Compare deux mains. >0 si a meilleure, <0 si b meilleure, 0 si égalité parfaite.
    static func compare(_ a: HandValue, _ b: HandValue) -> Int {
        let ar = a.category.rawValue, br = b.category.rawValue
        if ar != br { return ar - br }
        let len = max(a.ranks.count, b.ranks.count)
        for i in 0..<len {
            let av = i < a.ranks.count ? a.ranks[i] : 0
            let bv = i < b.ranks.count ? b.ranks[i] : 0
            if av != bv { return av - bv }
        }
        return 0
    }

    /// Vrai si holeCards + boardCards permettent AU MOINS la catégorie annoncée.
    static func validateAnnounce(_ announced: HandCategory,
                                 hole: [Card],
                                 board: [Card]) -> Bool {
        guard let best = evaluateBest(hole + board) else { return false }
        return best.category.rawValue >= announced.rawValue
    }

    /// Pour Hauteur : pioche automatiquement les 2 cartes qui maximisent la main.
    /// Pour les autres catégories : trouve les 2 cartes qui satisfont l'annonce et
    /// maximisent la force (nil si pas réalisable).
    static func autoPickCards(announced: HandCategory,
                              hole: [Card],
                              board: [Card]) -> [Card]? {
        guard hole.count >= 2 else { return nil }
        var best: (cards: [Card], value: HandValue)?
        for i in 0..<(hole.count - 1) {
            for j in (i + 1)..<hole.count {
                let combo = [hole[i], hole[j]]
                guard let v = evaluateBest(combo + board) else { continue }
                guard v.category.rawValue >= announced.rawValue else { continue }
                if let cur = best {
                    if compare(v, cur.value) > 0 { best = (combo, v) }
                } else {
                    best = (combo, v)
                }
            }
        }
        return best?.cards
    }

    /// Nuts théorique d'un board, du point de vue d'un observateur (= sa main est
    /// retirée du pool, le reste des cartes hors community est candidat).
    static func computeNuts(boardCards: [Card],
                            allCommunityCards: [[Card]],
                            viewerHand: [Card]) -> (category: HandCategory, ranks: [Int], cards: [Card])? {
        guard boardCards.count >= 5 else { return nil }
        var used = Set<Card>()
        for set in allCommunityCards { used.formUnion(set) }
        used.formUnion(viewerHand)
        let pool = Deck.full.filter { !used.contains($0) }
        var best: (cards: [Card], value: HandValue)?
        for i in 0..<(pool.count - 1) {
            for j in (i + 1)..<pool.count {
                let combo = [pool[i], pool[j]]
                guard let v = evaluateBest(combo + boardCards) else { continue }
                if let cur = best {
                    if compare(v, cur.value) > 0 { best = (combo, v) }
                } else {
                    best = (combo, v)
                }
            }
        }
        return best.map { (cards: $0.cards, value: $0.value) }
            .map { (category: $0.value.category, ranks: $0.value.ranks, cards: $0.cards) }
    }
}
