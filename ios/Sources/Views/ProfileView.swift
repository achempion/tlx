import SwiftUI

struct ProfileView: View {
    let publicKey: String
    let names: Names

    @State private var editingName = false
    @State private var copied = false

    var body: some View {
        List {
            Section {
                VStack(spacing: 12) {
                    Avatar(key: publicKey, size: 88)
                        .accessibilityHidden(true)
                    Text(names.of(publicKey))
                        .font(.title2.weight(.semibold))
                        .multilineTextAlignment(.center)
                        .textSelection(.enabled)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .listRowBackground(Color.clear)
            }
            Section {
                Button("Edit name") { editingName = true }
            } footer: {
                Text("This name is only visible to you on this device.")
            }
            Section("Public key") {
                Text("ssh-ed25519 \(publicKey)")
                    .font(.footnote.monospaced())
                    .textSelection(.enabled)
                Button {
                    UIPasteboard.general.string = "ssh-ed25519 \(publicKey)"
                    copied = true
                } label: {
                    Label(copied ? "Copied" : "Copy public key", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
            }
        }
        .navigationTitle("Profile")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $editingName) {
            NavigationStack {
                EditNameView(publicKey: publicKey, names: names)
            }
            .presentationDetents([.medium, .large])
        }
    }
}

private struct EditNameView: View {
    let publicKey: String
    let names: Names

    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: Bool
    @State private var name: String
    @State private var failure = ""

    init(publicKey: String, names: Names) {
        self.publicKey = publicKey
        self.names = names
        _name = State(initialValue: names.aliases[publicKey] ?? "")
    }

    var body: some View {
        Form {
            Section("Name") {
                TextField("Name", text: $name)
                    .textContentType(.nickname)
                    .textInputAutocapitalization(.words)
                    .autocorrectionDisabled()
                    .focused($focused)
                    .submitLabel(.done)
                    .onSubmit { save() }
            }
            if !failure.isEmpty {
                Section {
                    Text(failure).foregroundStyle(.red)
                }
            }
            if names.aliases[publicKey] != nil {
                Section {
                    Button("Remove name", role: .destructive) { save(removing: true) }
                } footer: {
                    Text("The default name will be shown again.")
                }
            }
        }
        .navigationTitle("Edit name")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { save() }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .onChange(of: name) { failure = "" }
        .task { focused = true }
    }

    private func save(removing: Bool = false) {
        do {
            let store = try Store(ownPublicKey: names.me)
            if removing {
                try names.removeAlias(publicKey: publicKey, using: store)
            } else {
                try names.setAlias(publicKey: publicKey, name: name, using: store)
            }
            dismiss()
        } catch {
            failure = error.localizedDescription
        }
    }
}
