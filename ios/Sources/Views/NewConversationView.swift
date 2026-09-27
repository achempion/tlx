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
