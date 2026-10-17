import SwiftUI
import UIKit

/// Ranges use UTF-16, matching UITextView and NSString, including emoji and CJK input.
enum MarkdownAction: String, CaseIterable {
    case heading, bold, italic, quote, bullet, numbered, task, link, code, codeBlock, divider
    var title: String {
        switch self {
        case .heading: "标题"
        case .bold: "加粗"
        case .italic: "斜体"
        case .quote: "引用"
        case .bullet: "列表"
        case .numbered: "编号"
        case .task: "待办"
        case .link: "链接"
        case .code: "行内代码"
        case .codeBlock: "代码块"
        case .divider: "分隔线"
        }
    }
    var symbol: String {
        switch self {
        case .heading: "textformat.size"
        case .bold: "bold"
        case .italic: "italic"
        case .quote: "text.quote"
        case .bullet: "list.bullet"
        case .numbered: "list.number"
        case .task: "checklist"
        case .link: "link"
        case .code: "chevron.left.forwardslash.chevron.right"
        case .codeBlock: "curlybraces"
        case .divider: "minus"
        }
    }

    func edit(text: String, selection: NSRange) -> MarkdownEdit {
        let source = text as NSString
        let start = min(max(selection.location, 0), source.length)
        let range = NSRange(location: start, length: min(max(selection.length, 0), source.length - start))
        let selected = source.substring(with: range)
        switch self {
        case .heading, .quote, .bullet, .numbered, .task:
            let lines = source.lineRange(for: range)
            let original = source.substring(with: lines)
            var parts = original.components(separatedBy: "\n")
            let trailing = parts.last == "" && parts.count > 1
            if trailing { parts.removeLast() }
            let prefixes = parts.indices.map { index in
                switch self {
                case .heading: "## "
                case .quote: "> "
                case .bullet: "- "
                case .numbered: "\(index + 1). "
                default: "- [ ] "
                }
            }
            let replacement = zip(parts, prefixes).map { $1 + $0 }.joined(separator: "\n") + (trailing ? "\n" : "")
            let firstPrefixLength = (prefixes.first ?? "").utf16.count
            let cursor = lines.location + min(start - lines.location + firstPrefixLength, replacement.utf16.count)
            return MarkdownEdit(range: lines, replacement: replacement,
                                selection: range.length == 0 ? NSRange(location: cursor, length: 0) : NSRange(location: lines.location, length: replacement.utf16.count))
        case .divider:
            let value = "\n\n---\n\n"
            return MarkdownEdit(range: range, replacement: value, selection: NSRange(location: start + value.utf16.count, length: 0))
        default:
            let prefix: String
            let suffix: String
            let placeholder: String
            switch self {
            case .bold: (prefix, suffix, placeholder) = ("**", "**", "加粗文字")
            case .italic: (prefix, suffix, placeholder) = ("*", "*", "斜体文字")
            case .link: (prefix, suffix, placeholder) = ("[", "](https://)", "链接文字")
            case .code: (prefix, suffix, placeholder) = ("`", "`", "代码")
            default: (prefix, suffix, placeholder) = ("\n```\n", "\n```\n", "代码")
            }
            let value = selected.isEmpty ? placeholder : selected
            return MarkdownEdit(range: range, replacement: prefix + value + suffix,
                                selection: NSRange(location: start + prefix.utf16.count, length: value.utf16.count))
        }
    }
}

struct MarkdownEdit {
    let range: NSRange
    let replacement: String
    let selection: NSRange
}

@MainActor
final class MarkdownWritingController: ObservableObject {
    weak var textView: UITextView?
    @Published var canUndo = false
    @Published var canRedo = false

    func apply(_ action: MarkdownAction) {
        guard let textView, textView.isEditable else { return }
        textView.becomeFirstResponder()
        guard textView.markedTextRange == nil else { return }
        let edit = action.edit(text: textView.text, selection: textView.selectedRange)
        textView.selectedRange = edit.range
        textView.insertText(edit.replacement)
        textView.selectedRange = edit.selection
        textView.delegate?.textViewDidChange?(textView)
        refresh()
    }
    func undo() { textView?.undoManager?.undo(); if let textView { textView.delegate?.textViewDidChange?(textView) }; refresh() }
    func redo() { textView?.undoManager?.redo(); if let textView { textView.delegate?.textViewDidChange?(textView) }; refresh() }
    /// Inserts media at the saved cursor position, including after a picker closes.
    @discardableResult
    func insert(_ snippet: String) -> Bool {
        guard let textView, textView.isEditable, textView.markedTextRange == nil else { return false }
        textView.insertText(snippet)
        textView.delegate?.textViewDidChange?(textView)
        refresh()
        return true
    }
    func refresh() {
        let nextCanUndo = textView?.undoManager?.canUndo ?? false
        let nextCanRedo = textView?.undoManager?.canRedo ?? false
        if canUndo != nextCanUndo { canUndo = nextCanUndo }
        if canRedo != nextCanRedo { canRedo = nextCanRedo }
    }
}

