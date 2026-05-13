//
//  BakaratApp.swift
//  Bakarat
//
//  Entry point. Wraps everything in the AuthService environment so any view
//  can observe `auth.session` and react to login/logout.
//

import SwiftUI

@main
struct BakaratApp: App {
    @StateObject private var auth = AuthService()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(auth)
                .task {
                    // Restore session at launch (synchronously if cached locally).
                    await auth.restoreSessionIfNeeded()
                }
        }
    }
}
