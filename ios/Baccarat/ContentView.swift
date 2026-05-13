//
//  ContentView.swift
//  Baccarat
//
//  Top-level switch : auth gate when no session, MainTabView when signed in.
//  All animations are SwiftUI-native (cross-fade between states).
//

import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var auth: AuthService

    var body: some View {
        Group {
            if auth.isSignedIn {
                MainTabView()
                    .transition(.opacity.combined(with: .move(edge: .trailing)))
            } else {
                AuthGateView()
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: auth.isSignedIn)
    }
}
