import SwiftUI
import UIKit

enum CreationDesign {
    static let canvas = color(0xF2EFE8, 0x201F1C)
    static let surface = color(0xFAF8F3, 0x2B2A26)
    static let soft = color(0xE7E5DB, 0x35352E)
    static let foreground = Color.primary
    static let secondary = Color.secondary
    static let accent = color(0x557460, 0xADC3A6)
    static let primaryText = color(0xFFFFFF, 0x201F1C)
    static let accentSoft = color(0xE1E7DC, 0x353F32)
    static let border = color(0xD7D4C9, 0x49483F)
    static let danger = color(0xB64C4C, 0xF58282)

    static func interface(_ style: Font.TextStyle = .body, weight: Font.Weight = .regular) -> Font {
        let size: CGFloat
        switch style {
        case .largeTitle: size = 34
        case .title: size = 28
        case .title2: size = 22
        case .title3: size = 20
        case .headline, .body: size = 17
        case .callout: size = 16
        case .subheadline: size = 15
        case .footnote: size = 13
        case .caption: size = 12
        case .caption2: size = 11
        @unknown default: size = 17
        }
        return interface(size: size, relativeTo: style, weight: weight)
    }
    static func interface(size: CGFloat, relativeTo style: Font.TextStyle = .body, weight: Font.Weight = .regular) -> Font {
        .custom(weight == .bold || weight == .semibold || weight == .heavy ? "NotoSerifSC-SemiBold" : "NotoSerifSC-Regular", size: size, relativeTo: style)
    }
    static func time(_ style: Font.TextStyle = .caption) -> Font {
        let size: CGFloat = style == .caption2 ? 11 : style == .footnote ? 13 : style == .subheadline ? 15 : style == .body ? 17 : 12
        return copy(size, relativeTo: style)
    }
    static func editorial(_ size: CGFloat, relativeTo style: Font.TextStyle = .title, bold: Bool = false) -> Font {
        interface(size: size, relativeTo: style, weight: bold ? .semibold : .regular)
    }

    static func contentTitle(_ size: CGFloat, relativeTo style: Font.TextStyle = .headline, bold: Bool = false) -> Font {
        interface(size: size, relativeTo: style, weight: bold ? .semibold : .regular)
    }
    static func copy(_ size: CGFloat = 17, relativeTo style: Font.TextStyle = .body) -> Font {
        .custom("LXGWWenKai-Regular", size: size, relativeTo: style)
    }
    static func writingFont(compatibleWith traits: UITraitCollection? = nil) -> UIFont {
        UIFontMetrics(forTextStyle: .body).scaledFont(for: UIFont(name: "LXGWWenKai-Regular", size: 17) ?? .systemFont(ofSize: 17), compatibleWith: traits)
    }

    private static func color(_ light: UInt32, _ dark: UInt32) -> Color {
        let previewLight = previewColor(light)
        return Color(uiColor: UIColor { traits in
            let value = traits.userInterfaceStyle == .dark ? dark : previewLight
            return UIColor(red: CGFloat((value >> 16) & 255) / 255, green: CGFloat((value >> 8) & 255) / 255, blue: CGFloat(value & 255) / 255, alpha: 1)
        })
    }

    /// Palette comparisons are available only in the offline Debug preview.
    /// Normal launches and Release builds keep the selected production palette.
    private static func previewColor(_ value: UInt32) -> UInt32 {
#if DEBUG
        let args = ProcessInfo.processInfo.arguments
        guard CreationPreview.isEnabled, let index = args.firstIndex(of: "--preview-palette"), args.indices.contains(index + 1) else { return value }
        let values: [UInt32]
        switch args[index + 1] {
        case "oat": values = [0xF2EFE8, 0xFAF8F3, 0xE7E5DB, 0x557460, 0xE1E7DC, 0xD7D4C9]
        case "blue": values = [0xECEFF2, 0xF6F8FA, 0xE0E6ED, 0x526E91, 0xDDE6F0, 0xCAD3DE]
        case "clay": values = [0xF0ECE7, 0xF8F5F0, 0xE6DDD4, 0xAC604A, 0xF0DED4, 0xD9CDC2]
        case "lilac": values = [0xEFEDF2, 0xF8F6FA, 0xE4DFEA, 0x7B688B, 0xE8DFF0, 0xD4CCDE]
        default: return value
        }
        let originals: [UInt32] = [0xF2EFE8, 0xFAF8F3, 0xE7E5DB, 0x557460, 0xE1E7DC, 0xD7D4C9]
        if let position = originals.firstIndex(of: value) { return values[position] }
#endif
        return value
    }
}

