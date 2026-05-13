//
//  ProfileSheet.swift
//  Baccarat
//
//  Sheet d'édition du profil : photo, pseudo, email (read-only), déconnexion.
//  Accessible via l'avatar en haut à droite du tab Dettes.
//

import SwiftUI
import PhotosUI

struct ProfileSheet: View {
    @EnvironmentObject private var auth: AuthService
    @Environment(\.dismiss) private var dismiss

    @State private var displayName = ""
    @State private var saveError: String?
    @State private var isSaving = false
    @State private var photoItem: PhotosPickerItem?
    @State private var showSignOutConfirm = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Spacer()
                        PhotosPicker(selection: $photoItem, matching: .images, photoLibrary: .shared()) {
                            AvatarBubble(profile: auth.profile, size: 92)
                        }
                        Spacer()
                    }
                    .listRowBackground(Color.clear)
                }

                Section("Pseudo") {
                    TextField("Ton pseudo", text: $displayName)
                        .textInputAutocapitalization(.words)
                }

                Section("Email") {
                    Text(auth.userEmail ?? "—")
                        .foregroundStyle(.secondary)
                }

                if let saveError {
                    Section {
                        Text(saveError).foregroundStyle(.red).font(.caption)
                    }
                }

                Section {
                    Button(role: .destructive) {
                        showSignOutConfirm = true
                    } label: {
                        Text("Se déconnecter")
                            .frame(maxWidth: .infinity)
                    }
                }
            }
            .navigationTitle("Mon profil")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annuler") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Enregistrer", action: save)
                        .fontWeight(.semibold)
                        .disabled(displayName.trimmingCharacters(in: .whitespaces).isEmpty || isSaving)
                }
            }
            .confirmationDialog("Se déconnecter ?", isPresented: $showSignOutConfirm, titleVisibility: .visible) {
                Button("Se déconnecter", role: .destructive) {
                    Task { await auth.signOut(); dismiss() }
                }
                Button("Annuler", role: .cancel) { }
            }
            .onAppear {
                displayName = auth.profile?.displayName ?? ""
            }
            .onChange(of: photoItem) { _, newItem in
                guard let newItem else { return }
                Task { await uploadAvatar(item: newItem) }
            }
        }
    }

    // MARK: - Save / upload

    private func save() {
        let trimmed = displayName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        Task {
            isSaving = true
            saveError = nil
            do {
                try await auth.updateDisplayName(trimmed)
                dismiss()
            } catch {
                saveError = error.localizedDescription
            }
            isSaving = false
        }
    }

    private func uploadAvatar(item: PhotosPickerItem) async {
        // TODO: implement Supabase Storage upload to avatars/{user_id}/avatar.jpg
        // For now, just acknowledge the selection — the upload pipeline will be
        // implemented in the next batch (mirroring the web version's logic).
        _ = try? await item.loadTransferable(type: Data.self)
    }
}
