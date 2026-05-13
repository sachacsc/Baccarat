//
//  AuthErrorMessage.swift
//  Baccarat
//
//  Map Supabase auth errors → user-friendly French messages. Mirrors the
//  gateErrorMessage() helper in the web version.
//

import Foundation

func friendlyAuthMessage(_ error: Error) -> String {
    let raw = error.localizedDescription.lowercased()
    if raw.contains("invalid login credentials") { return "Email ou mot de passe incorrect." }
    if raw.contains("user already registered")   { return "Un compte existe déjà avec cet email — connecte-toi plutôt." }
    if raw.contains("email not confirmed")       { return "Email pas encore confirmé (vérifie ta boîte mail)." }
    if raw.contains("password should be at least") { return "Le mot de passe doit faire au moins 6 caractères." }
    if raw.contains("network") || raw.contains("offline") { return "Erreur réseau — vérifie ta connexion." }
    return error.localizedDescription
}
