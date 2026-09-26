import SwiftUI

enum NewConversation: String, Identifiable {
    case chat, topic
    var id: Self { self }
}

struct NewConversationView: View {
    let mode: NewConversation
    let names: Names
    let onCreate: (Chat) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            if mode == .topic {
                TopicNameView(names: names, onCreate: finish, onCancel: { dismiss() })
            } else {
                ParticipantPicker(topic: nil, names: names, onCreate: finish, onCancel: { dismiss() })
            }
        }
    }

    private func finish(_ chat: Chat) {
        onCreate(chat)
        dismiss()
    }
}

private struct TopicNameView: View {
    let names: Names
    let onCreate: (Chat) -> Void
    let onCancel: () -> Void
    @State private var name = ""
    @State private var failure = ""
    @State private var nextTopic: String?
    @FocusState private var focused: Bool

    var body: some View {
        Form {
            Section {
                HStack {
                    Text("#").foregroundStyle(.secondary)
                    TextField("Topic name", text: $name)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($focused)
                        .submitLabel(.next)
                        .onSubmit(next)
                }
            } footer: {
                Text("A short name, such as launch or weekend-plans. Participants will see this name.")
            }
            if !failure.isEmpty {
                Text(failure).foregroundStyle(.red)
            }
        }
        .navigationTitle("New topic")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: onCancel) }
            ToolbarItem(placement: .confirmationAction) {
                Button("Next", action: next).disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .navigationDestination(item: $nextTopic) { topic in
            ParticipantPicker(topic: topic, names: names, onCreate: onCreate, onCancel: onCancel)
        }
        .onChange(of: name) { failure = "" }
        .task { focused = true }
    }

    private func next() {
        do {
            nextTopic = try topicName(name)
        } catch {
            failure = error.localizedDescription
        }
    }
}

private struct ParticipantPicker: View {
    let topic: String?
    let names: Names
    let onCreate: (Chat) -> Void
    let onCancel: () -> Void
    @State private var store: Store?
    @State private var contacts: [String] = []
    @State private var selected: [String] = []
    @State private var search = ""
    @State private var addingKey = false
    @State private var failure = ""

    private var matches: [String] {
        contacts.filter { key in
            !selected.contains(key) && (search.isEmpty || names.of(key).localizedCaseInsensitiveContains(search)
                                       || fingerprint(key).localizedCaseInsensitiveContains(search))
        }.sorted { names.of($0).localizedStandardCompare(names.of($1)) == .orderedAscending }
    }

    var body: some View {
        List {
            Section {
                Button { addingKey = true } label: {
                    Label("Add by public key", systemImage: "key")
                }
            }
            if !selected.isEmpty {
                Section("Selected (\(selected.count))") {
                    ForEach(selected, id: \.self) { key in
                        person(key, selected: true)
                    }
                }
            }
            Section("Contacts") {
                ForEach(matches, id: \.self) { key in
                    person(key, selected: false)
                }
                if contacts.isEmpty {
                    Text("Add someone using their public key.").foregroundStyle(.secondary)
                } else if matches.isEmpty && !search.isEmpty {
                    Text("No matching contacts").foregroundStyle(.secondary)
                }
            }
            if !failure.isEmpty {
                Text(failure).foregroundStyle(.red)
            }
        }
        .navigationTitle(topic.map { "#" + $0 } ?? "New chat")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $search, prompt: "Name or fingerprint")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: onCancel) }
            ToolbarItem(placement: .confirmationAction) {
                Button("Create", action: create).disabled(selected.isEmpty || store == nil)
            }
        }
        .sheet(isPresented: $addingKey) {
            NavigationStack {
                AddPublicKeyView(me: names.me, selected: selected) { key in
                    if !contacts.contains(key) { contacts.append(key) }
                    selected.append(key)
                }
            }
        }
        .task {
            do {
                let store = try Store(ownPublicKey: names.me)
                contacts = try store.knownContacts()
                self.store = store
            } catch {
                failure = error.localizedDescription
            }
        }
    }

    private func person(_ key: String, selected isSelected: Bool) -> some View {
        Button {
            if isSelected {
                selected.removeAll { $0 == key }
            } else {
                selected.append(key)
            }
        } label: {
            HStack(spacing: 12) {
                Avatar(key: key).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(names.of(key)).foregroundStyle(.primary)
                    if names.aliases[key] != nil {
                        Text(String(fingerprint(key).prefix(8))).font(.caption.monospaced()).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
            }
        }
        .accessibilityValue(isSelected ? "Selected" : "Not selected")
    }

    private func create() {
        guard let store else { return }
        do {
            onCreate(try store.createChat(topic: topic, recipients: selected))
        } catch {
            failure = error.localizedDescription
        }
    }
}

private struct AddPublicKeyView: View {
    let me: String
    let selected: [String]
    let onAdd: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: Bool
    @State private var key = ""
    @State private var failure = ""

    var body: some View {
        Form {
            Section {
                TextField("Public key", text: $key, axis: .vertical)
                    .lineLimit(3...5)
                    .font(.footnote.monospaced())
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($focused)
            } footer: {
                Text("Paste an Ed25519 public key, with or without the ssh-ed25519 prefix.")
            }
            if !failure.isEmpty {
                Text(failure).foregroundStyle(.red)
            }
        }
        .navigationTitle("Add person")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Add", action: add).disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .onChange(of: key) { failure = "" }
        .task { focused = true }
    }

    private func add() {
        do {
            let key = try SSH.publicKey(key)
            guard key != me else { throw ChatCreationError.ownKey }
            guard !selected.contains(key) else { throw ChatCreationError.alreadySelected }
            onAdd(key)
            dismiss()
        } catch {
            failure = error.localizedDescription
        }
    }
}
