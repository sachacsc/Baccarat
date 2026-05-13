//
//  DebtsRootView.swift
//  Baccarat
//
//  Tab "Dettes" : balance net + liste pairwise. Toolbar trailing = avatar
//  qui ouvre la sheet "Mon profil".
//

import SwiftUI

struct DebtsRootView: View {
    @EnvironmentObject private var auth: AuthService
    @State private var showingProfile = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    Spacer().frame(height: 8)

                    // Carte "bilan net" (placeholder)
                    VStack(spacing: 4) {
                        Text("Bilan net")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textCase(.uppercase)
                            .tracking(0.5)
                        Text("+0,00 €")
                            .font(.system(size: 36, weight: .bold, design: .rounded))
                            .foregroundStyle(.green)
                    }
                    .padding(20)
                    .frame(maxWidth: .infinity)
                    .background(Color(.secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

                    VStack(spacing: 10) {
                        Image(systemName: "eurosign.circle")
                            .font(.system(size: 36))
                            .foregroundStyle(.tertiary)
                        Text("Aucune dette encore")
                            .font(.headline)
                        Text("Joue une partie pour commencer à voir ton ledger.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(.top, 30)
                }
                .padding(.horizontal, 16)
            }
            .navigationTitle("Dettes")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingProfile = true
                    } label: {
                        AvatarBubble(profile: auth.profile, size: 32)
                    }
                }
            }
            .sheet(isPresented: $showingProfile) {
                ProfileSheet()
                    .environmentObject(auth)
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            }
        }
    }
}

// MARK: - Avatar bubble (initials or image)

struct AvatarBubble: View {
    let profile: UserProfile?
    var size: CGFloat = 40

    var body: some View {
        let initial = profile.map { String($0.displayName.prefix(1)).uppercased() } ?? "?"
        ZStack {
            Circle().fill(Theme.brandGradient)
            if let urlString = profile?.avatarUrl, let url = URL(string: urlString) {
                AsyncImage(url: url) { img in
                    img.resizable().scaledToFill()
                } placeholder: {
                    Text(initial).font(.system(size: size * 0.4, weight: .bold))
                        .foregroundStyle(.white)
                }
                .clipShape(Circle())
            } else {
                Text(initial).font(.system(size: size * 0.4, weight: .bold))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: size, height: size)
        .overlay(Circle().stroke(.white, lineWidth: 1.5))
        .shadow(color: Theme.brandRed.opacity(0.18), radius: 4, y: 2)
    }
}