struct CreationPageHeader<Trailing: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder var trailing: Trailing
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    var body: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
            : AnyLayout(HStackLayout(alignment: .center, spacing: 16))
        layout {
            VStack(alignment: .leading, spacing: 7) {
                Text(title).font(CreationDesign.interface(.largeTitle, weight: .bold))
                    .foregroundStyle(CreationDesign.foreground)
                if !subtitle.isEmpty { Text(subtitle).font(CreationDesign.interface(.subheadline)).foregroundStyle(CreationDesign.secondary) }
            }.frame(maxWidth: .infinity, alignment: .leading)
            if #available(iOS 26.0, *) {
                trailing.buttonStyle(.glass)
            } else {
                trailing
            }
        }.padding(.top, 10).padding(.bottom, 4)
    }
}

/// Scroll phase includes deceleration, so the compose action never flashes
/// between a finger lifting and the list coming to rest.
struct CreationScrollActionVisibility: ViewModifier {
    @Binding var visible: Bool
    @State private var scrolling = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.onScrollPhaseChange { _, phase in
                scrolling = phase != .idle
                if scrolling { withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) { visible = false } }
            }.task(id: scrolling) {
                guard !scrolling else { return }
                do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
                withAnimation(reduceMotion ? nil : .spring(duration: 0.3)) { visible = true }
            }
        } else { content }
    }
}

struct CreationHeaderIconFrame: ViewModifier {
    @ViewBuilder func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.frame(width: 28, height: 28)
        } else {
            content.frame(width: 44, height: 44).contentShape(Rectangle())
        }
    }
}

/// For content selectors only. Keep edge swipes available to navigation and
/// ignore vertical scrolling or short accidental movements.
struct CreationContentTabSwipe<Value: Equatable>: ViewModifier {
    @Binding var selection: Value
    let values: [Value]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func body(content: Content) -> some View {
        content.simultaneousGesture(DragGesture(minimumDistance: 35).onEnded { value in
            guard value.startLocation.x > 28,
                  abs(value.translation.width) > 65,
                  abs(value.translation.width) > abs(value.translation.height) * 1.5,
                  let index = values.firstIndex(of: selection) else { return }
            let next = index + (value.translation.width < 0 ? 1 : -1)
            guard values.indices.contains(next) else { return }
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { selection = values[next] }
        })
    }
}

/// Instance-local font configuration keeps the native segmented control's
/// selection, accessibility and appearance without a global UIKit override.
struct CreationSegmentedPicker<Value: Equatable>: UIViewRepresentable {
    @Binding var selection: Value
    let values: [Value]
    let titles: [String]
    func makeCoordinator() -> CreationSegmentCoordinator { CreationSegmentCoordinator() }
    func makeUIView(context: Context) -> UISegmentedControl {
        let view = UISegmentedControl(items: titles)
        view.addTarget(context.coordinator, action: #selector(CreationSegmentCoordinator.select(_:)), for: .valueChanged)
        return view
    }
    func updateUIView(_ view: UISegmentedControl, context: Context) {
        if view.numberOfSegments != titles.count {
            view.removeAllSegments()
            for (index, title) in titles.enumerated() { view.insertSegment(withTitle: title, at: index, animated: false) }
        } else {
            for (index, title) in titles.enumerated() where view.titleForSegment(at: index) != title { view.setTitle(title, forSegmentAt: index) }
        }
        let font = UIFontMetrics(forTextStyle: .subheadline).scaledFont(for: UIFont(name: "NotoSerifSC-Regular", size: 14) ?? .preferredFont(forTextStyle: .subheadline), compatibleWith: view.traitCollection)
        view.setTitleTextAttributes([.font: font], for: .normal)
        view.setTitleTextAttributes([.font: font], for: .selected)
        view.selectedSegmentIndex = values.firstIndex(of: selection) ?? UISegmentedControl.noSegment
        context.coordinator.onSelect = { index in if values.indices.contains(index) { selection = values[index] } }
    }
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UISegmentedControl, context: Context) -> CGSize? {
        let lineHeight = (uiView.titleTextAttributes(for: .normal)?[.font] as? UIFont)?.lineHeight ?? 20
        return CGSize(width: proposal.width ?? uiView.intrinsicContentSize.width, height: max(32, lineHeight + 12))
    }
}
@MainActor
final class CreationSegmentCoordinator: NSObject {
    var onSelect: ((Int) -> Void)?
    @objc func select(_ sender: UISegmentedControl) { onSelect?(sender.selectedSegmentIndex) }
}

