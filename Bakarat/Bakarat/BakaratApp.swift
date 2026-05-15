//
//  BakaratApp.swift
//  Bakarat
//
//  Entry point. Wraps everything in the AuthService environment so any view
//  can observe `auth.session` and react to login/logout.
//

import SwiftUI
import SwiftData

@main
struct BakaratApp: App {
    @StateObject private var auth = AuthService()

    /// Container SwiftData (compteurs locaux). Recréé à la volée si l'init
    /// throw — un wipe & recreate vaut mieux qu'un crash de l'app au launch.
    private let modelContainer: ModelContainer = {
        let schema = Schema([
            Counter.self,
            CounterPlayer.self,
            CounterManche.self,
        ])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        do {
            return try ModelContainer(for: schema, configurations: [config])
        } catch {
            print("[SwiftData] container init failed: \(error). Falling back to in-memory.")
            let memConfig = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
            return try! ModelContainer(for: schema, configurations: [memConfig])
        }
    }()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(auth)
                .task {
                    // Restore session at launch (synchronously if cached locally).
                    await auth.restoreSessionIfNeeded()
                }
        }
        .modelContainer(modelContainer)
    }
}
