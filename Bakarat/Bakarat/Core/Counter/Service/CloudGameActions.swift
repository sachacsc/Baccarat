//
//  CloudGameActions.swift
//  Bakarat
//
//  Wrappers Swift autour des RPCs Supabase de suppression / leave game.
//  Stateless, appelables depuis n'importe quelle vue qui veut effacer une
//  session du carnet de comptes.
//

import Foundation
import Supabase

enum CloudGameActions {

    /// Owner only : supprime le game et tout ce qui en dépend (cascade).
    static func deleteGame(gameId: UUID) async throws {
        struct Params: Encodable { let p_game_id: UUID }
        try await SupabaseClientProvider.shared
            .rpc("delete_game", params: Params(p_game_id: gameId))
            .execute()
    }

    /// Participant non-owner : retire le caller du game et supprime ses
    /// settlements pour ce game. Le game reste vivant pour les autres.
    static func leaveGame(gameId: UUID) async throws {
        struct Params: Encodable { let p_game_id: UUID }
        try await SupabaseClientProvider.shared
            .rpc("leave_game", params: Params(p_game_id: gameId))
            .execute()
    }
}
