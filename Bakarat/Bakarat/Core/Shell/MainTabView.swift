//
//  MainTabView.swift
//  Baccarat
//
//  Root TabView when signed in. Three tabs : Online · Compteur · Dettes.
//  Each tab owns its own NavigationStack so push/pop is iOS-native (including
//  the swipe-back gesture). On iOS 26+ the tab bar gets the Liquid Glass
//  treatment for free.
//

import SwiftUI

struct MainTabView: View {
    @State private var selection: Tab = .online

    enum Tab: Hashable {
        case online, counter, debts
    }

    var body: some View {
        TabView(selection: $selection) {
            OnlineRootView()
                .tabItem {
                    Label("Online", systemImage: "gamecontroller")
                }
                .tag(Tab.online)

            CounterRootView()
                .tabItem {
                    Label("Compteur", systemImage: "list.bullet.clipboard")
                }
                .tag(Tab.counter)

            DebtsRootView()
                .tabItem {
                    Label("Dettes", systemImage: "eurosign.circle")
                }
                .tag(Tab.debts)
        }
        .tint(Theme.brandRed)
    }
}

#Preview {
    MainTabView()
        .environmentObject(AuthService())
}
