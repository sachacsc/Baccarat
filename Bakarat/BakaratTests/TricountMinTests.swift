//
//  TricountMinTests.swift
//  BakaratTests
//
//  Couvre l'algorithme greedy de minimisation des transactions utilisé pour
//  l'onglet Comptes. Garde-fous contre les régressions : sortie déterministe,
//  conservation de la somme, et au plus N-1 transactions pour N joueurs.
//

import Testing
import Foundation
@testable import Bakarat

struct TricountMinTests {

    // 4 UUIDs stables pour rendre les tests lisibles + reproductibles.
    private let A = UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!
    private let B = UUID(uuidString: "00000000-0000-0000-0000-00000000000B")!
    private let C = UUID(uuidString: "00000000-0000-0000-0000-00000000000C")!
    private let D = UUID(uuidString: "00000000-0000-0000-0000-00000000000D")!

    @Test func emptyReturnsNothing() {
        #expect(TricountMin.settle(deltas: [:]).isEmpty)
    }

    @Test func zeroSumNoNonZeroReturnsNothing() {
        let result = TricountMin.settle(deltas: [A: 0, B: 0])
        #expect(result.isEmpty)
    }

    @Test func simplePairOneTransaction() {
        // B doit 10 à A.
        let result = TricountMin.settle(deltas: [A: 10, B: -10])
        #expect(result.count == 1)
        #expect(result[0].payerUserId == B)
        #expect(result[0].payeeUserId == A)
        #expect(result[0].amount == 10)
    }

    @Test func threeWayOneWinner() {
        // A gagne 20, B et C perdent 10 chacun → 2 transactions, somme = 20.
        let result = TricountMin.settle(deltas: [A: 20, B: -10, C: -10])
        #expect(result.count == 2)
        let total = result.reduce(0) { $0 + $1.amount }
        #expect(total == 20)
        #expect(result.allSatisfy { $0.payeeUserId == A })
    }

    @Test func fourPlayersBoundedByNMinusOne() {
        // 4 joueurs non-nuls → max 3 transactions.
        let result = TricountMin.settle(deltas: [A: 30, B: 10, C: -25, D: -15])
        #expect(result.count <= 3)
        // Conservation : la somme des paiements = somme des absolutes des
        // créditeurs (ou des débiteurs).
        let total = result.reduce(0) { $0 + $1.amount }
        #expect(total == 40)
    }

    @Test func epsilonFiltersNearZero() {
        // 0.003 < default epsilon 0.005 → ignoré.
        let result = TricountMin.settle(deltas: [A: 0.003, B: -0.003])
        #expect(result.isEmpty)
    }

    @Test func sumPreservation() {
        // Vecteur asymétrique : 2 créditeurs, 1 débiteur.
        let deltas: [UUID: Double] = [A: 8, B: 4, C: -12]
        let result = TricountMin.settle(deltas: deltas)
        // C paie A et B, total = 12.
        let total = result.reduce(0) { $0 + $1.amount }
        #expect(total == 12)
        // C est toujours le payer.
        #expect(result.allSatisfy { $0.payerUserId == C })
    }
}
