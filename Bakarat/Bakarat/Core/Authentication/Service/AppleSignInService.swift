//
//  AppleSignInService.swift
//  Bakarat
//
//  Wrap ASAuthorizationController en API async pour Apple Sign-In. Génère
//  un nonce aléatoire (raw + SHA256), passe le hash à Apple, retourne le
//  raw au caller pour le forward à Supabase.
//
//  Supabase exige le RAW nonce (pas le hashé) côté `signInWithIdToken`,
//  parce qu'il refait le hash et vérifie l'égalité avec celui inclus dans
//  l'ID token JWT.
//

import Foundation
import AuthenticationServices
import CryptoKit
import UIKit

struct AppleSignInResult {
    /// JWT ID token de Apple. À forwarder à Supabase.
    let idToken: String
    /// Nonce RAW (pas hashé) — Supabase fait le SHA256 lui-même.
    let rawNonce: String
    /// `appleidentifier` stable (ASAuthorizationAppleIDCredential.user).
    let appleUserId: String
    /// Nom complet (uniquement renvoyé au PREMIER login Apple).
    let fullName: String?
    /// Email (uniquement renvoyé au PREMIER login Apple, masqué possible).
    let email: String?
}

enum AppleSignInError: LocalizedError {
    case userCancelled
    case missingIdToken
    case asAuthorizationFailed(String)

    var errorDescription: String? {
        switch self {
        case .userCancelled: return "Connexion annulée."
        case .missingIdToken: return "Apple n'a pas renvoyé d'ID token."
        case .asAuthorizationFailed(let msg): return msg
        }
    }
}

@MainActor
final class AppleSignInService: NSObject, ASAuthorizationControllerDelegate, ASAuthorizationControllerPresentationContextProviding {
    private var continuation: CheckedContinuation<AppleSignInResult, Error>?
    private var currentRawNonce: String?

    /// Lance le flow Apple Sign-In. Renvoie un AppleSignInResult ou throw.
    func signIn() async throws -> AppleSignInResult {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<AppleSignInResult, Error>) in
            self.continuation = cont
            let nonce = Self.randomNonceString()
            self.currentRawNonce = nonce

            let provider = ASAuthorizationAppleIDProvider()
            let request = provider.createRequest()
            request.requestedScopes = [.fullName, .email]
            request.nonce = Self.sha256(nonce)

            let controller = ASAuthorizationController(authorizationRequests: [request])
            controller.delegate = self
            controller.presentationContextProvider = self
            controller.performRequests()
        }
    }

    // MARK: - ASAuthorizationControllerDelegate

    nonisolated func authorizationController(controller: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization) {
        Task { @MainActor in
            guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                  let tokenData = credential.identityToken,
                  let idToken = String(data: tokenData, encoding: .utf8) else {
                continuation?.resume(throwing: AppleSignInError.missingIdToken)
                continuation = nil
                return
            }
            let rawNonce = currentRawNonce ?? ""
            let fullName: String? = {
                guard let n = credential.fullName else { return nil }
                let formatter = PersonNameComponentsFormatter()
                let s = formatter.string(from: n).trimmingCharacters(in: .whitespaces)
                return s.isEmpty ? nil : s
            }()
            let result = AppleSignInResult(
                idToken: idToken,
                rawNonce: rawNonce,
                appleUserId: credential.user,
                fullName: fullName,
                email: credential.email
            )
            continuation?.resume(returning: result)
            continuation = nil
        }
    }

    nonisolated func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
        Task { @MainActor in
            if let asErr = error as? ASAuthorizationError, asErr.code == .canceled {
                continuation?.resume(throwing: AppleSignInError.userCancelled)
            } else {
                continuation?.resume(throwing: AppleSignInError.asAuthorizationFailed(error.localizedDescription))
            }
            continuation = nil
        }
    }

    // MARK: - ASAuthorizationControllerPresentationContextProviding

    nonisolated func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        // Fallback : keyWindow de la scene active.
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        return scene?.keyWindow ?? ASPresentationAnchor()
    }

    // MARK: - Nonce helpers

    /// Génère une chaîne aléatoire alphanum (32 chars) sans caractères spéciaux.
    private static func randomNonceString(length: Int = 32) -> String {
        precondition(length > 0)
        let charset: [Character] = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz-._")
        var result = ""
        var remaining = length
        while remaining > 0 {
            var bytes = [UInt8](repeating: 0, count: 16)
            let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
            if status != errSecSuccess { fatalError("Unable to generate random bytes") }
            for byte in bytes {
                if remaining == 0 { break }
                if byte < charset.count {
                    result.append(charset[Int(byte)])
                    remaining -= 1
                }
            }
        }
        return result
    }

    private static func sha256(_ input: String) -> String {
        let data = Data(input.utf8)
        let hashed = SHA256.hash(data: data)
        return hashed.map { String(format: "%02x", $0) }.joined()
    }
}

import UIKit
