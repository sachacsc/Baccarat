//
//  OnlineRootView.swift
//  Baccarat
//
//  Tab "Online" : page d'accueil avec deux cards Créer/Rejoindre.
//  Push vers Lobby ou Join (couvre la tabbar automatiquement via NavigationStack).
//

import SwiftUI

struct OnlineRootView: View {
    @State private var path = NavigationPath()
    @State private var joinCode = ""

    enum Route: Hashable {
        case createLobby
        case enterCode
        case joinedLobby(code: String)
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
                    action: { path.append(Route.createLobby) }
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
                case .createLobby:
                    OnlineLobbyView(role: .host)
                case .enterCode:
                    OnlineJoinView(code: $joinCode) { code in
                        path.append(Route.joinedLobby(code: code))
                    }
                case .joinedLobby(let code):
                    OnlineLobbyView(role: .guest(code: code))
                }
            }
        }
    }

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

// MARK: - Placeholders (to be filled out next batches)

struct OnlineLobbyView: View {
    enum Role: Hashable {
        case host
        case guest(code: String)
    }
    let role: Role

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("Lobby — à implémenter")
                .font(.headline)
            Text(roleLabel)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.top, 40)
        .navigationTitle(roleLabel)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var roleLabel: String {
        switch role {
        case .host:                return "Hôte"
        case .guest(let code):     return "Code \(code)"
        }
    }
}

struct OnlineJoinView: View {
    @Binding var code: String
    var onJoined: (String) -> Void

    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 20) {
            Spacer().frame(height: 24)

            Text("Code à 4 caractères")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            TextField("ABCD", text: $code)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .focused($focused)
                .multilineTextAlignment(.center)
                .font(.system(size: 36, weight: .bold, design: .monospaced))
                .frame(maxWidth: 240)
                .padding(.vertical, 14)
                .background(Color(.systemGray6))
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .onChange(of: code) { _, new in
                    let trimmed = new.uppercased().filter { $0.isLetter || $0.isNumber }
                    if trimmed != new { code = String(trimmed.prefix(4)) }
                }

            Button {
                onJoined(code)
            } label: {
                Text("Rejoindre")
            }
            .modifier(PrimaryButtonStyle())
            .disabled(code.count != 4)
            .opacity(code.count == 4 ? 1 : 0.5)

            Spacer()
        }
        .navigationTitle("Rejoindre")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { focused = true }
    }
}
