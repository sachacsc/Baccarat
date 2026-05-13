//
//  MainTabView.swift
//  Bakarat
//
//  Root TabView when signed in. Three tabs : Online · Compteur · Dettes.
//  Each tab owns its own NavigationStack so push/pop, back chevron and the
//  swipe-back gesture are all native (SwiftUI handles them).
//
//  Deployment target : iOS 18.
//   - iOS 26+ : the tab bar gets Liquid Glass automatically — no extra code.
//   - iOS 18..25 : we explicitly configure a solid translucent background so
//     the tab bar stays visible (without that, scrollEdgeAppearance can
//     render it fully transparent over scrolled content). Same pattern as
//     the Zmeo iOS app uses.
//

import SwiftUI
import UIKit

struct MainTabView: View {
    @State private var selection: AppTab = .online

    enum AppTab: Hashable {
        case online, counter, debts
    }

    init() {
        Self.configureLegacyTabBarAppearanceIfNeeded()
    }

    var body: some View {
        TabView(selection: $selection) {
            Tab("Online", systemImage: "gamecontroller", value: AppTab.online) {
                OnlineRootView()
            }

            Tab("Compteur", systemImage: "list.bullet.clipboard", value: AppTab.counter) {
                CounterRootView()
            }

            Tab("Dettes", systemImage: "eurosign.circle", value: AppTab.debts) {
                DebtsRootView()
            }
        }
        .tint(Theme.brandRed)
    }

    /// On iOS 26+ : Liquid Glass automatique, on ne touche pas à UITabBar.
    /// Avant : on force un background "translucent default" pour que la tab
    /// bar reste visible sur fond de scroll (sinon iOS 18 peut rendre la
    /// scrollEdgeAppearance complètement transparente).
    private static func configureLegacyTabBarAppearanceIfNeeded() {
        if #unavailable(iOS 26.0) {
            let appearance = UITabBarAppearance()
            appearance.configureWithDefaultBackground()
            UITabBar.appearance().standardAppearance = appearance
            UITabBar.appearance().scrollEdgeAppearance = appearance
        }
    }
}

#Preview {
    MainTabView()
        .environmentObject(AuthService())
}
