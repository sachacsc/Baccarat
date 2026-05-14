//
//  OnlineRoom.swift
//  Bakarat
//
//  Modèles transportés sur le channel Realtime pour la phase Lobby.
//

import Foundation

/// Rôle du user courant dans la room.
enum OnlineRole: Equatable {
    case host
    case guest
}

/// Participant d'une room. Stable par user_id (UUID Supabase).
struct OnlineParticipant: Codable, Identifiable, Hashable {
    let userId: UUID
    var displayName: String
    var isHost: Bool
    /// Marquage UI : présence côté Realtime
    var isOnline: Bool = true

    var id: UUID { userId }
}

/// État courant de la room du point de vue du client. Le host est la source de vérité,
/// les guests reçoivent les snapshots via broadcast.
struct OnlineRoom: Codable, Equatable {
    let code: String
    /// L'hôte courant. **var** car le rôle peut être transféré en cours de
    /// partie (déco de l'hôte, ou hôte passant en spectateur).
    var hostUserId: UUID
    var participants: [OnlineParticipant]
    /// Status simplifié : 'lobby' au début, 'playing' une fois la partie lancée.
    var status: Status
    /// Prix de la ligne configuré par le host (visible en lobby, fixe pendant la partie).
    var linePrice: Double = 2.5
    /// Mode Flash : manche raccourcie (tempo réduit + auto-skip plus agressif).
    var flashMode: Bool = false
    /// Timer par annonce, en secondes (0 = désactivé, sinon countdown rolling).
    var announceTimerSeconds: Int = 0
    /// État de la manche en cours. nil tant qu'on est en lobby ou que la partie n'a pas démarré.
    var gameState: OnlineGameState?
    /// UUID Supabase de la `games` créée à la 1ère manche persistée (retourné par
    /// `record_manche`). Nil tant qu'aucune manche n'a été sauvegardée. Réutilisé
    /// pour les manches suivantes.
    var cloudGameId: UUID? = nil
    /// Historique des manches terminées (delta par joueur, gagnants par board).
    /// Visible dans le sheet "Solde & historique" depuis la toolbar de l'écran
    /// de jeu.
    var pastManches: [MancheArchive] = []

    enum Status: String, Codable {
        case lobby
        case playing
        case finished
    }

    enum CodingKeys: String, CodingKey {
        case code, hostUserId, participants, status,
             linePrice, flashMode, announceTimerSeconds, gameState, cloudGameId,
             pastManches
    }

    init(code: String,
         hostUserId: UUID,
         participants: [OnlineParticipant],
         status: Status,
         linePrice: Double = 2.5,
         flashMode: Bool = false,
         announceTimerSeconds: Int = 0,
         gameState: OnlineGameState? = nil,
         cloudGameId: UUID? = nil,
         pastManches: [MancheArchive] = []) {
        self.code = code
        self.hostUserId = hostUserId
        self.participants = participants
        self.status = status
        self.linePrice = linePrice
        self.flashMode = flashMode
        self.announceTimerSeconds = announceTimerSeconds
        self.gameState = gameState
        self.cloudGameId = cloudGameId
        self.pastManches = pastManches
    }

    // Decoding tolérant : si un client envoie un snapshot sans les nouveaux champs,
    // on tombe sur les valeurs par défaut au lieu de tout planter.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.code           = try c.decode(String.self, forKey: .code)
        self.hostUserId     = try c.decode(UUID.self,   forKey: .hostUserId)
        self.participants   = try c.decode([OnlineParticipant].self, forKey: .participants)
        self.status         = try c.decode(Status.self, forKey: .status)
        self.linePrice      = try c.decodeIfPresent(Double.self, forKey: .linePrice) ?? 2.5
        self.flashMode      = try c.decodeIfPresent(Bool.self,   forKey: .flashMode) ?? false
        self.announceTimerSeconds = try c.decodeIfPresent(Int.self, forKey: .announceTimerSeconds) ?? 0
        self.gameState      = try c.decodeIfPresent(OnlineGameState.self, forKey: .gameState)
        self.cloudGameId    = try c.decodeIfPresent(UUID.self, forKey: .cloudGameId)
        self.pastManches    = try c.decodeIfPresent([MancheArchive].self, forKey: .pastManches) ?? []
    }
}

