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
    let hostUserId: UUID
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

    enum Status: String, Codable {
        case lobby
        case playing
        case finished
    }

    enum CodingKeys: String, CodingKey {
        case code, hostUserId, participants, status,
             linePrice, flashMode, announceTimerSeconds, gameState
    }

    init(code: String,
         hostUserId: UUID,
         participants: [OnlineParticipant],
         status: Status,
         linePrice: Double = 2.5,
         flashMode: Bool = false,
         announceTimerSeconds: Int = 0,
         gameState: OnlineGameState? = nil) {
        self.code = code
        self.hostUserId = hostUserId
        self.participants = participants
        self.status = status
        self.linePrice = linePrice
        self.flashMode = flashMode
        self.announceTimerSeconds = announceTimerSeconds
        self.gameState = gameState
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
    }
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
    }

    enum Payload: Codable {
        case hello(userId: UUID, displayName: String)
        case snapshot(OnlineRoom)
        case leave(userId: UUID)
        case start
        case submitAnnounce(seat: Int, submission: BoardSubmission)

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
            default:
                throw DecodingError.dataCorruptedError(forKey: .t, in: c,
                                                       debugDescription: "Unknown tag \(tag)")
            }
        }

        private struct HelloV: Codable { let userId: UUID; let displayName: String }
        private struct LeaveV: Codable { let userId: UUID }
        private struct SubmitV: Codable { let seat: Int; let submission: BoardSubmission }
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