struct MarkdownWritingView: UIViewRepresentable {
    @Binding var text: String
    @Binding var focused: Bool
    let controller: MarkdownWritingController
    var editable = true
    var label = "文章正文"
    var minimumHeight: CGFloat = 0

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.delegate = context.coordinator
        view.backgroundColor = .clear
        view.font = .preferredFont(forTextStyle: .body)
        view.adjustsFontForContentSizeCategory = true
        view.textColor = .label
        view.tintColor = UIColor(CreationDesign.accent)
        view.textContainerInset = UIEdgeInsets(top: 12, left: 0, bottom: 20, right: 0)
        view.textContainer.lineFragmentPadding = 0
        view.isScrollEnabled = false
        view.keyboardDismissMode = .interactive
        view.smartQuotesType = .no
        view.smartDashesType = .no
        view.accessibilityLabel = label
        controller.textView = view
        return view
    }
    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.isUpdatingView = true
        defer { context.coordinator.isUpdatingView = false }
        controller.textView = view
        view.isEditable = editable
        if view.text != text && view.markedTextRange == nil {
            let selected = view.selectedRange
            view.text = text
            view.selectedRange = NSRange(location: min(selected.location, text.utf16.count), length: 0)
        }
        if focused && !view.isFirstResponder && editable {
            DispatchQueue.main.async { if self.focused && view.window != nil { view.becomeFirstResponder() } }
        } else if !focused && view.isFirstResponder { view.resignFirstResponder() }
    }
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        guard let width = proposal.width else { return nil }
        let contentSize = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        // The actual text view must fill the writing area so blank space accepts taps.
        return CGSize(width: width, height: max(minimumHeight, contentSize.height))
    }
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: MarkdownWritingView
        var isUpdatingView = false
        init(_ parent: MarkdownWritingView) { self.parent = parent }
        func textViewDidChange(_ view: UITextView) {
            if isUpdatingView {
                // UIKit can end editing synchronously in updateUIView. Commit
                // delegate changes after SwiftUI finishes its update instead
                // of delaying the actual keyboard dismissal.
                DispatchQueue.main.async { [weak self, weak view] in
                    guard let self, let view, self.parent.controller.textView === view else { return }
                    self.textViewDidChange(view)
                }
                return
            }
            guard view.markedTextRange == nil else { return }
            if parent.text != view.text { parent.text = view.text }
            view.invalidateIntrinsicContentSize()
            parent.controller.refresh()
            revealCaret(view)
        }
        func textViewDidChangeSelection(_ view: UITextView) { if view.isFirstResponder { revealCaret(view) } }
        private func revealCaret(_ view: UITextView) {
            DispatchQueue.main.async { [weak view] in
                guard let view, view.isFirstResponder, let selected = view.selectedTextRange else { return }
                var ancestor = view.superview
                while let current = ancestor {
                    if let scroll = current as? UIScrollView, scroll.isScrollEnabled {
                        let caret = view.caretRect(for: selected.end).insetBy(dx: 0, dy: -18)
                        scroll.scrollRectToVisible(view.convert(caret, to: scroll), animated: false)
                        break
                    }
                    ancestor = current.superview
                }
            }
        }
        func textViewDidBeginEditing(_ view: UITextView) { if !isUpdatingView && !parent.focused { parent.focused = true } }
        func textViewDidEndEditing(_ view: UITextView) { if !isUpdatingView && parent.focused { parent.focused = false }; textViewDidChange(view) }
    }
}

struct MarkdownFormatBar: View {
    @ObservedObject var controller: MarkdownWritingController
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 3) {
                Button { controller.undo() } label: { Image(systemName: "arrow.uturn.backward").frame(width: 44, height: 44) }.disabled(!controller.canUndo).opacity(controller.canUndo ? 1 : 0.3).accessibilityLabel("撤销")
                Button { controller.redo() } label: { Image(systemName: "arrow.uturn.forward").frame(width: 44, height: 44) }.disabled(!controller.canRedo).opacity(controller.canRedo ? 1 : 0.3).accessibilityLabel("重做")
                Rectangle().fill(CreationDesign.border).frame(width: 1, height: 20).padding(.horizontal, 6)
                ForEach(MarkdownAction.allCases, id: \.self) { action in
                    Button { controller.apply(action) } label: { Image(systemName: action.symbol).frame(width: 44, height: 44) }.accessibilityLabel(action.title)
                }
            }.padding(.horizontal, 10)
        }.foregroundStyle(CreationDesign.foreground).background(CreationDesign.soft)
    }
}

func creationMarkdownBlocks(_ content: String, references: [AdminReferenceSnapshot]) -> [MarkdownBlock] {
    MarkdownParser.parse(content, references: references.map {
        ArticleReferenceSnapshot(url: $0.url ?? $0.canonicalUrl, canonicalURL: $0.canonicalUrl,
                                 title: $0.title, source: $0.source, author: $0.author,
                                 publishedAt: $0.publishedAt, cover: $0.cover, coverURL: $0.coverUrl,
                                 description: $0.description, summary: $0.summary, keyPoints: $0.keyPoints)
    })
}
