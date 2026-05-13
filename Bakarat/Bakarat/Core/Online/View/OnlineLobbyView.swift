//
//  OnlineLobbyView.swift
//  Bakarat
//
//  Vue Lobby : affiche le code de la partie + la liste des joueurs connectés.
//  Le host voit un bouton "Démarrer la partie", les guests voient "En attente…".
//  Quitter via le back chevron du NavigationStack (auto via SwiftUI).
//

import SwiftUI

struct OnlineLobbyView: View {
    @EnvironmentObject private var auth: AuthService
    @ObservedObject var service: OnlineGameService

    @Environment(\.dismiss) private var dismiss
    @State private var pendingStart = false
    @State private var didCallLeave = false

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                if let room = service.room {
                    codePill(room.code)
                    playerList(room.participants)

                    if service.role == .host {
                        Button(action: startGame) {
                            if pendingStart {
                                ProgressView().tint(.white)
                            } else {
                                Text("Démarrer la partie")
                            }
                        }
                        .modifier(PrimaryButtonStyle())
                        .disabled(room.participants.count < 2 || pendingStart)
                        .opacity(room.participants.count < 2 || pendingStart ? 0.5 : 1)

                        if room.participants.count < 2 {
                            Text("En attente d'au moins un autre joueur…")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Label("En attente que l'hôte démarre", systemImage: "hourglass")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .padding(.top, 6)
                    }
                } else {
                    ProgressView()
                        .padding(.top, 60)
                    Text(connectingLabel)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                if let err = service.lastError {
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 30)
                }

                Spacer()
            }
            .padding(.top, 12)
            .padding(.horizontal, 16)
        }
        .navigationTitle(service.role == .host ? "Ma partie" : "Salon")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear { performLeaveIfNeeded() }
    }

    // MARK: - Components

    @ViewBuilder
    private func codePill(_ code: String) -> some View {
        VStack(spacing: 6) {
            Text("Code de la partie")
                .font(.caption)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .tracking(0.5)

            Text(code)
                .font(.system(size: 40, weight: .bold, design: .monospaced))
                .tracking(8)
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Theme.brandRed.opacity(0.08))
                )

            Button {
                UIPasteboard.general.string = code
            } label: {
                Label("Copier", systemImage: "doc.on.doc")
                    .font(.footnote.weight(.semibold))
            }
            .tint(Theme.brandRed)
        }
        .padding(.top, 8)
    }

    @ViewBuilder
    private func playerList(_ players: [OnlineParticipant]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Joueurs")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text("\(players.count)")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 4)

            ForEach(players) { p in
                HStack(spacing: 12) {
                    Circle()
                        .fill(Theme.brandGradient)
                        .frame(width: 32, height: 32)
                        .overlay(
                            Text(String(p.displayName.prefix(1)).uppercased())
                                .font(.callout.weight(.bold))
                                .foregroundStyle(.white)
                        )
                    Text(p.displayName)
                        .font(.subheadline)
                    if p.isHost {
                        Text("HOST")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(Theme.brandRed)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(
                                Capsule().fill(Theme.brandRed.opacity(0.1))
                            )
                    }
                    Spacer()
                }
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color(.secondarySystemBackground))
                )
            }
        }
    }

    private var connectingLabel: String {
        switch service.phase {
        case .connecting: return "Connexion…"
        case .lobby:      return "Préparation du salon…"
        default:          return ""
        }
    }

    // MARK: - Actions

    private func startGame() {
        Task {
            pendingStart = true
            await service.startGame()
            pendingStart = false
        }
    }

    private func performLeaveIfNeeded() {
        guard !didCallLeave else { return }
        didCallLeave = true
        if let uid = auth.userId {
            Task { await service.leave(myUserId: uid) }
        }
    }
}