/// Archive d'une manche terminée — gardée dans `OnlineRoom.pastManches` pour
/// l'historique affiché à l'utilisateur.
struct MancheArchive: Codable, Equatable, Identifiable {
    let mancheNumber: Int
    let dealerSeat: Int
    /// Delta de score net par seat sur cette manche.
    let perPlayerDelta: [Int: Double]
    /// Liste des boards remportés par chaque joueur (seat → [boardIdx]).
    let boardsWon: [Int: [Int]]
    /// Seat du full-board winner si applicable.
    let fullBoardWinnerSeat: Int?

    var id: Int { mancheNumber }
}

// MARK: - Messages broadcast

/// Enveloppe des messages échangés sur le channel (réutilisée par les phases suivantes).
struct OnlineMessage: Codable {
    let kind: Kind
    let payload: Payload

    enum Kind: String, Codable {
        /// Guest annonce son arrivée → host répond avec un snapshot
        case helloFromGuest
        /// Host pousse le snapshot complet de la room (broadcast régulier)
        case roomSnapshot
        /// Quelqu'un quitte volontairement (avant déconnexion forcée)
        case leave
        /// Host lance la partie
        case start
        /// Guest envoie son annonce pour le board en cours
        case submitAnnounce
        /// Guest demande à passer en spectateur (ou à rejoindre) pour la prochaine manche
        case setSpectator
    }

    enum Payload: Codable {
        case hello(userId: UUID, displayName: String)
        case snapshot(OnlineRoom)
        case leave(userId: UUID)
        case start
        case submitAnnounce(seat: Int, submission: BoardSubmission)
        case setSpectator(seat: Int, wantsToSpectate: Bool)

        // Custom encoding: tag + value (so it's resilient to future variants)
        enum CodingKeys: String, CodingKey { case t, v }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .hello(let userId, let name):
                try c.encode("hello", forKey: .t)
                try c.encode(HelloV(userId: userId, displayName: name), forKey: .v)
            case .snapshot(let room):
                try c.encode("snapshot", forKey: .t)
                try c.encode(room, forKey: .v)
            case .leave(let userId):
                try c.encode("leave", forKey: .t)
                try c.encode(LeaveV(userId: userId), forKey: .v)
            case .start:
                try c.encode("start", forKey: .t)
            case .submitAnnounce(let seat, let submission):
                try c.encode("submit", forKey: .t)
                try c.encode(SubmitV(seat: seat, submission: submission), forKey: .v)
            case .setSpectator(let seat, let wantsToSpectate):
                try c.encode("spect", forKey: .t)
                try c.encode(SpectV(seat: seat, wantsToSpectate: wantsToSpectate), forKey: .v)
            }
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let tag = try c.decode(String.self, forKey: .t)
            switch tag {
            case "hello":
                let v = try c.decode(HelloV.self, forKey: .v)
                self = .hello(userId: v.userId, displayName: v.displayName)
            case "snapshot":
                let v = try c.decode(OnlineRoom.self, forKey: .v)
                self = .snapshot(v)
            case "leave":
                let v = try c.decode(LeaveV.self, forKey: .v)
                self = .leave(userId: v.userId)
            case "start":
                self = .start
            case "submit":
                let v = try c.decode(SubmitV.self, forKey: .v)
                self = .submitAnnounce(seat: v.seat, submission: v.submission)
            case "spect":
                let v = try c.decode(SpectV.self, forKey: .v)
                self = .setSpectator(seat: v.seat, wantsToSpectate: v.wantsToSpectate)
            default:
                throw DecodingError.dataCorruptedError(forKey: .t, in: c,
                                                       debugDescription: "Unknown tag \(tag)")
            }
        }

        private struct HelloV: Codable { let userId: UUID; let displayName: String }
        private struct LeaveV: Codable { let userId: UUID }
        private struct SubmitV: Codable { let seat: Int; let submission: BoardSubmission }
        private struct SpectV: Codable { let seat: Int; let wantsToSpectate: Bool }
    }
}

// MARK: - Room code generation

enum RoomCode {
    /// Génère un code à 4 caractères majuscules + chiffres lisibles (pas de 0/O/1/I).
    static func random() -> String {
        let alphabet = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
        return String((0..<4).map { _ in alphabet.randomElement()! })
    }
}
