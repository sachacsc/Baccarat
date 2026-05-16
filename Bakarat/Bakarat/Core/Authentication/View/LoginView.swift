//
//  LoginView.swift
//  Baccarat
//

import SwiftUI

struct LoginView: View {
    var onTapSignUp: () -> Void
    var onTapForgot: () -> Void

    @EnvironmentObject private var auth: AuthService
    @State private var email = ""
    @State private var password = ""
    @State private var errorMessage: String?
    @State private var isSubmitting = false
    @FocusState private var focus: Field?

    enum Field { case email, password }

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 60)

            BrandLogo(size: 96)
                .padding(.bottom, 40)

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

                SecureField("Mot de passe", text: $password)
                    .textContentType(.password)
                    .focused($focus, equals: .password)
                    .submitLabel(.go)
                    .onSubmit { submit() }
                    .modifier(FormFieldStyle())
            }

            HStack {
                Spacer()
                Button("Mot de passe oublié ?", action: onTapForgot)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Theme.brandRed)
                    .padding(.top, 4)
                    .padding(.trailing, 28)
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
                        Text("Se connecter")
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
        .safeAreaInset(edge: .bottom) {
            HStack(spacing: 5) {
                Text("Pas encore de compte ?")
                    .foregroundStyle(.secondary)
                Button("S'inscrire", action: onTapSignUp)
                    .fontWeight(.semibold)
                    .foregroundStyle(Theme.brandRed)
            }
            .font(.subheadline)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity)
            .background(.regularMaterial)
            .overlay(alignment: .top) {
                Divider()
            }
        }
        .scrollDismissesKeyboard(.interactively)
    }

    private var isFormValid: Bool {
        email.contains("@") && password.count >= 6
    }

    private func submit() {
        guard isFormValid else { return }
        Task {
            isSubmitting = true
            errorMessage = nil
            do {
                try await auth.signIn(email: email.trimmingCharacters(in: .whitespaces), password: password)
            } catch {
                errorMessage = friendlyAuthMessage(error)
            }
            isSubmitting = false
        }
    }
}
