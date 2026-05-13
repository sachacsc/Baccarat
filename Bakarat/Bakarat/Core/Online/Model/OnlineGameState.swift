//
//  OnlineGameState.swift
//  Bakarat
//
//  État d'une manche en cours, partagé entre tous les clients via broadcast.
//  Le host est la source de vérité — il calcule les transitions de phase et
//  fait avancer la partie. Les guests reçoivent les snapshots et envoient
//  des intents (annonces) au host.
//
//  Cette structure suit le port du web pour rester compatible avec
//  RULES.md et le scoring stocké dans manche_results.
//

import Foundation

/// Snapshot complet d'une manche en cours. Sérialisable en JSON pour broadcast.
struct OnlineGameState: Codable, Equatable {
    /// Numéro de manche (1, 2, 3...).
    let mancheNumber: Int
    /// Prix de la ligne (en €) — défini au démarrage de la partie.
    let linePrice: Double
    /// Joueurs participants à cette manche (avec leur score cumulé sur la session).
    var players: [GamePlayer]
    /// Index du donneur dans `players` (= seat de la personne qui distribue).
    var dealerSeat: Int
    /// Phase courante de la manche.
    var phase: GamePhase
    /// Board en cours (0..2). Pertinent pour annonce/reveal.
    var currentBoard: Int
    /// Round de re-bid pour le board courant (incrémenté quand tous bluffent).
    var rebidRound: Int
    /// Mains des joueurs, indexées par seat. **Seul le host voit toutes les
    /// mains** — les guests ne reçoivent que la leur dans `mySeatHand` via le
    /// snapshot filtré (Phase 2.2+). Pour la Phase 2.1, on broadcaste tout
    /// (debug) pour simplifier ; on filtrera quand on aura l'annonce.
    var hands: [Int: [Card]]
    /// Cartes brûlées (3 max). Révélées en fin de manche.
    var burns: [Card]
    var burnsRevealed: Int
    /// Cartes communautaires par board (3 × 5 in fine). Vide tant que pas
    /// révélées.
    var communityCards: [[Card]]
    /// Cartes pré-piochées pour les phases flop/turn/river (host source de
    /// vérité — diffusées dans le snapshot mais effectivement révélées seulement
    /// quand on passe `communityCards` au plein).
    var pendingFlop: [[Card]]
    var pendingTurns: [Card]
    var pendingRivers: [Card]
    /// Soumissions reçues sur le board courant, indexées par seat.
    var submissions: [Int: BoardSubmission]
    /// Résultats de chaque board (nil tant que pas résolu).
    var boardResults: [BoardResult?]
    /// Gagnant du Full Board (3 boards gagnés par la même personne).
    var fullBoardWinnerSeat: Int?
    /// Bluffeurs exclus pour le board courant (perte ferme).
    var excludedThisBoard: [Int]
}

enum GamePhase: String, Codable {
    case dealing       // distribution animée des cartes
    case flop          // flop 9 cartes révélé, on attend annonces board 1
    case announcing    // les joueurs annoncent sur le board courant
    case boardReveal   // les annonces du board courant sont révélées
    case turn          // turn révélé (3 cartes ajoutées aux boards)
    case river         // river révélé
    case mancheEnd     // résolution finale de la manche
}

struct GamePlayer: Codable, Equatable, Identifiable {
    let userId: UUID
    var displayName: String
    /// Position fixe pour cette manche (0..N-1).
    var seat: Int
    /// Score cumulé sur la session online (depuis le début de la partie).
    var score: Double
    /// Joueur actif à cette manche (false = spectateur).
    var inManche: Bool
    /// Indique si le joueur est encore connecté.
    var connected: Bool
    /// Si déconnecté en cours de manche : à partir de quel board.
    var forfeitFromBoard: Int?

    var id: UUID { userId }
}

struct BoardSubmission: Codable, Equatable {
    /// Catégorie annoncée (ID HandCategory) ou "skip".
    let categoryId: String
    /// Cartes sélectionnées (vide si skip).
    let cards: [Card]
}

struct BoardResult: Codable, Equatable {
    let board: Int
    var winnerSeat: Int?
    /// Catégorie gagnante (ID HandCategory).
    var winningCategoryId: String?
    /// Catégorie effective utilisée pour le multi de paiement (peut différer
    /// si tie-break — Phase 2.3).
    var finalMulti: Int
    var isSplit: Bool
    var splitterSeats: [Int]
    /// Résultats détaillés par joueur (pour reveal).
    var perPlayer: [PlayerBoardResult]
    /// Board abandonné : personne ne peut faire une annonce valide.
    var abandoned: Bool
}

struct PlayerBoardResult: Codable, Equatable {
    let userId: UUID
    let seat: Int
    /// Catégorie annoncée (nil = pas joué)
    let announcedCategoryId: String?
    let cards: [Card]
    let isValid: Bool
    let isBluff: Bool
    let isSkip: Bool
    let isExcluded: Bool
    let isForfeit: Bool
}
