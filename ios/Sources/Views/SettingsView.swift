import SwiftUI

struct SettingsView: View {
    @Binding var settings: Settings?
    @Environment(\.dismiss) private var dismiss

    @State private var host: String
    @State private var port: String
    @State private var privateKeyPEM: String
    @State private var connecting = false
    @State private var failure = ""

    init(settings: Binding<Settings?>) {
        _settings = settings
        _host = State(initialValue: settings.wrappedValue?.address.host ?? "")
        _port = State(initialValue: String(settings.wrappedValue?.address.port ?? 2222))
        _privateKeyPEM = State(initialValue: settings.wrappedValue?.identity.privateKeyPEM ?? "")
    }

    private var parsed: Result<Identity, Error> {
        Result { try Identity(privateKeyPEM: privateKeyPEM) }
    }

    var body: some View {
        Form {
            Section("Relay") {
                TextField("Host", text: $host)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("Port", text: $port)
                    .keyboardType(.numberPad)
            }
            Section("Private key") {
                TextEditor(text: $privateKeyPEM)
                    .font(.footnote.monospaced())
                    .frame(minHeight: 120)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                keyLine
            }
            Section {
                Button(connecting ? "Connecting…" : "Connect", action: connect)
                    .disabled(connecting || host.isEmpty || Int(port) == nil || (try? parsed.get()) == nil)
                if !failure.isEmpty {
                    Text(failure).foregroundStyle(.red)
                }
            }
        }
    }

    @ViewBuilder
    private var keyLine: some View {
        switch parsed {
        case .success(let identity):
            Text("ssh-ed25519 \(identity.publicKey)").font(.footnote.monospaced())
        case .failure where privateKeyPEM.isEmpty:
            Text("Paste the private key from ~/.tlx/key").foregroundStyle(.secondary)
        case .failure(let error):
            Text(error.localizedDescription).foregroundStyle(.red)
        }
    }

    private func connect() {
        guard case .success(let identity) = parsed, let port = Int(port) else {
            return
        }
        let candidate = Settings(identity: identity, address: RelayAddress(host: host, port: port))
        connecting = true
        failure = ""
        Task {
            do {
                try await Relay(address: candidate.address, identity: identity).check()
                if candidate != settings {
                    resetDatabases()
                }
                try candidate.save()
                UIPasteboard.general.items = []
                settings = candidate
                dismiss()
            } catch {
                failure = error.localizedDescription
            }
            connecting = false
        }
    }
}
