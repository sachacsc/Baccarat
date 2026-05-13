//
//  AuthGateView.swift
//  Baccarat
//
//  Switch between Login and Signup views with a NavigationStack-style push.
//  Wraps both in a fullscreen container — no chrome, just the form.
//

import SwiftUI

struct AuthGateView: View {
    @State private var path: [AuthRoute] = []

    enum AuthRoute: Hashable {
        case signUp
        case forgotPassword
    }

    var body: some View {
        NavigationStack(path: $path) {
            LoginView(
                onTapSignUp: { path.append(.signUp) },
                onTapForgot: { path.append(.forgotPassword) }
            )
            .navigationDestination(for: AuthRoute.self) { route in
                switch route {
                case .signUp:
                    SignUpView()
                case .forgotPassword:
                    ForgotPasswordView()
                }
            }
        }
        .tint(Theme.brandRed)
    }
}

#Preview {
    AuthGateView().environmentObject(AuthService())
}
