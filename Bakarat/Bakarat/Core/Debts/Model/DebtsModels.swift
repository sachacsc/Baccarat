//
//  DebtsModels.swift
//  Bakarat
//
//  Modèles de l'onglet "Dettes" — recalculés à la volée à partir des parties
//  où je suis loggé. Deux niveaux de vue :
//
//   • par joueur  : DebtAggregate (somme sur toutes les parties non-réglées)
//   • par partie  : GameDebt + GamePayment (chaque payment me concerne)
//
//  Cohort & re-routing : la simplification Tricount-min est faite PAR PARTIE
//  (les seats loggés d'une même partie peuvent s'absorber les uns les autres).
//  Aucune re-routing inter-parties → si A et C n'ont jamais joué ensemble,
//  ils n'apparaîtront jamais dans le ledger l'un de l'autre.
//
//  Settlement : 1 row par paire-par-partie dans `game_pair_settlements`,
//  bilatéral (n'importe lequel des deux users peut déclarer payé, l'autre
//  voit aussitôt la ligne barrée).
//

import Foundation

/// Direction d'un payment depuis le POV du user courant.
enum DebtDirection {
    case iOwe       // je paie l'autre
    case owesMe     // l'autre me paie
}

/// Une transaction (paire ↔ paire) issue d'une partie unique.
struct GamePayment: Identifiable, Hashable {
    let gameId: UUID
    let otherUserId: UUID
    /// Montant absolu (toujours > 0).
    let amount: Double
    let direction: DebtDirection
    let isSettled: Bool

    /// Identifiant stable d'une row "par partie".
    var id: String { "\(gameId.uuidString)|\(otherUserId.uuidString)" }
}

/// Synthèse "par joueur" — net signé des paiements NON-réglés agrégés.
struct DebtAggregate: Identifiable, Hashable {
    let otherUserId: UUID
    var displayName: String
    var avatarUrl: String?
    /// Convention :
    ///   amount > 0 → l'autre me doit (créance nette)
    ///   amount < 0 → je dois à l'autre (dette nette)
    var amount: Double
    /// gameIds qui contribuent (paiements non-réglés impliquant cette paire).
    var contributingGameIds: [UUID]

    var id: UUID { otherUserId }

    var absAmount: Double { abs(amount) }
    var direction: DebtDirection { amount < 0 ? .iOwe : .owesMe }
}

/// Synthèse "par partie" — toutes les transactions me concernant pour ce game.
struct GameDebt: Identifiable, Hashable {
    let gameId: UUID
    /// "online" ou "counter".
    let mode: String
    let createdAt: Date
    let payments: [GamePayment]

    var id: UUID { gameId }

    /// True quand toutes les transactions me concernant sont marquées réglées
    /// (ou qu'il n'y en a aucune). Sert au greying des rows historique.
    var isFullySettledByMe: Bool {
        payments.allSatisfy { $0.isSettled }
    }

    /// Net signé après filtrage des règlements (positif = je suis créditeur).
    var openNet: Double {
        payments.filter { !$0.isSettled }.reduce(0) { acc, p in
            acc + (p.direction == .owesMe ? p.amount : -p.amount)
        }
    }

    var hasOpenPayments: Bool { payments.contains(where: { !$0.isSettled }) }
}
