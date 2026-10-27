import SwiftUI

/// The first screen: log in, or make an account, with a username and password.
struct LoginView: View {
    @ObservedObject var account: Account
    @State private var username = ""
    @State private var password = ""
    @State private var creating = false
    @State private var busy = false
    @State private var message: String?

    var body: some View {
        VStack(spacing: 18) {
            Spacer()
            Image(systemName: "cube.transparent")
                .font(.system(size: 56))
            Text("RoomTwin")
                .font(.largeTitle.bold())
            Text(creating ? "Make an account to save the objects you scan." : "Log in to scan and furnish your room.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            VStack(spacing: 10) {
                TextField("Username", text: $username)
                    .textContentType(.username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField("Password", text: $password)
                    .textContentType(creating ? .newPassword : .password)
                    .onSubmit(submit)
            }
            .textFieldStyle(.roundedBorder)
            .frame(maxWidth: 340)
            if let message {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
            }
            Button(action: submit) {
                Group {
                    if busy { ProgressView() } else { Text(creating ? "Create Account" : "Log In") }
                }
                .frame(maxWidth: 340, minHeight: 32)
            }
            .buttonStyle(.borderedProminent)
            .disabled(busy || username.isEmpty || password.isEmpty)
            Button(creating ? "Have an account? Log in" : "New here? Create an account") {
                creating.toggle()
                message = nil
            }
            .font(.footnote)
            Spacer()
            if Account.config == nil {
                Text("Accounts aren't set up in this build: run python3 Accounts/setup_supabase.py on the Mac, then rebuild.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(24)
    }

    private func submit() {
        guard !busy, !username.isEmpty, !password.isEmpty else { return }
        busy = true
        message = nil
        Task {
            do {
                if creating {
                    try await account.signUp(username: username, password: password)
                } else {
                    try await account.signIn(username: username, password: password)
                }
            } catch {
                message = error.localizedDescription
            }
            busy = false
        }
    }
}

/// The account button over the main screen: who's signed in, and logging out.
struct AccountMenu: View {
    @EnvironmentObject private var account: Account

    var body: some View {
        Menu {
            Text("Logged in as \(account.session?.username ?? "")")
            Label("Rooms save to RoomTwin's Drive", systemImage: "externaldrive.fill.badge.checkmark")
            Button("Log Out", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive, action: account.signOut)
        } label: {
            Image(systemName: "person.crop.circle")
                .font(.title2)
                .padding(6)
                .background(.regularMaterial, in: Circle())
        }
        .padding(.leading, 8)
        .padding(.top, 4)
    }
}
