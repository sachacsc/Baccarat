//
//  OnlineRootView.swift
//  Bakarat
//
//  Tab Online : page d'accueil avec deux cards (Créer / Rejoindre). Une fois
//  une action choisie, on push un OnlineLobbyView qui couvre la tabbar
//  automatiquement (NavigationStack iOS-style).
//

import SwiftUI

struct OnlineRootView: View {
    @EnvironmentObject private var auth: AuthService
    @StateObject private var service = OnlineGameService()
    @State private var path = NavigationPath()
    @State private var joinCode = ""

    enum Route: Hashable {
        case createLobby
        case enterCode
        case joinedLobby
    }

    var body: some View {
        NavigationStack(path: $path) {
            VStack(spacing: 14) {
                Spacer().frame(height: 8)

                bigCard(
                    title: "Créer une partie",
                    description: "Tu deviens l'hôte. Donne le code à 4 caractères aux autres.",
                    systemImage: "plus",
                    primary: true,
                    action: { Task { await createGame() } }
                )

                bigCard(
                    title: "Rejoindre une partie",
                    description: "Entre le code à 4 caractères donné par l'hôte.",
                    systemImage: "arrow.right",
                    primary: false,
                    action: { path.append(Route.enterCode) }
                )

                Spacer()
            }
            .padding(.horizontal, 16)
            .navigationTitle("Partie en ligne")
            .navigationBarTitleDisplayMode(.large)
            .navigationDestination(for: Route.self) { route in
                switch route {
                case .createLobby, .joinedLobby:
                    OnlineLobbyView(service: service)
                case .enterCode:
                    OnlineJoinView(code: $joinCode) {
                        Task { await joinGame() }
                    }
                }
            }
        }
    }

    // MARK: - Actions

    private func createGame() async {
        guard let uid = auth.userId else { return }
        let name = displayName()
        await service.createRoom(myUserId: uid, myDisplayName: name)
        path.append(Route.createLobby)
    }

    private func joinGame() async {
        guard let uid = auth.userId else { return }
        let name = displayName()
        await service.joinRoom(code: joinCode, myUserId: uid, myDisplayName: name)
        joinCode = ""
        path.append(Route.joinedLobby)
    }

    private func displayName() -> String {
        if let n = auth.profile?.displayName, !n.isEmpty { return n }
        if let e = auth.userEmail, let local = e.split(separator: "@").first { return String(local) }
        return "Joueur"
    }

    // MARK: - Components

    @ViewBuilder
    private func bigCard(
        title: String,
        description: String,
        systemImage: String,
        primary: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: systemImage)
                    .font(.title3.weight(.bold))
                    .foregroundStyle(primary ? .white : Theme.brandRed)
                    .frame(width: 48, height: 48)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(primary ? Color.white.opacity(0.18) : Theme.brandRed.opacity(0.10))
                    )
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(primary ? .white : Color(.label))
                    Text(description)
                        .font(.caption)
                        .foregroundStyle(primary ? .white.opacity(0.85) : Color(.secondaryLabel))
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 6)
                Image(systemName: "chevron.right")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(primary ? .white.opacity(0.7) : Color(.tertiaryLabel))
            }
            .padding(16)
            .background(
                Group {
                    if primary {
                        Theme.brandGradient
                    } else {
                        Color(.secondarySystemBackground)
                    }
                }
            )
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .shadow(color: primary ? Theme.brandRed.opacity(0.25) : .clear, radius: 8, x: 0, y: 4)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Join code form

struct OnlineJoinView: View {
    @Binding var code: String
    var onSubmit: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 14) {
            Spacer().frame(height: 24)

            TextField("ABCD", text: $code)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .focused($focused)
                .multilineTextAlignment(.center)
                .font(.system(size: 40, weight: .bold, design: .monospaced))
                .foregroundStyle(Color(.systemBackground)) // blanc en light, noir en dark
                .tint(Color(.systemBackground))
                .tracking(8)
                .frame(maxWidth: 280)
                .padding(.vertical, 22)
                .padding(.horizontal, 16)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color.primary) // noir en light, blanc en dark
                )
                .padding(.horizontal, 16)
                .onChange(of: code) { _, new in
                    let trimmed = new.uppercased().filter { $0.isLetter || $0.isNumber }
                    if trimmed != new { code = String(trimmed.prefix(4)) }
                }

            Spacer()

            Button {
                onSubmit()
            } label: {
                Text("Rejoindre")
            }
            .modifier(PrimaryButtonStyle())
            .disabled(code.count != 4)
            .opacity(code.count == 4 ? 1 : 0.5)
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
        .navigationTitle("Rejoindre")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { focused = true }
    }
}
