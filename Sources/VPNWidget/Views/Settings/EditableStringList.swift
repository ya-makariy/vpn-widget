import SwiftUI

/// A short list of strings with add and remove, for domains and servers.
struct EditableStringList: View {
    var title: String
    var placeholder: String
    @Binding var items: [String]
    var validate: (String) -> Bool
    @State private var draft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline.weight(.medium))
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                HStack {
                    Image(systemName: validate(item) ? "circle.fill" : "exclamationmark.circle.fill")
                        .font(.system(size: 6))
                        .foregroundStyle(validate(item) ? Color.secondary : Color.orange)
                    Text(item).font(.body.monospaced())
                    Spacer()
                    Button {
                        items.remove(at: index)
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Remove \(item)")
                }
            }
            HStack {
                TextField(placeholder, text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    .onSubmit(add)
                Button("Add", action: add)
                    .disabled(!validate(draft))
            }
        }
        .padding(.vertical, 2)
    }

    private func add() {
        let value = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard validate(value), !items.contains(value) else { return }
        items.append(value)
        draft = ""
    }
}
