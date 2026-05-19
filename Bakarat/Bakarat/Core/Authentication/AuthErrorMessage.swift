//
//  AuthErrorMessage.swift
//  Bakarat
//
//  Map Supabase auth errors → user-friendly English messages. SwiftUI's
//  Text() will localize via Localizable.xcstrings if a French translation
//  is provided for these keys.
//

import Foundation

func friendlyAuthMessage(_ error: Error) -> String {
    let raw = error.localizedDescription.lowercased()
    if raw.contains("invalid login credentials") { return "Incorrect email or password." }
    if raw.contains("user already registered")   { return "An account already exists with this email — sign in instead." }
    if raw.contains("email not confirmed")       { return "Email not confirmed yet (check your inbox)." }
    if raw.contains("password should be at least") { return "Password must be at least 6 characters." }
    if raw.contains("network") || raw.contains("offline") { return "Network error — check your connection." }
    return error.localizedDescription
}