struct CreationSearchField: View {
    let placeholder: String
    @Binding var text: String
    var autofocus = false
    var submit: () -> Void = {}
    @FocusState private var focused: Bool
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").foregroundStyle(CreationDesign.secondary)
            TextField(placeholder, text: $text).submitLabel(.search).onSubmit(submit)
                .autocorrectionDisabled()
                .focused($focused)
            if !text.isEmpty {
                Button { text = ""; submit() } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(CreationDesign.secondary) }
                    .accessibilityLabel("清空搜索").frame(minWidth: 32, minHeight: 44)
            }
        }.padding(.horizontal, 14).frame(minHeight: 48)
            .background(CreationDesign.soft.opacity(0.65), in: RoundedRectangle(cornerRadius: 6))
            .task { if autofocus { focused = true } }
    }
}

struct CreationMiniPlayerHiddenKey: PreferenceKey {
    static let defaultValue = false
    static func reduce(value: inout Bool, nextValue: () -> Bool) { value = value || nextValue() }
}
struct CreationComposeWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

struct CreationOverlayPresentedKey: PreferenceKey {
    static let defaultValue = false
    static func reduce(value: inout Bool, nextValue: () -> Bool) { value = value || nextValue() }
}

private struct CreationParentPresentationKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    var creationParentPresented: Bool {
        get { self[CreationParentPresentationKey.self] }
        set { self[CreationParentPresentationKey.self] = newValue }
    }
}

/// Keyboard and presentations take precedence over the scroll-rest animation.
struct CreationComposeVisibility: ViewModifier {
    let visible: Bool
    @Environment(\.creationParentPresented) private var parentPresented
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var keyboardVisible = false
    private var shown: Bool { visible && !keyboardVisible && !parentPresented }
    func body(content: Content) -> some View {
        Group {
            if shown {
                content.transition(reduceMotion ? .opacity : .opacity.combined(with: .offset(y: 12)))
            }
        }
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: shown)
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in keyboardVisible = true }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in keyboardVisible = false }
    }
}

struct CreationFilterChip: View {
    let title: String
    var symbol: String? = nil
    let selected: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let symbol { Image(systemName: symbol) }
                Text(title)
            }.font(CreationDesign.interface(.subheadline, weight: selected ? .semibold : .regular))
                .padding(.horizontal, 16).frame(minHeight: 44)
                .foregroundStyle(selected ? CreationDesign.accent : CreationDesign.secondary)
                .overlay(alignment: .bottom) {
                    if selected { Rectangle().fill(CreationDesign.accent).frame(height: 1.5) }
                }
                .contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct CreationSectionHeading: View {
    let title: String
    var detail: String = ""
    var body: some View {
        HStack {
            Text(title).font(CreationDesign.interface(.headline))
            Spacer()
            if !detail.isEmpty { Text(detail).font(CreationDesign.interface(.caption)).foregroundStyle(CreationDesign.secondary) }
        }.foregroundStyle(CreationDesign.foreground)
    }
}

