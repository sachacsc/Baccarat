//
//  JoinByCodeSheet.swift
//  Bakarat
//
//  Flow "Rejoindre un compteur" en deux étapes :
//   1. Saisie du code (6 chars, format affiché "ABC-DEF")
//   2. Sélection du siège dans la liste retournée par lookup_share_code
//
//  Si l'utilisateur n'est pas connecté au moment du claim, on lui propose 3
//  options : se connecter, créer un compte, ou continuer en tant qu'invité
//  (compte anonyme auto-créé). Dans tous les cas le claim suit immédiatement
//  après l'auth.
//

import SwiftUI

struct JoinByCodeSheet: View {
    @EnvironmentObject private var auth: AuthService
    @Environment(\.dismiss) private var dismiss

    /// Code pré-rempli quand on entre via deep link (com.sacha.bakarat://join/XYZ).
    /// On lance immédiatement le lookup et on saute à l'étape pickSeat.
    let prefilledCode: String?

    init(prefilledCode: String? = nil) {
        self.prefilledCode = prefilledCode
    }

    enum Step: Equatable {
        case enterCode
        case pickSeat
        case success(claimedSeat: SharedGameSeat)
    }

    @State private var step: Step = .enterCode
    @State private var codeInput: String = ""
    @State private var seats: [SharedGameSeat] = []
    @State private var pendingSeatIndex: Int?

    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var showAnonOption = false   // si claim échoue car non loggé

