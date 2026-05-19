//
//  NotificationService.swift
//  Bakarat
//
//  Demande la permission, register pour APNs, capture le device token via
//  AppDelegate proxy et le pousse à Supabase via la RPC `register_device_token`.
//
//  IMPORTANT (setup Apple Developer + Supabase, à faire manuellement) :
//   1. Apple Developer Portal : activer la capability "Push Notifications"
//      sur l'App ID com.sacha.Bakarat.
//   2. Apple Developer Portal : générer une APNs Auth Key (.p8), noter
//      Key ID + Team ID.
//   3. Stocker les credentials côté Supabase (Edge Function env vars) :
//      APNS_KEY_ID, APNS_TEAM_ID, APNS_KEY_P8 (contenu du .p8), APNS_BUNDLE_ID.
//   4. Déployer la fonction `supabase/functions/notify_settlement/`.
//   5. Créer un trigger Postgres sur `game_pair_settlements` INSERT/UPDATE
//      qui POST vers l'Edge Function via pg_net (voir le README de la function).
//
//  Pour PRODUCTION : changer `aps-environment` dans Bakarat.entitlements
//  de "development" à "production" avant l'archive de release.
//

import Foundation
import Combine
import UIKit
import UserNotifications
import Supabase

@MainActor
final class NotificationService: ObservableObject {
    static let shared = NotificationService()

    @Published private(set) var permissionStatus: UNAuthorizationStatus = .notDetermined
    @Published private(set) var lastError: String?

    private init() {}

    /// Demande la permission utilisateur ET lance le register APNs si accordé.
    /// Idempotent — safe à appeler à chaque foreground.
    func requestAuthorizationAndRegister() async {
        do {
            let granted = try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .badge, .sound])
            await refreshStatus()
            if granted {
                await MainActor.run {
                    UIApplication.shared.registerForRemoteNotifications()
                }
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    func refreshStatus() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        await MainActor.run { self.permissionStatus = settings.authorizationStatus }
    }

    /// Appelé par AppDelegate quand iOS livre le device token.
    func handleDeviceToken(_ deviceToken: Data) async {
        let hex = deviceToken.map { String(format: "%02x", $0) }.joined()
        struct Params: Encodable {
            let p_token: String
            let p_platform: String
        }
        do {
            try await SupabaseClientProvider.shared
                .rpc("register_device_token", params: Params(p_token: hex, p_platform: "ios"))
                .execute()
            #if DEBUG
            print("[Notifications] token registered: \(hex.prefix(8))…")
            #endif
        } catch {
            #if DEBUG
            print("[Notifications] register failed: \(error)")
            #endif
        }
    }

    /// À appeler avant signOut() pour libérer le token côté Supabase.
    func unregisterCurrentToken(_ token: String) async {
        struct Params: Encodable { let p_token: String }
        try? await SupabaseClientProvider.shared
            .rpc("unregister_device_token", params: Params(p_token: token))
            .execute()
    }
}

// MARK: - AppDelegate proxy

/// Pont entre UIKit (UIApplicationDelegate) et SwiftUI App. Capture les
/// callbacks didRegisterForRemoteNotifications + failed pour les rediriger
/// vers NotificationService.
final class BakaratAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        Task { @MainActor in
            await NotificationService.shared.handleDeviceToken(deviceToken)
        }
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        #if DEBUG
        print("[Notifications] APNs registration failed: \(error)")
        #endif
    }
}
