//
//  SignUpView.swift
//  Baccarat
//

import SwiftUI

struct SignUpView: View {
    @EnvironmentObject private var auth: AuthService
    @Environment(\.dismiss) private var dismiss

    @State private var email = ""
    @State private var password = ""
    @State private var passwordConfirm = ""
    @State private var errorMessage: String?
    @State private var isSubmitting = false
    @FocusState private var focus: Field?

    enum Field { case email, password, passwordConfirm }

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 40)

            BrandLogo(size: 80)
                .padding(.bottom, 16)

            Text("Créer ton compte")
                .font(.title2.weight(.bold))
                .padding(.bottom, 6)

            Text("Tu utiliseras cet email pour te connecter.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 30)
                .padding(.bottom, 16)

            VStack(spacing: 12) {
                TextField("Email", text: $email)
                    .textContentType(.emailAddress)
                    .keyboardType(.emailAddress)
                    .autocapitalization(.none)
                    .autocorrectionDisabled()
                    .focused($focus, equals: .email)
                    .submitLabel(.next)
                    .onSubmit { focus = .password }
                    .modifier(FormFieldStyle())

                SecureField("Mot de passe (6 caractères min)", text: $password)
                    .textContentType(.newPassword)
                    .focused($focus, equals: .password)
                    .submitLabel(.next)
                    .onSubmit { focus = .passwordConfirm }
                    .modifier(FormFieldStyle())

                SecureField("Confirmer le mot de passe", text: $passwordConfirm)
                    .textContentType(.newPassword)
                    .focused($focus, equals: .passwordConfirm)
                    .submitLabel(.go)
                    .onSubmit { submit() }
                    .modifier(FormFieldStyle())
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 30)
                    .padding(.top, 10)
            }

            Button(action: submit) {
                Group {
                    if isSubmitting {
                        ProgressView().tint(.white)
                    } else {
                        Text("Créer mon compte")
                    }
                }
                .modifier(PrimaryButtonStyle())
            }
            .buttonStyle(.plain)
            .disabled(!isFormValid || isSubmitting)
            .opacity(isFormValid && !isSubmitting ? 1 : 0.5)
            .padding(.top, 18)

            Spacer()
        }
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle("Inscription")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            HStack(spacing: 5) {
                Text("Déjà inscrit ?")
                    .foregroundStyle(.secondary)
                Button("Se connecter") { dismiss() }
                    .fontWeight(.semibold)
                    .foregroundStyle(Theme.brandRed)
            }
            .font(.subheadline)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity)
            .background(.regularMaterial)
            .overlay(alignment: .top) { Divider() }
        }
    }

    private var isFormValid: Bool {
        email.contains("@") && password.count >= 6 && password == passwordConfirm
    }

    private func submit() {
        guard isFormValid else { return }
        Task {
            isSubmitting = true
            errorMessage = nil
            do {
                try await auth.signUp(email: email.trimmingCharacters(in: .whitespaces), password: password)
                // Avec enable_confirmations = false côté Supabase, la session est créée
                // immédiatement → ContentView bascule sur MainTabView automatiquement.
            } catch {
                errorMessage = friendlyAuthMessage(error)
            }
            isSubmitting = false
        }
    }
}