    @FocusState private var codeFocused: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                switch step {
                case .enterCode:           enterCodeView
                case .pickSeat:            pickSeatView
                case .success(let seat):   successView(seat: seat)
                }
            }
            .navigationTitle(navTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if case .pickSeat = step {
                        Button("Code") { step = .enterCode }
                            .tint(Theme.brandRed)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Close") { dismiss() }
                        .tint(Theme.brandRed)
                }
            }
            .alert("Action unavailable", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) { errorMessage = nil }
            } message: { Text(errorMessage ?? "") }
            .confirmationDialog("You're not signed in", isPresented: $showAnonOption, titleVisibility: .visible) {
                Button("Continue as guest") {
                    Task { await signInAnonAndClaim() }
                }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("You can create a temporary account (no email) to claim your seat right now. You'll be able to link it to an email later from your profile.")
            }
        }
    }

    private var navTitle: String {
        switch step {
        case .enterCode:    return "Join"
        case .pickSeat:     return "Pick your seat"
        case .success:      return "Joined!"
        }
    }

    // MARK: - Step 1 : code

    private var enterCodeView: some View {
        VStack(spacing: 20) {
            Spacer().frame(height: 20)

            Text("Enter the 6-character code")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            TextField("ABC-DEF", text: $codeInput)
                .font(.system(size: 32, weight: .bold, design: .rounded))
                .monospaced()
                .tracking(3)
                .multilineTextAlignment(.center)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled(true)
                .focused($codeFocused)
                .padding(.vertical, 18)
                .background(Color(.systemGray6))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .padding(.horizontal, 30)
                .onChange(of: codeInput) { _, new in
                    let normalized = CounterShareService.normalize(new)
                    if normalized.count <= 6 {
                        // re-format avec tiret au milieu
                        let display = CounterShareService.formatForDisplay(normalized)
                        if display != new { codeInput = display }
                    } else {
                        codeInput = CounterShareService.formatForDisplay(String(normalized.prefix(6)))
                    }
                }

            Button {
                Task { await lookup() }
            } label: {
                HStack {
                    if isLoading { ProgressView().tint(.white) }
                    Text(isLoading ? "Searching…" : "Continue").modifier(PrimaryButtonStyle())
                }
            }
            .disabled(isLoading || CounterShareService.normalize(codeInput).count != 6)

            Spacer()
        }
        .onAppear {
            if let pre = prefilledCode, !pre.isEmpty {
                codeInput = CounterShareService.formatForDisplay(pre)
                Task { await lookup() }
            } else {
                codeFocused = true
            }
        }
    }

    private func lookup() async {
        let normalized = CounterShareService.normalize(codeInput)
        guard normalized.count == 6 else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let result = try await CounterShareService.lookup(shareCode: normalized)
            seats = result
            step = .pickSeat
            codeFocused = false
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Step 2 : seat picker

    private var pickSeatView: some View {
        ScrollView {
            VStack(spacing: 14) {
                if let first = seats.first {
                    summaryHeader(first)
                }
                seatList
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 24)
        }
    }

    private func summaryHeader(_ s: SharedGameSeat) -> some View {
        VStack(spacing: 6) {
            Text("\(s.ownerDisplay ?? "—")'s counter")
                .font(.headline)
            HStack(spacing: 4) {
                Image(systemName: s.mode == "online" ? "gamecontroller.fill" : "list.bullet.clipboard.fill")
                Text(s.mode == "online" ? "Online game" : "Counter")
                    .font(.subheadline)
                Text("·")
                Text("\(String(format: "%.2f", s.linePrice)) \(s.currency)/line")
                    .font(.subheadline)
            }
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var seatList: some View {
        VStack(spacing: 0) {
            ForEach(Array(seats.enumerated()), id: \.element.id) { idx, s in
                seatRow(s)
                if idx < seats.count - 1 {
                    Divider().padding(.leading, 60)
                }
            }
        }
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func seatRow(_ s: SharedGameSeat) -> some View {
        let isMine = (s.claimedByUserId != nil && s.claimedByUserId == auth.userId)
        let isClaimable = !s.isClaimed
        return HStack(spacing: 12) {
            ProfileAvatar(
                name: s.claimedByDisplay ?? s.guestName ?? "?",
                avatarUrl: s.claimedByAvatar,
                size: 36
            )
            .opacity(s.isClaimed ? 1.0 : 0.55)

            VStack(alignment: .leading, spacing: 2) {
                Text(s.guestName ?? "Seat \(s.seatIndex + 1)")
                    .font(.system(size: 16, weight: .semibold))
                if isMine {
                    Text("You")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.brandRed)
                } else if let claimed = s.claimedByDisplay {
                    Text("Taken by \(claimed)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Available")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
            }
            Spacer()

            if isClaimable {
                Button {
                    Task { await claim(seatIndex: s.seatIndex) }
                } label: {
                    Text(isLoading && pendingSeatIndex == s.seatIndex ? "…" : "That's me")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(Theme.brandGradient)
                        .clipShape(Capsule())
                }
                .disabled(isLoading)
            } else if isMine {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.title3)
            } else {
                Image(systemName: "lock.fill")
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    // MARK: - Claim

    private func claim(seatIndex: Int) async {
        guard let first = seats.first else { return }
        pendingSeatIndex = seatIndex
        defer { pendingSeatIndex = nil }

        // Si le user n'est pas connecté → propose le compte anonyme.
        guard auth.isSignedIn else {
            showAnonOption = true
            return
        }

        await performClaim(shareCodeFromSeats: first, seatIndex: seatIndex)
    }

    private func signInAnonAndClaim() async {
        guard let first = seats.first, let idx = pendingSeatIndex else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            try await auth.signInAnonymously()
            await performClaim(shareCodeFromSeats: first, seatIndex: idx)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func performClaim(shareCodeFromSeats first: SharedGameSeat, seatIndex: Int) async {
        let code = CounterShareService.normalize(codeInput)
        isLoading = true
        defer { isLoading = false }
        do {
            _ = try await CounterShareService.claim(shareCode: code, seatIndex: seatIndex)
            // Refresh local view + pass to success step
            let updated = try await CounterShareService.lookup(shareCode: code)
            seats = updated
            if let mine = updated.first(where: { $0.seatIndex == seatIndex }) {
                step = .success(claimedSeat: mine)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Step 3 : success

    private func successView(seat: SharedGameSeat) -> some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 64))
                .foregroundStyle(.green)
            Text("Seat claimed")
                .font(.title2.weight(.bold))
            Text("You now play as **\(seat.guestName ?? "—")** on \(seat.ownerDisplay ?? "—")'s counter. Your wins and losses will appear in your Accounts after each round.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 30)

            if auth.isAnonymous {
                Text("Guest account active. Link it to an email from your profile so you don't lose access.")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 30)
                    .padding(.top, 8)
            }

            Spacer()

            Button { dismiss() } label: {
                Text("Done").modifier(PrimaryButtonStyle())
            }
            .padding(.bottom, 20)
        }
    }
}
