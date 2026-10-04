import SwiftUI

/// The full draft is kept even when parsing fails. A malformed draft must not
/// silently turn into a different number or authorize submission of an old Int.
struct IntegerInputDraft: Equatable {
    var text: String
    let range: ClosedRange<Int>
    var parsed: Int? { ConnectionValidation.integer(text, range: range) }
    var valid: Bool { parsed != nil }
    mutating func apply(_ text: String, to value: inout Int) {
        self.text = text
        if let parsed { value = parsed }
    }
}

struct IntegerInput: View {
    @EnvironmentObject private var store: AppStore
    @Binding var value: Int
    @Binding var valid: Bool
    let range: ClosedRange<Int>
    let placeholder: String
    let label: String
    @State private var draft: IntegerInputDraft
    init(value: Binding<Int>, valid: Binding<Bool>, range: ClosedRange<Int>, placeholder: String = "", label: String) {
        _value = value; _valid = valid; self.range = range; self.placeholder = placeholder; self.label = label
        _draft = State(initialValue: IntegerInputDraft(text: String(value.wrappedValue), range: range))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            TextField(placeholder, text: Binding(get: { draft.text }, set: { text in
                var current = value
                draft.apply(text, to: &current)
                valid = draft.valid
                if draft.valid { value = current }
            })).appInput().accessibilityLabel(label)
            if !draft.valid {
                Text(store.text("Enter an integer from \(range.lowerBound) to \(range.upperBound)", "请输入 \(range.lowerBound)–\(range.upperBound) 的整数"))
                    .font(.system(size: 10)).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
        }.onAppear { valid = draft.valid }
            .onChange(of: value) { _, newValue in
                if draft.parsed != newValue {
                    draft = IntegerInputDraft(text: String(newValue), range: range)
                    valid = draft.valid
                }
            }
    }
}

struct PortInput: View {
    @Binding var value: Int
    @Binding var valid: Bool
    var placeholder = "22"
    let label: String
    var body: some View { IntegerInput(value: $value, valid: $valid, range: 1...65535, placeholder: placeholder, label: label) }
}
