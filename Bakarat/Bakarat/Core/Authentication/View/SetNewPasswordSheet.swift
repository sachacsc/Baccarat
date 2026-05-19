//
//  SetNewPasswordSheet.swift
//  Bakarat
//
//  Sheet présentée par ContentView quand AuthService.isInPasswordRecovery
//  bascule à true (après le deep link com.sacha.bakarat://auth/callback#...).
//  La session est déjà valide en mode recovery — l'utilisateur n'a qu'à
//  taper son nouveau mot de passe.
//

import SwiftUI

struct SetNewPasswordSheet: View {
    @EnvironmentObject private var auth: AuthService

    @State private var newPassword = ""
    @State private var confirm = ""
    @State private var errorMessage: String?
    @State private var isSubmitting = false
    @FocusState private var focus: Field?

    enum Field { case password, confirm }

    private var isValid: Bool {
        newPassword.count >= 8 && newPassword == confirm
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField("New password", text: $newPassword)
                        .textContentType(.newPassword)
                        .focused($focus, equals: .password)
                        .submitLabel(.next)
                        .onSubmit { focus = .confirm }
                    SecureField("Confirm", text: $confirm)
                        .textContentType(.newPassword)
                        .focused($focus, equals: .confirm)
                        .submitLabel(.go)
                        .onSubmit { if isValid { submit() } }
                } footer: {
                    Text("At least 8 characters. Once confirmed, you'll be signed in with this new password.")
                        .font(.caption)
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage).foregroundStyle(.red).font(.caption)
                    }
                }

                Section {
                    Button(action: submit) {
                        HStack {
                            if isSubmitting { ProgressView().tint(.white) }
                            Text(isSubmitting ? "Loading..." : "Update")
                                .modifier(PrimaryButtonStyle())
                        }
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                    .disabled(!isValid || isSubmitting)
                }
            }
            .navigationTitle("New password")
            .navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled(isSubmitting)
            .onAppear { focus = .password }
        }
    }

    private func submit() {
        guard isValid else { return }
        Task {
            isSubmitting = true
            errorMessage = nil
            do {
                try await auth.updatePassword(newPassword)
                // auth.isInPasswordRecovery = false → ContentView dismisse la sheet.
            } catch {
                errorMessage = friendlyAuthMessage(error)
            }
            isSubmitting = false
        }
    }
}