struct CreationFloatingButton: View {
    let title: String
    var symbol = "plus"
    var verticalPadding: CGFloat = 20
    let action: () -> Void
    var body: some View {
        Group {
            if #available(iOS 26.0, *) {
                Button(action: action) {
                    Label(title, systemImage: symbol)
                        .font(CreationDesign.interface(.subheadline, weight: .semibold))
                        .padding(.horizontal, 12)
                        .frame(minHeight: 44)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.capsule)
                .tint(CreationDesign.accent)
            } else {
                Button(action: action) {
                    Label(title, systemImage: symbol).font(CreationDesign.interface(.subheadline, weight: .semibold))
                }.buttonStyle(.borderedProminent).tint(CreationDesign.accent)
            }
        }
        .accessibilityLabel(title)
        .background { GeometryReader { proxy in Color.clear.preference(key: CreationComposeWidthKey.self, value: proxy.size.width) } }
        .padding(.horizontal, 20).padding(.vertical, verticalPadding)
    }
}

struct CreationPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(CreationDesign.interface(.headline)).foregroundStyle(CreationDesign.primaryText)
            .padding(.horizontal, 18).frame(minHeight: 44)
            .background(CreationDesign.accent.opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.35), in: RoundedRectangle(cornerRadius: 6))
    }
}

struct CreationIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.title3).foregroundStyle(CreationDesign.accent)
            .frame(minWidth: 44, minHeight: 44)
            .background(CreationDesign.soft.opacity(configuration.isPressed ? 1 : 0), in: RoundedRectangle(cornerRadius: 6))
    }
}

struct CreationSaveBar: View {
    let title: String
    let message: String
    var isSaving = false
    var canSave = true
    let action: () -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 16) {
                Text(message).font(CreationDesign.interface(.caption)).foregroundStyle(CreationDesign.secondary)
                Spacer(minLength: 0)
                saveButton
            }
            VStack(alignment: .leading, spacing: 10) {
                Text(message).font(CreationDesign.interface(.caption)).foregroundStyle(CreationDesign.secondary)
                saveButton.frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
        .background(CreationDesign.surface)
        .overlay(alignment: .top) { Rectangle().fill(CreationDesign.border).frame(height: 0.5) }
    }

    private var saveButton: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if isSaving { ProgressView() }
                Text(isSaving ? "保存中…" : title)
            }
        }.buttonStyle(CreationPrimaryButtonStyle()).disabled(!canSave || isSaving)
    }
}

struct CreationNotice: View {
    let text: String
    var isError = false
    var body: some View {
        Label(text, systemImage: isError ? "exclamationmark.circle" : "checkmark.circle")
            .font(CreationDesign.interface(.subheadline)).foregroundStyle(isError ? CreationDesign.danger : CreationDesign.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12).background(CreationDesign.soft, in: RoundedRectangle(cornerRadius: 12))
            .accessibilityElement(children: .combine)
    }
}

struct CreationToolLabel: View {
    let title: String
    let symbol: String
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(spacing: 8) {
                    Image(systemName: symbol).font(.title3).foregroundStyle(CreationDesign.accent)
                    Text(title).lineLimit(1).minimumScaleFactor(0.7)
                }.padding(.vertical, 10)
            } else { Label(title, systemImage: symbol) }
        }.frame(maxWidth: .infinity, minHeight: 48)
    }
}

struct CreationRemoteImage: View {
    let path: String?
    let site: URL
    var contentMode: ContentMode = .fill
    @Environment(\.displayScale) private var displayScale
    var body: some View {
        GeometryReader { geometry in
            content(maxPixelSize: Int(ceil(min(2048, max(64, max(geometry.size.width, geometry.size.height) * displayScale)))))
                .frame(width: geometry.size.width, height: geometry.size.height).clipped()
        }
    }
    private func content(maxPixelSize: Int) -> some View {
        Group {
            if CreationPreview.isEnabled {
                Image(path?.contains("/preview-1.") == true ? "BrandCat" : "EditorialPreview").resizable().aspectRatio(contentMode: contentMode)
            } else if let path, let url = URL(string: path, relativeTo: site)?.absoluteURL, ["https", "http"].contains(url.scheme?.lowercased() ?? "") {
                RemoteImageView(url: url, loader: .shared, contentMode: contentMode, maxPixelSize: maxPixelSize) {
                    CreationDesign.soft.overlay { Image(systemName: "photo").foregroundStyle(CreationDesign.secondary) }
                }
            } else { CreationDesign.soft.overlay { Image(systemName: "photo").foregroundStyle(CreationDesign.secondary) } }
        }
        .clipped()
    }
}
