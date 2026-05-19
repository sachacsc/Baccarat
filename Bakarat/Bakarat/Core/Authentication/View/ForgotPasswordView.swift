//
//  ForgotPasswordView.swift
//  Baccarat
//

import SwiftUI

struct ForgotPasswordView: View {
    @EnvironmentObject private var auth: AuthService
    @Environment(\.dismiss) private var dismiss

    @State private var email = ""
    @State private var isSubmitting = false
    @State private var feedback: Feedback?

    enum Feedback {
        case sent(String)
        case error(String)
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 40)

            BrandLogo(size: 80)
                .padding(.bottom, 16)

            Text("Forgot password")
                .font(.title2.weight(.bold))
                .padding(.bottom, 6)

            Text("Enter your email and we'll send you a link to pick a new password.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 30)
                .padding(.bottom, 20)

            TextField("Email", text: $email)
                .textContentType(.emailAddress)
                .keyboardType(.emailAddress)
                .autocapitalization(.none)
                .autocorrectionDisabled()
                .submitLabel(.go)
                .onSubmit { submit() }
                .modifier(FormFieldStyle())

            if let feedback {
                switch feedback {
                case .sent(let msg):
                    Text(msg).font(.footnote).foregroundStyle(.green)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 30).padding(.top, 10)
                case .error(let msg):
                    Text(msg).font(.caption).foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 30).padding(.top, 10)
                }
            }

            Button(action: submit) {
                Group {
                    if isSubmitting { ProgressView().tint(.white) } else { Text("Send the link") }
                }
                .modifier(PrimaryButtonStyle())
            }
            .buttonStyle(.plain)
            .disabled(!email.contains("@") || isSubmitting)
            .opacity(email.contains("@") && !isSubmitting ? 1 : 0.5)
            .padding(.top, 18)

            Spacer()
        }
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle("Forgot password")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func submit() {
        Task {
            isSubmitting = true
            feedback = nil
            do {
                try await auth.sendPasswordReset(email: email.trimmingCharacters(in: .whitespaces))
                feedback = .sent("✓ Link sent to \(email).\nCheck your inbox (and spam folder).")
            } catch {
                feedback = .error(friendlyAuthMessage(error))
            }
            isSubmitting = false
        }
    }
}
