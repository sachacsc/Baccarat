//
//  LoginView.swift
//  Baccarat
//

import SwiftUI
import AuthenticationServices

struct LoginView: View {
    var onTapSignUp: () -> Void
    var onTapForgot: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var auth: AuthService
    @State private var email = ""
    @State private var password = ""
    @State private var errorMessage: String?
    @State private var isSubmitting = false
    @State private var appleSignIn = AppleSignInService()
    @State private var isAppleSubmitting = false
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

                SecureField("Password", text: $password)
                    .textContentType(.password)
                    .focused($focus, equals: .password)
                    .submitLabel(.go)
                    .onSubmit { submit() }
                    .modifier(FormFieldStyle())
            }

            HStack {
                Spacer()
                Button("Forgot password?", action: onTapForgot)
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
                        Text("Sign in")
                    }
                }
                .modifier(PrimaryButtonStyle())
            }
            .buttonStyle(.plain)
            .disabled(!isFormValid || isSubmitting)
            .opacity(isFormValid && !isSubmitting ? 1 : 0.5)
            .padding(.top, 18)

            // Apple Sign-In : petit rectangle noir, plus espacé du red CTA.
            Button {
                Task { await submitWithApple() }
            } label: {
                HStack(spacing: 8) {
                    if isAppleSubmitting {
                        ProgressView().tint(.white).scaleEffect(0.8)
                    } else {
                        Image(systemName: "apple.logo")
                            .font(.system(size: 16, weight: .semibold))
                    }
                    Text("Continue with Apple")
                        .font(.system(size: 15, weight: .semibold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .background(Color.black)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(isAppleSubmitting)
            .padding(.top, 36)

            Spacer()
        }
        .safeAreaInset(edge: .bottom) {
            HStack(spacing: 5) {
                Text("No account yet?")
                    .foregroundStyle(.secondary)
                Button("Sign up", action: onTapSignUp)
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

    private func submitWithApple() async {
        isAppleSubmitting = true
        errorMessage = nil
        defer { isAppleSubmitting = false }
        do {
            let result = try await appleSignIn.signIn()
            try await auth.signInWithApple(
                idToken: result.idToken,
                rawNonce: result.rawNonce,
                fullName: result.fullName
            )
        } catch AppleSignInError.userCancelled {
            // silencieux : l'user a annulé exprès
        } catch {
            errorMessage = friendlyAuthMessage(error)
        }
    }
}
