import AppKit
import SwiftUI

extension ClipKind {
    var accent: Color {
        switch self {
        case .link:  return Color(red: 0.11, green: 0.51, blue: 1.00)
        case .code:  return Color(red: 1.00, green: 0.62, blue: 0.09)
        case .image: return Color(red: 0.73, green: 0.27, blue: 1.00)
        case .file:  return Color(red: 0.04, green: 0.80, blue: 0.35)
        case .color: return Color(red: 1.00, green: 0.20, blue: 0.58)
        // Plain text is the common case, so this one carried the whole
        // "washed out" impression. Still neutral, but with actual colour in it.
        case .text, .rtf: return Color(red: 0.33, green: 0.56, blue: 0.78)
        }
    }

    var label: String {
        switch self {
        case .text:  return "Texto"
        case .code:  return "Código"
        case .link:  return "Link"
        case .image: return "Imagem"
        case .file:  return "Arquivo"
        case .color: return "Cor"
        case .rtf:   return "Texto rico"
        }
    }
}

struct CardView: View {
    let item: ClipItem
    let isSelected: Bool
    let index: Int
    /// Inside a pinboard the header takes the pinboard's colour, the way Paste
    /// does it; loose history falls back to a colour per content type.
    let accent: Color
    /// Set only while searching across every pinboard, to say where a hit lives.
    let pinboardName: String?

