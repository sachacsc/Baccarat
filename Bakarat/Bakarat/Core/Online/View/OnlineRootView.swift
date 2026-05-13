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
                    OnlineJoinView(
                        code: $joinCode,
                        errorMessage: service.lastError
                    ) {
                        Task { await joinGame() }
                    } onCodeChange: {
                        // Efface l'erreur dès que l'utilisateur retape
                        if service.lastError != nil { service.lastError = nil }
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
        let ok = await service.joinRoom(code: joinCode, myUserId: uid, myDisplayName: name)
        // Si le code est mal formé, on reste sur l'écran de saisie et `service.lastError`
        // affiche le message — pas de navigation vers un salon qui n'existe pas.
        guard ok else { return }
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
    var errorMessage: String? = nil
    var onSubmit: () -> Void
    var onCodeChange: (() -> Void)? = nil
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 14) {
            Spacer().frame(height: 16)

            // Badge systemGray — adapté light/dark, mêmes proportions que le badge lobby
            VStack(spacing: 6) {
                Text("Code de la partie")
                    .font(.caption2.weight(.semibold))
                    .textCase(.uppercase)
                    .tracking(1.5)
                    .foregroundStyle(.secondary)

                TextField("ABCD", text: $code)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .focused($focused)
                    .multilineTextAlignment(.center)
                    .font(.system(size: 34, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color.primary)
                    .tint(Color.primary)
                    .tracking(8)
                    .padding(.bottom, 2)
                    .onChange(of: code) { _, new in
                        let trimmed = new.uppercased().filter { $0.isLetter || $0.isNumber }
                        if trimmed != new { code = String(trimmed.prefix(4)) }
                        onCodeChange?()
                    }

                Button {
                    pasteFromClipboard()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "doc.on.clipboard")
                        Text("Coller")
                    }
                    .font(.footnote.weight(.semibold))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(
                        Capsule()
                            .fill(Color.primary.opacity(0.06))
                            .overlay(
                                Capsule()
                                    .stroke(Color.primary.opacity(0.10), lineWidth: 1)
                            )
                    )
                    .foregroundStyle(Color.primary)
                }
                .buttonStyle(.plain)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .padding(.horizontal, 16)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color(.systemGray6))
            )
            .padding(.horizontal, 16)

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

            if let err = errorMessage {
                Text(err)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 16)
            } else {
                Spacer().frame(height: 16)
            }
        }
        .navigationTitle("Rejoindre")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { focused = true }
    }

    private func pasteFromClipboard() {
        guard let clip = UIPasteboard.general.string else { return }
        let cleaned = clip.uppercased().filter { $0.isLetter || $0.isNumber }
        code = String(cleaned.prefix(4))
    }
}
