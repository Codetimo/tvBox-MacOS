import SwiftUI
import AppKit

struct SearchSuggestionField: View {
    @Binding var text: String
    let suggestions: [SearchSuggestion]
    let onSubmit: () -> Void
    var onClearHistory: (() -> Void)? = nil
    var onSelect: ((SearchSuggestion) -> Void)? = nil
    @State private var isEditing = false
    @State private var isDismissed = false
    @State private var selectedIndex: Int?

    private var isPresented: Bool { isEditing && !isDismissed && !suggestions.isEmpty }

    var body: some View {
        SuggestionTextField(text: $text, isEditing: $isEditing, command: handleCommand)
            .frame(height: 22)
            .overlay(alignment: .topLeading) {
                if isPresented {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text("本地搜索建议").font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            if suggestions.contains(where: { $0.source == .history }), let onClearHistory {
                                Button("清空历史", action: onClearHistory).font(.caption).buttonStyle(.plain)
                            }
                        }.padding(.horizontal, 8).padding(.vertical, 5)
                        ForEach(Array(suggestions.enumerated()), id: \.element.id) { index, suggestion in
                            Button { submit(suggestion.text, suggestion: suggestion) } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: suggestion.source == .history ? "clock" : "magnifyingglass")
                                        .foregroundStyle(.secondary)
                                    Text(suggestion.text).lineLimit(1)
                                    Spacer(minLength: 8)
                                    Text(suggestion.source.rawValue).font(.caption).foregroundStyle(.secondary)
                                }
                                .padding(.horizontal, 8).padding(.vertical, 7)
                                .contentShape(Rectangle())
                                .background(selectedIndex == index ? Color.accentColor.opacity(0.16) : Color.clear,
                                            in: RoundedRectangle(cornerRadius: 5))
                            }.buttonStyle(.plain)
                        }
                    }
                    .padding(5)
                    .frame(width: 350)
                    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 9))
                    .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color.secondary.opacity(0.25)))
                    .shadow(color: .black.opacity(0.15), radius: 8, y: 3)
                    .offset(y: 29)
                }
            }
            .onChange(of: text) { _ in selectedIndex = nil; isDismissed = false }
            .onChange(of: suggestions) { _ in selectedIndex = nil }
            .onChange(of: isEditing) { _ in selectedIndex = nil; isDismissed = false }
    }

    /// 鼠标与键盘选择共用来源路由；没有选中候选的普通回车仍提交自由输入。
    private func submit(_ value: String, suggestion: SearchSuggestion? = nil) {
        text = value
        selectedIndex = nil
        isEditing = false
        isDismissed = true
        if let suggestion, let onSelect { onSelect(suggestion) }
        else { onSubmit() }
    }

    /// 拦截文本编辑器的导航命令，保留中文输入法候选确认和普通文字编辑行为。
    private func handleCommand(_ command: Selector) -> Bool {
        switch NSStringFromSelector(command) {
        case "moveDown:":
            guard !suggestions.isEmpty else { return false }
            isEditing = true
            isDismissed = false
            selectedIndex = min((selectedIndex ?? -1) + 1, suggestions.count - 1)
            return true
        case "moveUp:":
            guard isPresented else { return false }
            selectedIndex = max((selectedIndex ?? suggestions.count) - 1, 0)
            return true
        case "cancelOperation:":
            guard isPresented else { return false }
            isDismissed = true
            selectedIndex = nil
            return true
        case "insertNewline:":
            if isPresented, let selectedIndex, suggestions.indices.contains(selectedIndex) {
                submit(suggestions[selectedIndex].text, suggestion: suggestions[selectedIndex])
            } else {
                submit(text)
            }
            return true
        default: return false
        }
    }
}

private struct SuggestionTextField: NSViewRepresentable {
    @Binding var text: String
    @Binding var isEditing: Bool
    let command: (Selector) -> Bool

    /// 使用原生字段代理在 macOS 13 上处理上下键，不依赖较新系统的 onKeyPress。
    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(string: text)
        field.placeholderString = "搜索影片、频道或分组"
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: NSFont.systemFontSize)
        field.delegate = context.coordinator
        field.setAccessibilityLabel("搜索影片、频道或分组")
        return field
    }

    /// 只同步真实变化，避免每次 SwiftUI 刷新都打断光标与中文输入法组合文本。
    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text, (field.currentEditor() as? NSTextView)?.hasMarkedText() != true {
            field.stringValue = text
        }
    }

    /// 持有文本字段代理，生命周期随 SwiftUI 组件销毁。
    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: SuggestionTextField
        init(parent: SuggestionTextField) { self.parent = parent }

        func controlTextDidBeginEditing(_ notification: Notification) { parent.isEditing = true }
        func controlTextDidEndEditing(_ notification: Notification) { parent.isEditing = false }
        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.isEditing = true
            parent.text = field.stringValue
        }
        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard !textView.hasMarkedText() else { return false }
            return parent.command(commandSelector)
        }
    }
}
