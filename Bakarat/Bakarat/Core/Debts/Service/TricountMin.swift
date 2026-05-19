//
//  TricountMin.swift
//  Bakarat
//
//  Algorithme de minimisation du nombre de transactions pour un vecteur de
//  soldes signés par joueur (le même qu'utilisent Tricount / Splitwise) :
//  greedy creditor ↔ debtor matching. Produit au plus N-1 transactions pour
//  N joueurs non-nuls (souvent moins).
//
//  Appelé PAR PARTIE — la simplification est volontairement contenue au
//  roster de la partie ; aucune absorption inter-parties.
//

import Foundation

struct TricountPayment {
    let payerUserId: UUID
    let payeeUserId: UUID
    let amount: Double      // > 0
}

enum TricountMin {

    /// `deltas` : userId → solde signé (sum des deltas par seat sur toute la
    /// partie, projetés sur user_id). Positif = créditeur, négatif = débiteur.
    /// Les guests (sans user_id) doivent être exclus en amont.
    static func settle(deltas: [UUID: Double], epsilon: Double = 0.005) -> [TricountPayment] {
        // Bucket en créditeurs / débiteurs avec montants absolus.
        var creditors: [(uid: UUID, amount: Double)] = deltas
            .filter { $0.value >  epsilon }
            .map { (uid: $0.key, amount: $0.value) }
        var debtors: [(uid: UUID, amount: Double)] = deltas
            .filter { $0.value < -epsilon }
            .map { (uid: $0.key, amount: -$0.value) }

        creditors.sort { $0.amount > $1.amount }
        debtors.sort   { $0.amount > $1.amount }

        var out: [TricountPayment] = []
        var i = 0, j = 0
        while i < creditors.count && j < debtors.count {
            let amt = min(creditors[i].amount, debtors[j].amount)
            out.append(TricountPayment(
                payerUserId: debtors[j].uid,
                payeeUserId: creditors[i].uid,
                amount: amt
            ))
            creditors[i].amount -= amt
            debtors[j].amount   -= amt
            if creditors[i].amount <= epsilon { i += 1 }
            if debtors[j].amount   <= epsilon { j += 1 }
        }
        return out
    }
}
