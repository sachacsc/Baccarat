//
//  SupabaseClientProvider.swift
//  Baccarat
//
//  Shared Supabase client instance. Used by every service (Auth, Counter, Online,
//  Debts). The official supabase-swift SDK already manages session persistence
//  via Keychain when configured to do so.
//

import Foundation
import Supabase

enum SupabaseClientProvider {
    static let shared: SupabaseClient = {
        SupabaseClient(
            supabaseURL: SupabaseConfig.url,
            supabaseKey: SupabaseConfig.anonKey
        )
    }()
}
