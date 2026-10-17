import SwiftUI
import UIKit

enum CreationDesign {
    static let canvas = color(0xF5F4EF, 0x121714)
    static let surface = color(0xFFFFFF, 0x1E2420)
    static let soft = color(0xEFEEE8, 0x2B322D)
    static let foreground = color(0x18201B, 0xECF3ED)
    static let secondary = color(0x657168, 0xA4B4A8)
    static let accent = color(0x356B52, 0x77CCA2)
    static let primaryText = color(0xFFFFFF, 0x121714)
    static let accentSoft = color(0xE4EDE3, 0x284D3B)
    static let border = color(0xE1E6E0, 0x3C4740)
    static let danger = color(0xB64C4C, 0xF58282)

    private static func color(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(uiColor: UIColor { traits in
            let value = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: CGFloat((value >> 16) & 255) / 255, green: CGFloat((value >> 8) & 255) / 255, blue: CGFloat(value & 255) / 255, alpha: 1)
        })
    }
}

struct CreationPageHeader<Trailing: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder var trailing: Trailing
    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 7) {
                Text(title).font(.system(.largeTitle, design: .serif, weight: .bold))
                    .foregroundStyle(CreationDesign.foreground)
                Text(subtitle).font(.subheadline).foregroundStyle(CreationDesign.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading)
            trailing
        }.padding(.top, 10).padding(.bottom, 4)
    }
}

struct CreationSearchField: View {
    let placeholder: String
    @Binding var text: String
    var submit: () -> Void = {}
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").foregroundStyle(CreationDesign.secondary)
            TextField(placeholder, text: $text).submitLabel(.search).onSubmit(submit)
                .autocorrectionDisabled()
            if !text.isEmpty {
                Button { text = ""; submit() } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(CreationDesign.secondary) }
                    .accessibilityLabel("清空搜索").frame(minWidth: 32, minHeight: 44)
            }
        }.padding(.horizontal, 14).frame(minHeight: 48)
            .background(CreationDesign.surface, in: RoundedRectangle(cornerRadius: 16))
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
            }.font(.subheadline.weight(selected ? .semibold : .regular))
                .padding(.horizontal, 16).frame(minHeight: 44)
                .background(selected ? CreationDesign.accent : CreationDesign.surface, in: Capsule())
                .foregroundStyle(selected ? CreationDesign.primaryText : CreationDesign.secondary)
        }.buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct CreationSectionHeading: View {
    let title: String
    var detail: String = ""
    var body: some View {
        HStack {
            Text(title).font(.headline)
            Spacer()
            if !detail.isEmpty { Text(detail).font(.caption).foregroundStyle(CreationDesign.secondary) }
        }.foregroundStyle(CreationDesign.foreground)
    }
}

struct CreationFloatingButton: View {
    let title: String
    var symbol = "plus"
    let action: () -> Void
    var body: some View {
        Button(action: action) { Label(title, systemImage: symbol).padding(.vertical, 4) }
            .buttonStyle(CreationPrimaryButtonStyle())
            .shadow(color: CreationDesign.accent.opacity(0.2), radius: 12, x: 0, y: 5)
            .padding(20)
    }
}

struct CreationPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.headline).foregroundStyle(CreationDesign.primaryText)
            .padding(.horizontal, 18).frame(minHeight: 44)
            .background(CreationDesign.accent.opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.35), in: Capsule())
    }
}

struct CreationIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.title3).foregroundStyle(CreationDesign.accent)
            .frame(minWidth: 44, minHeight: 44)
            .background(CreationDesign.accentSoft.opacity(configuration.isPressed ? 0.6 : 1), in: Circle())
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
                Text(message).font(.caption).foregroundStyle(CreationDesign.secondary)
                Spacer(minLength: 0)
                saveButton
            }
            VStack(alignment: .leading, spacing: 10) {
                Text(message).font(.caption).foregroundStyle(CreationDesign.secondary)
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
            .font(.subheadline).foregroundStyle(isError ? CreationDesign.danger : CreationDesign.secondary)
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
                ZStack {
                    CreationDesign.accentSoft
                    Image(systemName: path?.contains("cover") == true ? "music.note" : "leaf.fill").font(.largeTitle).foregroundStyle(CreationDesign.accent)
                }
            } else if let path, let url = URL(string: path, relativeTo: site)?.absoluteURL, ["https", "http"].contains(url.scheme?.lowercased() ?? "") {
                RemoteImageView(url: url, loader: .shared, contentMode: contentMode, maxPixelSize: maxPixelSize) {
                    CreationDesign.soft.overlay { Image(systemName: "photo").foregroundStyle(CreationDesign.secondary) }
                }
            } else { CreationDesign.soft.overlay { Image(systemName: "photo").foregroundStyle(CreationDesign.secondary) } }
        }
        .clipped()
    }
}
