//
//  OnlineGameService.swift
//  Bakarat
//
//  Service ObservableObject autour de Supabase Realtime V2. Une instance par
//  vue (créée dans OnlineRootView via @StateObject). Gère le cycle de vie du
//  channel : create/join → subscribe → broadcast → leave.
//
//  Phase 1 : lobby uniquement.
//    - Host : génère un code, ouvre `online:CODE`, se déclare participant,
//             répond aux helloFromGuest avec un snapshot.
//    - Guest : ouvre `online:CODE`, envoie helloFromGuest, attend un snapshot.
//
//  Phase 2+ : on ajoutera la propagation des actions (deal, announce, reveal,
//  tie-break) via le même channel — d'où l'enveloppe OnlineMessage extensible.
//

import Foundation
import Combine
import Supabase
import Realtime

@MainActor
final class OnlineGameService: ObservableObject {
    @Published private(set) var room: OnlineRoom?
    @Published private(set) var role: OnlineRole?
    @Published private(set) var phase: Phase = .idle
    @Published var lastError: String?

    enum Phase: Equatable {
        /// Pas encore dans une room (vue entry)
        case idle
        /// En cours d'ouverture du channel (loader)
        case connecting
        /// Connecté, en lobby (avant start)
        case lobby
        /// La partie est lancée (Phase 2+)
        case playing
        /// On a quitté ou été déco
        case left
    }

    private let client = SupabaseClientProvider.shared
    private var channel: RealtimeChannelV2?
    private var subscribeTask: Task<Void, Never>?
    private var listenerTask: Task<Void, Never>?

    // MARK: - Public API

    /// Crée une nouvelle room et devient host.
    func createRoom(myUserId: UUID, myDisplayName: String) async {
        let code = RoomCode.random()
        let me = OnlineParticipant(userId: myUserId, displayName: myDisplayName, isHost: true)
        self.role = .host
        self.room = OnlineRoom(code: code, hostUserId: myUserId, participants: [me], status: .lobby)
        await openChannel(code: code, myUserId: myUserId, myDisplayName: myDisplayName)
    }

    /// Rejoint une room existante en tant que guest.
    func joinRoom(code rawCode: String, myUserId: UUID, myDisplayName: String) async {
        let code = rawCode.uppercased().filter { $0.isLetter || $0.isNumber }
        guard code.count == 4 else {
            lastError = "Code invalide (4 caractères attendus)."
            return
        }
        self.role = .guest
        self.room = nil
        await openChannel(code: code, myUserId: myUserId, myDisplayName: myDisplayName)
    }

    /// Quitte la room (broadcast de leave + unsubscribe).
    func leave(myUserId: UUID) async {
        if let channel {
            // Best-effort leave broadcast
            try? await sendMessage(.init(kind: .leave, payload: .leave(userId: myUserId)))
            await channel.unsubscribe()
        }
        listenerTask?.cancel()
        subscribeTask?.cancel()
        channel = nil
        room = nil
        role = nil
        phase = .left
    }

    /// Host uniquement : passe la room en `.playing` et le broadcast.
    /// (Phase 2 : ce sera le départ du dealing.)
    func startGame() async {
        guard role == .host, var current = room else { return }
        current.status = .playing
        room = current
        phase = .playing
        await broadcastSnapshot()
        try? await sendMessage(.init(kind: .start, payload: .start))
    }

    // MARK: - Channel lifecycle

    private func openChannel(code: String, myUserId: UUID, myDisplayName: String) async {
        phase = .connecting
        let name = "online:\(code)"

        // Si on a déjà un channel ouvert (re-join), on nettoie d'abord
        if let existing = channel {
            await existing.unsubscribe()
        }

        let ch = client.realtimeV2.channel(name)
        self.channel = ch

        // Bind les broadcasts AVANT subscribe (sinon on peut rater le 1er message)
        listenerTask = Task { [weak self] in
            guard let self else { return }
            for await msg in ch.broadcastStream(event: "msg") {
                await self.handleIncoming(rawMessage: msg, myUserId: myUserId, myDisplayName: myDisplayName)
            }
        }

        do {
            try await ch.subscribeWithError()
            // Si host : on est seul pour l'instant, rien d'autre à faire.
            // Si guest : on annonce notre arrivée, le host répondra avec un snapshot.
            if role == .guest {
                try await sendMessage(
                    .init(kind: .helloFromGuest,
                          payload: .hello(userId: myUserId, displayName: myDisplayName))
                )
            }
            phase = .lobby
        } catch {
            lastError = "Connexion au channel impossible : \(error.localizedDescription)"
            phase = .idle
        }
    }

    private func sendMessage(_ msg: OnlineMessage) async throws {
        guard let channel else { return }
        // On encode l'OnlineMessage en JSON string puis on l'enveloppe dans une clé "p".
        // Plus simple et plus fiable que de mapper récursivement vers AnyJSON.
        let data = try JSONEncoder().encode(msg)
        let str = String(data: data, encoding: .utf8) ?? ""
        try await channel.broadcast(event: "msg", message: ["p": .string(str)])
    }

    private func handleIncoming(rawMessage: [String: AnyJSON],
                                myUserId: UUID,
                                myDisplayName: String) async {
        // Désenveloppe : on attend ["p": .string(<json>)]
        guard case .string(let payloadStr) = rawMessage["p"],
              let data = payloadStr.data(using: .utf8),
              let msg = try? JSONDecoder().decode(OnlineMessage.self, from: data) else {
            return
        }
        switch msg.payload {
        case .hello(let userId, let displayName):
            // Côté host : on ajoute le guest à la liste, on broadcast le snapshot
            guard role == .host, var current = room else { return }
            if !current.participants.contains(where: { $0.userId == userId }) {
                current.participants.append(
                    OnlineParticipant(userId: userId, displayName: displayName, isHost: false)
                )
                room = current
                await broadcastSnapshot()
            }

        case .snapshot(let snapshot):
            // Côté guest (ou rejoin) : on prend le snapshot du host
            if role == .guest {
                self.room = snapshot
            } else if role == .host {
                // Sécurité : ignore les snapshots d'un autre host (ne devrait pas arriver)
                if snapshot.hostUserId != myUserId { return }
            }

        case .leave(let userId):
            guard role == .host, var current = room else { return }
            if userId == myUserId { return } // jamais soi-même
            current.participants.removeAll { $0.userId == userId }
            room = current
            await broadcastSnapshot()

        case .start:
            // Phase 1 : on note juste que la partie démarre. Phase 2 sera étoffée.
            phase = .playing
            if var current = room {
                current.status = .playing
                room = current
            }
        }
    }

    private func broadcastSnapshot() async {
        guard let snapshot = room else { return }
        try? await sendMessage(.init(kind: .roomSnapshot, payload: .snapshot(snapshot)))
    }
}