    private static let relative: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "pt_BR")
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    var body: some View {
        VStack(spacing: 0) {
            header
            body_
            footer
        }
        .frame(width: 236, height: 248)
        .background(Color(nsColor: .textBackgroundColor).opacity(0.92))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(isSelected ? Color.accentColor : Color.white.opacity(0.12),
                              lineWidth: isSelected ? 3 : 1)
        )
    }

    /// The derived title is the first line of whatever was copied, which made
    /// every header a truncated echo of the body. Show the type instead, and give
    /// the headline over to the user only when they asked for it with ⌘R.
    private var headline: String {
        if item.titleIsCustom, let title = item.title, !title.isEmpty { return title }
        return item.kind.label
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(headline)
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(2)
                Text(Self.relative.localizedString(for: item.createdAt, relativeTo: Date()))
                    .font(.system(size: 12))
                    .opacity(0.75)
            }
            .foregroundStyle(.white)

            Spacer(minLength: 2)

            // The pinboard name used to sit here, between the headline and the
            // app icon, and it ate the headline: "senha nore…" instead of the
            // name the user typed. The header has one job — say what this is —
            // and the badge says where it lives, which the footer has room for.

            if let icon = AppIcons.icon(forBundleID: item.sourceBundleID) {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 42, height: 42)
                    .padding(.trailing, -3)
                    .padding(.top, -3)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(height: 56)
        .background(
            LinearGradient(
                colors: [accent.blended(with: .white, fraction: 0.14),
                         accent.blended(with: .black, fraction: 0.22)],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }

    @ViewBuilder
    private var body_: some View {
        Group {
            switch item.kind {
            case .image:
                thumbnail
            case .file:
                fileRow
            case .color:
                colorSwatch
            case .link:
                linkPreview
            case .code:
                Text(item.preview)
                    .font(.system(size: 11, design: .monospaced))
            default:
                Text(item.preview)
                    .font(.system(size: 12))
            }
        }
        .lineLimit(9)
        .multilineTextAlignment(.leading)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.horizontal, showsFullBleedColour ? 0 : 10)
        .padding(.top, showsFullBleedColour ? 0 : 8)
        .clipped()
    }

    @ViewBuilder
    private var linkPreview: some View {
        if item.linkTitle != nil || item.linkImagePath != nil {
            VStack(alignment: .leading, spacing: 6) {
                if let path = item.linkImagePath, let image = Thumbnails.image(for: path) {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(maxWidth: .infinity, maxHeight: 96)
                        .clipped()
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                }
                Text(item.linkTitle ?? item.preview)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(3)
                Text(item.linkDomain ?? URL(string: item.preview)?.host() ?? "")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        } else {
            Text(item.preview).font(.system(size: 12))
        }
    }

    @ViewBuilder
    private var thumbnail: some View {
        if let path = item.blobPath, let image = Thumbnails.image(for: path) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 5))
        } else {
            Text(item.preview).font(.system(size: 12)).opacity(0.6)
        }
    }

    @ViewBuilder
    private var fileRow: some View {
        // A single image file gets the same treatment as pasted image data —
        // otherwise copying a screenshot from Finder shows only its filename,
        // while copying the same screenshot as data shows the picture.
        if let path = singlePath, let preview = Thumbnails.image(forFile: path) {
            VStack(alignment: .leading, spacing: 4) {
                Image(nsImage: preview)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                Text(URL(fileURLWithPath: path).lastPathComponent)
                    .font(.system(size: 11)).lineLimit(1).opacity(0.7)
            }
        } else {
            fileList
        }
    }

    @ViewBuilder
    private var fileList: some View {
        if let path = singlePath {
            VStack(spacing: 8) {
                Spacer(minLength: 0)
                Image(nsImage: NSWorkspace.shared.icon(forFile: path))
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 72, height: 72)
                Spacer(minLength: 0)
                // Truncating in the middle keeps both the volume and the file
                // name, which is what tells two similar paths apart.
                Text(path)
                    .font(.system(size: 11))
                    .lineLimit(3)
                    .truncationMode(.middle)
                    .multilineTextAlignment(.center)
                    .opacity(0.75)
            }
            .frame(maxWidth: .infinity)
        } else {
            VStack(alignment: .leading, spacing: 5) {
                ForEach(item.preview.split(separator: "\n").prefix(5), id: \.self) { path in
                    HStack(spacing: 6) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: String(path)))
                            .resizable().frame(width: 22, height: 22)
                        Text(URL(fileURLWithPath: String(path)).lastPathComponent)
                            .font(.system(size: 12)).lineLimit(1)
                    }
                }
            }
        }
    }

    private var singlePath: String? {
        let paths = item.preview.split(separator: "\n")
        guard paths.count == 1 else { return nil }
        return String(paths[0])
    }

    /// A colour card *is* the colour, edge to edge — which is why `body_` drops
    /// its padding for this one case. A small swatch floating in a padded box
    /// reads as a picture of a colour; the point is to see the colour itself.
    private var showsFullBleedColour: Bool {
        item.kind == .color && NSColor(hex: item.preview) != nil
    }

    @ViewBuilder
    private var colorSwatch: some View {
        if let color = NSColor(hex: item.preview) {
            Color(nsColor: color)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(
                    Text(item.preview.uppercased())
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Self.readableInk(on: color))
                        .padding(.horizontal, 9).padding(.vertical, 4)
                        .background(.ultraThinMaterial, in: Capsule())
                )
        } else {
            Text(item.preview).font(.system(size: 12))
        }
    }

    /// Black on light colours, white on dark ones. One fixed ink colour is
    /// unreadable over half of any palette.
    private static func readableInk(on color: NSColor) -> Color {
        guard let srgb = color.usingColorSpace(.sRGB) else { return .white }
        let luminance = 0.2126 * srgb.redComponent
            + 0.7152 * srgb.greenComponent
            + 0.0722 * srgb.blueComponent
        return luminance > 0.6 ? .black : .white
    }

    private var footer: some View {
        HStack(spacing: 4) {
            // Quick-pick hint: Cmd+1..9 jumps straight to a card.
            if index < 9 {
                Text("⌘\(index + 1)")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.white.opacity(0.10), in: Capsule())
            }
            if let pinboardName {
                HStack(spacing: 4) {
                    Circle().fill(accent).frame(width: 6, height: 6)
                    Text(pinboardName)
                        .font(.system(size: 10, weight: .semibold))
                        .lineLimit(1)
                }
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Color.white.opacity(0.10), in: Capsule())
                .layoutPriority(1)
            }

            Spacer(minLength: 4)

            Text(footerText)
                .font(.system(size: 11))
                .opacity(0.55)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .frame(height: 26)
    }

    private var footerText: String {
        switch item.kind {
        case .image:
            // The preview already carries "Imagem 1008×343"; the dimensions read
            // better than a byte count, and match what Paste shows.
            let dimensions = item.preview.replacingOccurrences(of: "Imagem ", with: "")
            if dimensions != item.preview, !dimensions.isEmpty { return dimensions }
            return ByteCountFormatter.string(fromByteCount: Int64(item.byteSize), countStyle: .file)
        case .file:
            let count = item.preview.split(separator: "\n").count
            return count == 1 ? "1 arquivo" : "\(count) arquivos"
        default:
            return "\(item.charCount) caracteres"
        }
    }
}

extension NSColor {
    convenience init?(hex: String) {
        var text = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.hasPrefix("#") else { return nil }
        text.removeFirst()
        if text.count == 3 { text = text.map { "\($0)\($0)" }.joined() }
        guard text.count == 6 || text.count == 8, let value = UInt32(text, radix: 16) else { return nil }

        let hasAlpha = text.count == 8
        let r = CGFloat((value >> (hasAlpha ? 24 : 16)) & 0xFF) / 255
        let g = CGFloat((value >> (hasAlpha ? 16 : 8)) & 0xFF) / 255
        let b = CGFloat((value >> (hasAlpha ? 8 : 0)) & 0xFF) / 255
        let a = hasAlpha ? CGFloat(value & 0xFF) / 255 : 1
        self.init(srgbRed: r, green: g, blue: b, alpha: a)
    }
}

extension Color {
    /// SwiftUI has no blend operator, and NSColor's needs both sides in the same
    /// colour space or it returns nil.
    func blended(with other: Color, fraction: CGFloat) -> Color {
        guard let base = NSColor(self).usingColorSpace(.sRGB),
              let mix = NSColor(other).usingColorSpace(.sRGB),
              let result = base.blended(withFraction: fraction, of: mix)
        else { return self }
        return Color(nsColor: result)
    }
}
