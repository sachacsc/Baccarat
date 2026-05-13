//
//  AuthService.swift
//  Baccarat
//
//  ObservableObject around Supabase Auth. Exposes :
//   - `session` (current Supabase session, nil if signed out)
//   - `profile` (custom `profiles` row, fetched on sign-in)
//   - `isSignedIn` computed convenience
//   - signIn / signUp / signOut / sendPasswordReset / updateProfile
//
//  Listens to authStateChanges so external sign-out (token expiry, etc.) flips
//  the UI back to the gate automatically.
//

import Foundation
import Supabase

@MainActor
final class AuthService: ObservableObject {
    @Published private(set) var session: Session?
    @Published private(set) var profile: UserProfile?
    @Published var isLoading = false
    @Published var lastError: String?

    private let client = SupabaseClientProvider.shared
    private var observationTask: Task<Void, Never>?

    var isSignedIn: Bool { session != nil }

    init() {
        observeAuthChanges()
    }

    deinit {
        observationTask?.cancel()
    }

    private func observeAuthChanges() {
        observationTask = Task { [weak self] in
            guard let self else { return }
            for await (event, session) in self.client.auth.authStateChanges {
                self.session = session
                switch event {
                case .signedIn, .tokenRefreshed, .initialSession:
                    if let session {
                        await self.loadProfile(for: session.user.id)
                    }
                case .signedOut:
                    self.profile = nil
                case .passwordRecovery:
                    // Handled by the password reset screen
                    break
                default:
                    break
                }
            }
        }
    }

    func restoreSessionIfNeeded() async {
        do {
            let s = try await client.auth.session
            self.session = s
            await loadProfile(for: s.user.id)
        } catch {
            // No cached session — stay signed out
        }
    }

    // MARK: - Profile

    private func loadProfile(for userID: UUID) async {
        do {
            let row: UserProfile = try await client
                .from("profiles")
                .select()
                .eq("user_id", value: userID)
                .single()
                .execute()
                .value
            self.profile = row
        } catch {
            // Fallback : the trigger may not have populated the row yet. Retry once.
            self.profile = UserProfile(
                userId: userID,
                displayName: session?.user.email?.split(separator: "@").first.map(String.init) ?? "?",
                avatarUrl: nil,
                currency: "EUR"
            )
        }
    }

    func updateDisplayName(_ newName: String) async throws {
        guard let userID = session?.user.id else { return }
        struct Patch: Encodable { let display_name: String }
        try await client
            .from("profiles")
            .update(Patch(display_name: newName))
            .eq("user_id", value: userID)
            .execute()
        if var p = profile {
            p.displayName = newName
            profile = p
        }
    }

    // MARK: - Sign in / Sign up

    func signIn(email: String, password: String) async throws {
        isLoading = true
        defer { isLoading = false }
        try await client.auth.signIn(email: email, password: password)
    }

    func signUp(email: String, password: String) async throws {
        isLoading = true
        defer { isLoading = false }
        try await client.auth.signUp(email: email, password: password)
    }

    func signOut() async {
        do {
            try await client.auth.signOut()
        } catch {
            self.lastError = error.localizedDescription
        }
    }

    func sendPasswordReset(email: String) async throws {
        try await client.auth.resetPasswordForEmail(email)
    }
}
