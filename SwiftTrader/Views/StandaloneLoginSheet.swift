import DukascopyClient
import SwiftUI

/// Standalone-mode login: pick a saved account (or add one) and connect the native
/// Dukascopy session. Passwords are stored as SHA-1 hashes in the Keychain.
struct StandaloneLoginSheet: View {
    @Bindable var accounts: AccountStore
    var auth: StandaloneAuthViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var isAddingAccount = false
    @State private var newLabel = ""
    @State private var newLogin = ""
    @State private var newPassword = ""
    @State private var newEnv: DukascopyEnvironment = .demo

    private var showingForm: Bool { isAddingAccount || accounts.accounts.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Standalone login")
                .font(.headline)

            if showingForm {
                addAccountForm
            } else {
                accountList
            }

            if let saveError = accounts.lastSaveError {
                Text("Couldn't save credentials to the Keychain: \(String(describing: saveError))")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }

            switch auth.phase {
            case .connecting:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Connecting…").font(.caption).foregroundStyle(.secondary)
                }
            case .failed(let msg):
                Text(msg)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            default:
                EmptyView()
            }

            HStack {
                if !showingForm {
                    Button("Add account") { isAddingAccount = true }
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                if showingForm {
                    Button("Save") { saveNewAccount() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(newLabel.isEmpty || newLogin.isEmpty || newPassword.isEmpty)
                } else {
                    Button("Connect") { connect() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(accounts.selectedAccountID == nil || auth.phase == .connecting)
                }
            }
        }
        .padding(20)
        .frame(width: 380)
    }

    private var accountList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Choose an account")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            ForEach(accounts.accounts) { account in
                HStack {
                    Image(systemName: accounts.selectedAccountID == account.id
                        ? "largecircle.fill.circle" : "circle")
                        .foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(account.label)
                        Text("\(account.login) · \(account.environment.rawValue.uppercased())")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(role: .destructive) {
                        accounts.removeAccount(account.id)
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                }
                .contentShape(Rectangle())
                .onTapGesture { accounts.selectedAccountID = account.id }
            }
        }
    }

    private var addAccountForm: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Label (e.g. My Demo)", text: $newLabel)
                .textFieldStyle(.roundedBorder)
            TextField("Login / account number", text: $newLogin)
                .textFieldStyle(.roundedBorder)
            SecureField("Password", text: $newPassword)
                .textFieldStyle(.roundedBorder)
            Picker("Environment", selection: $newEnv) {
                ForEach(DukascopyEnvironment.allCases, id: \.self) {
                    Text($0.rawValue.uppercased()).tag($0)
                }
            }
            .pickerStyle(.segmented)
        }
    }

    private func saveNewAccount() {
        accounts.addAccount(
            label: newLabel, login: newLogin, password: newPassword, environment: newEnv
        )
        // Keep the form (and the typed values) up if the Keychain write failed, so the
        // user sees the error and can retry rather than losing an account that can't connect.
        guard accounts.lastSaveError == nil else { return }
        newLabel = ""; newLogin = ""; newPassword = ""; newEnv = .demo
        isAddingAccount = false
    }

    private func connect() {
        Task {
            await auth.connectOrSwitch()
            if auth.phase == .ready { dismiss() }
        }
    }
}
