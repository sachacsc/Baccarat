//
//  UserProfile.swift
//  Baccarat
//
//  Mirror of the `public.profiles` table.
//

import Foundation

struct UserProfile: Codable, Identifiable, Equatable {
    let userId: UUID
    var displayName: String
    var avatarUrl: String?
    var currency: String

    var id: UUID { userId }

    enum CodingKeys: String, CodingKey {
        case userId = "user_id"
        case displayName = "display_name"
        case avatarUrl = "avatar_url"
        case currency
    }
}
