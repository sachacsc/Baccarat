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
    @StateObject private var historyService = OnlineHistoryService()
    @State private var path = NavigationPath()
    @State private var joinCode = ""
    /// Partie host interrompue qu'on propose de reprendre (chargée au appear).
    @State private var resumableRoom: OnlineRoom? = nil
    /// Lock pour empêcher la double-création d'un salon en cas de tap rapide.
    @State private var isCreatingGame = false

    enum Route: Hashable {
        case createLobby
        case enterCode
        case joinedLobby
        case history
    }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                actionsSection
                if let resumable = resumableRoom {
                    resumeBannerSection(resumable)
                }
                historySectionList
            }
            .listStyle(.insetGrouped)
            .onAppear {
                resumableRoom = OnlineGameService.loadResumableHostState()
            }
            .task {
                if let uid = auth.userId {
                    await historyService.load(myUserId: uid)
                    await historyService.startLiveUpdates(myUserId: uid)
                }
            }
            // Au pop d'une partie/lobby on rafraîchit explicitement (au cas
            // où le live update a manqué un event — best-effort).
            .onChange(of: path.count) { _, newCount in
                guard newCount == 0 else { return }
                resumableRoom = OnlineGameService.loadResumableHostState()
                if let uid = auth.userId {
                    Task { await historyService.load(myUserId: uid) }
                }
            }
            .onDisappear {
                Task { await historyService.stopLiveUpdates() }
            }
            .refreshable {
                if let uid = auth.userId {
                    await historyService.load(myUserId: uid)
                }
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    BrandLogo(size: 30)
                }
            }
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
                        if service.lastError != nil { service.lastError = nil }
                    }
                case .history:
                    OnlineHistoryView(injectedService: historyService)
                }
            }
        }
    }

    // MARK: - Actions section (Créer above Rejoindre, native List rows)

    @ViewBuilder
    private var actionsSection: some View {
        Section {
            Button {
                Task { await createGame() }
            } label: {
                actionRowContent(
                    title: isCreatingGame ? "Création du salon…" : "Créer une partie",
                    subtitle: "Donne le code aux autres",
                    systemImage: "plus.circle.fill",
                    onPrimary: true
                )
            }
            .buttonStyle(.plain)
            .disabled(isCreatingGame)
            .listRowBackground(Theme.brandGradient)
            .listRowInsets(EdgeInsets(top: 14, leading: 16, bottom: 14, trailing: 16))
            .listRowSeparator(.hidden)

            Button {
                path.append(Route.enterCode)
            } label: {
                actionRowContent(
                    title: "Rejoindre une partie",
                    subtitle: "Entre le code à 4 caractères de l'hôte",
                    systemImage: "arrow.right.circle.fill",
                    onPrimary: false
                )
            }
            .buttonStyle(.plain)
            .listRowInsets(EdgeInsets(top: 14, leading: 16, bottom: 14, trailing: 16))
        }
    }

    @ViewBuilder
    private func actionRowContent(
        title: String,
        subtitle: String,
        systemImage: String,
        onPrimary: Bool
    ) -> some View {
        HStack(spacing: 14) {
            Image(systemName: systemImage)
                .font(.system(size: 28, weight: .bold))
                .foregroundStyle(onPrimary ? .white : Theme.brandRed)
                .frame(width: 44, height: 44)
                .background(
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(onPrimary
                              ? Color.white.opacity(0.18)
                              : Theme.brandRed.opacity(0.10))
                )
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline.weight(.bold))
                    .foregroundStyle(onPrimary ? .white : Color.primary)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(onPrimary ? .white.opacity(0.85) : Color.secondary)
                    .lineLimit(2)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(onPrimary ? Color.white.opacity(0.7) : Color(.tertiaryLabel))
        }
        .contentShape(Rectangle())
    }

    // MARK: - Resume banner section

    @ViewBuilder
    private func resumeBannerSection(_ room: OnlineRoom) -> some View {
        Section {
            resumeBanner(room)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                .listRowSeparator(.hidden)
        }
    }

    // MARK: - History section

    @ViewBuilder
    private var historySectionList: some View {
        Section {
            historyContent
        } header: {
            HStack {
                Text("Historique")
                Spacer()
                if showBilan {
                    Text("Bilan : \(formatBalance(totalBalance, currency: historyService.games.first?.currency ?? "EUR"))")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(balanceColor(totalBalance))
                        .textCase(.none)
                }
            }
        }
    }

    @ViewBuilder
    private var historyContent: some View {
        if historyService.isLoading && historyService.games.isEmpty {
            HStack {
                Spacer()
                ProgressView()
                Spacer()
            }
            .padding(.vertical, 8)
        } else if historyService.games.isEmpty {
            VStack(spacing: 6) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.title2)
                    .foregroundStyle(.tertiary)
                Text("Aucune partie pour l'instant")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text("Tes parties online apparaîtront ici")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 18)
            .listRowSeparator(.hidden)
        } else {
            ForEach(Array(historyService.games.prefix(5))) { game in
                historyRow(game)
                    .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16))
            }
            Button {
                path.append(Route.history)
            } label: {
                HStack(spacing: 5) {
                    Spacer()
                    Text("Voir plus")
                    Image(systemName: "arrow.right")
                        .font(.caption.weight(.bold))
                    Spacer()
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.brandRed)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
        }
    }

    @ViewBuilder
    private func historyRow(_ game: GameHistoryItem) -> some View {
        HStack(spacing: 10) {
            Circle()
                .fill(game.isOngoing ? Color.green : Color.clear)
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(dateLabel(game))
                    .font(.subheadline.weight(.semibold))
                Text(subtitle(for: game))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(formatBalance(game.myBalance, currency: game.currency))
                .font(.subheadline.weight(.bold).monospacedDigit())
                .foregroundStyle(balanceColor(game.myBalance))
        }
    }

    /// Cache le bilan quand il n'y a pas de parties OU quand le total est nul.
    private var showBilan: Bool {
        !historyService.games.isEmpty && abs(totalBalance) >= 0.005
    }

    // MARK: - Helpers

    private var totalBalance: Double {
        historyService.games.reduce(0) { $0 + $1.myBalance }
    }

    private func dateLabel(_ g: GameHistoryItem) -> String {
        let date = g.lastMancheAt ?? g.createdAt
        return date.formatted(.dateTime.weekday(.abbreviated).hour().minute())
    }

    private func subtitle(for g: GameHistoryItem) -> String {
        var parts: [String] = []
        if g.numParticipants > 0 {
            parts.append("\(g.numParticipants) joueur\(g.numParticipants > 1 ? "s" : "")")
        }
        if g.numManches > 0 {
            parts.append("\(g.numManches) manche\(g.numManches > 1 ? "s" : "")")
        }
        return parts.joined(separator: " · ")
    }

    private func formatBalance(_ v: Double, currency: String) -> String {
        let sym = currencySymbol(currency)
        if abs(v) < 0.005 { return "0 \(sym)" }
        let sign = v > 0 ? "+" : "−"
        return "\(sign)\(String(format: "%.2f", abs(v))) \(sym)"
    }

    private func currencySymbol(_ c: String) -> String {
        switch c.uppercased() {
        case "EUR": return "€"
        case "USD": return "$"
        case "GBP": return "£"
        case "CHF": return "CHF"
        default:    return c
        }
    }

    private func balanceColor(_ v: Double) -> Color {
        if abs(v) < 0.005 { return .secondary }
        return v > 0 ? .green : .red
    }

    // MARK: - Actions

    private func createGame() async {
        guard !isCreatingGame else { return }
        guard let uid = auth.userId else { return }
        isCreatingGame = true
        defer { isCreatingGame = false }
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

    // MARK: - Resume banner

    @ViewBuilder
    private func resumeBanner(_ room: OnlineRoom) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.clockwise.circle.fill")
                .font(.title2)
                .foregroundStyle(Theme.brandRed)
            VStack(alignment: .leading, spacing: 2) {
                Text("Partie en cours")
                    .font(.subheadline.weight(.semibold))
                let manche = room.gameState?.mancheNumber ?? 1
                Text("Code \(room.code) · Manche \(manche)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                Task { await resumeGame(room) }
            } label: {
                Text("Reprendre")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(Capsule().fill(Theme.brandRed))
            }
            .buttonStyle(.plain)
            Button {
                OnlineGameService.clearResumableHostState()
                resumableRoom = nil
            } label: {
                Image(systemName: "xmark")
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Theme.brandRed.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Theme.brandRed.opacity(0.20), lineWidth: 1)
                )
        )
    }

    private func resumeGame(_ room: OnlineRoom) async {
        guard let uid = auth.userId else { return }
        let name = displayName()
        resumableRoom = nil
        await service.resumeAsHost(savedRoom: room, myUserId: uid, myDisplayName: name)
        path.append(Route.createLobby)
    }

    // MARK: - Components

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
                    .modifier(PrimaryButtonStyle())
            }
            .buttonStyle(.plain)
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
