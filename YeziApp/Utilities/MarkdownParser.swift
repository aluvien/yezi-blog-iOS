import Foundation
import SwiftUI

struct MusicMarker: Hashable, Sendable {
    let id: String
    let type: String
    let shuffle: Bool
    let title: String?
    let artist: String?
    let cover: String?
}

enum MarkdownBlock: Hashable, Sendable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case unorderedList([String])
    case orderedList([String])
    case quote(String)
    case music(String)
    case video(String)
    case code(language: String?, text: String)
    case image(url: String, alt: String)
    case divider
    case reference(ArticleReferenceSnapshot)
    case unresolvedReference(String)
}

struct MarkdownParser: Sendable {
    private struct FenceStart: Sendable {
        let language: String?
        let marker: Character
    }

    static func parse(_ content: String, references: [ArticleReferenceSnapshot] = []) -> [MarkdownBlock] {
        let normalized = content.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.components(separatedBy: "\n")
        var result: [MarkdownBlock] = []
        var index = 0

        while index < lines.count {
            let line = lines[index]
            if line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                index += 1
                continue
            }

            if let fence = fencedCodeStart(line) {
                index += 1
                var codeLines: [String] = []
                while index < lines.count && !isFenceEnd(lines[index], marker: fence.marker) {
                    codeLines.append(lines[index])
                    index += 1
                }
                if index < lines.count { index += 1 }
                let code = codeLines.joined(separator: "\n")
                if fence.language == "music" || fence.language == "qqvip" {
                    let musicSpecs = code
                        .components(separatedBy: "\n")
                        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .filter { musicMarker(from: $0) != nil }
                    if musicSpecs.isEmpty {
                        result.append(.code(language: fence.language, text: code))
                    } else {
                        result.append(contentsOf: musicSpecs.map { .music($0) })
                    }
                } else if fence.language == "video" || fence.language == "embed" {
                    let videoURLs = code
                        .components(separatedBy: "\n")
                        .compactMap { videoURL(in: $0) }
                    if videoURLs.isEmpty {
                        result.append(.code(language: fence.language, text: code))
                    } else {
                        result.append(contentsOf: videoURLs.map { .video($0) })
                    }
                } else if fence.language == "reference" {
                    appendReference(code.trimmingCharacters(in: .whitespacesAndNewlines), references: references, to: &result)
                } else {
                    result.append(.code(language: fence.language, text: code))
                }
                continue
            }

            if let music = musicPayload(in: line) {
                result.append(.music(music))
                index += 1
                continue
            }

            if let video = videoURL(in: line) {
                result.append(.video(video))
                index += 1
                continue
            }

            if let marker = referencePayload(in: line) {
                index += 1
                appendReference(marker, references: references, to: &result)
                continue
            }

            if let heading = heading(in: line) {
                result.append(.heading(level: heading.level, text: heading.text))
                index += 1
                continue
            }

            if let image = image(in: line) {
                result.append(.image(url: image.url, alt: image.alt))
                index += 1
                continue
            }

            if isDivider(line) {
                result.append(.divider)
                index += 1
                continue
            }

            if line.trimmingCharacters(in: .whitespaces).hasPrefix(">") {
                var quoteLines: [String] = []
                while index < lines.count {
                    let current = lines[index].trimmingCharacters(in: .whitespaces)
                    guard current.hasPrefix(">") else { break }
                    quoteLines.append(String(current.dropFirst()).trimmingCharacters(in: .whitespaces))
                    index += 1
                }
                result.append(.quote(quoteLines.joined(separator: "\n")))
                continue
            }

            if unorderedItem(in: line) != nil {
                var items: [String] = []
                while index < lines.count, let item = unorderedItem(in: lines[index]) {
                    items.append(item)
                    index += 1
                }
                result.append(.unorderedList(items))
                continue
            }

            if orderedItem(in: line) != nil {
                var items: [String] = []
                while index < lines.count, let item = orderedItem(in: lines[index]) {
                    items.append(item)
                    index += 1
                }
                result.append(.orderedList(items))
                continue
            }

            // Consecutive ordinary lines form one paragraph. This keeps the
            // parser small while preserving Markdown's normal soft line breaks.
            var paragraphLines = [line]
            index += 1
            while index < lines.count,
                  !lines[index].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !isStructuralLine(lines[index]) {
                paragraphLines.append(lines[index])
                index += 1
            }
            result.append(.paragraph(paragraphLines.joined(separator: "\n")))
        }

        return result
    }

    static func attributed(_ text: String) -> AttributedString {
        do {
            return try AttributedString(markdown: text, options: .init(interpretedSyntax: .full))
        } catch {
            return AttributedString(text)
        }
    }

    static func referencePayload(in line: String) -> String? {
        let value = normalizedMarkerLine(line)
        let labels = ["!reference", "!article-reference", "!article", "!cite"]
        for label in labels {
            let lowercased = value.lowercased()
            guard lowercased.hasPrefix(label) else { continue }
            let remainder = value.dropFirst(label.count)
            guard remainder.isEmpty || remainder.first == ":" || remainder.first == " " || remainder.first == "\t" else {
                continue
            }
            let payload = remainder.drop(while: { $0 == ":" || $0 == " " || $0 == "\t" })
            return String(payload).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }

    /// The web editor accepts both the historical `!music ...` marker and a
    /// fenced `music` block. Normalize the line marker here so every native
    /// screen renders the same music card instead of showing raw Markdown.
    static func musicPayload(in line: String) -> String? {
        let value = normalizedMarkerLine(line)
        let lowercased = value.lowercased()
        let label = "!music"
        guard lowercased.hasPrefix(label) else { return nil }
        let remainder = value.dropFirst(label.count)
        guard remainder.isEmpty || remainder.first == ":" || remainder.first == " " || remainder.first == "\t" else {
            return nil
        }
        let payload = remainder.drop(while: { $0 == ":" || $0 == " " || $0 == "\t" })
        let result = String(payload).trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? nil : result
    }

    /// Accepts the native `!video:<url>` marker, a fenced `video` block, a
    /// Markdown link labelled video, and the simple HTML embeds commonly
    /// emitted by the web editor. The parser intentionally only treats a
    /// whole line as a video marker so ordinary prose containing a URL stays
    /// ordinary prose.
    static func videoURL(in line: String) -> String? {
        let value = normalizedMarkerLine(line)
        let lowercased = value.lowercased()
        let label = "!video"
        if lowercased.hasPrefix(label) {
            let remainder = value.dropFirst(label.count)
            guard remainder.isEmpty || remainder.first == ":" || remainder.first == " " || remainder.first == "\t" else {
                return nil
            }
            let payload = remainder.drop(while: { $0 == ":" || $0 == " " || $0 == "\t" })
            return cleanMediaURL(String(payload))
        }

        // The web editor stores provider videos as `bilibili:BV...[:page]`
        // or `youtube:VIDEO_ID` inside a fenced `video` block. Normalize the
        // provider spec to a regular web URL so native previews can render a
        // stable placeholder without attempting playback.
        if let providerURL = providerVideoURL(in: value) {
            return providerURL
        }

        if lowercased.hasPrefix("[video]("), value.last == ")" {
            let start = value.index(value.startIndex, offsetBy: "[video](".count)
            return cleanMediaURL(String(value[start..<value.index(before: value.endIndex)]))
        }

        if lowercased.contains("<video") || lowercased.contains("<iframe") || lowercased.contains("<embed") || lowercased.contains("<source") {
            return attributeValue("src", in: value) ?? attributeValue("data-src", in: value)
        }

        // A fenced video block may contain only a URL. Supporting direct
        // media links here also covers servers that omit the `!video` prefix.
        guard let url = cleanMediaURL(value), let parsed = URL(string: url),
              let scheme = parsed.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return nil
        }
        let path = parsed.path.lowercased()
        let isDirectVideo = [".mp4", ".mov", ".m4v", ".m3u8", ".webm", ".ogv", ".3gp"].contains { path.hasSuffix($0) }
        return isDirectVideo ? url : nil
    }

    /// Parses the site's `qqvip:id:type[:random|meta-...]` marker. Search
    /// results may include a percent-encoded metadata snapshot so the native
    /// preview can render the selected title and cover before another QQ
    /// request completes.
    static func musicMarker(from spec: String) -> MusicMarker? {
        let parts = normalizedMusicSpec(spec)
            .split(separator: ":", maxSplits: 3)
            .map(String.init)
        guard parts.count >= 3,
              parts[0].lowercased() == "qqvip" else { return nil }

        let id = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
        guard id.count >= 4, id.count <= 80,
              id.unicodeScalars.allSatisfy({ scalar in
                  scalar.value == 45 || scalar.value == 95
                      || (scalar.value >= 48 && scalar.value <= 57)
                      || (scalar.value >= 65 && scalar.value <= 90)
                      || (scalar.value >= 97 && scalar.value <= 122)
              }) else { return nil }

        let type = parts[2].lowercased()
        guard type == "song" || type == "playlist" else { return nil }

        let mode = parts.count == 4 ? parts[3].trimmingCharacters(in: .whitespacesAndNewlines) : ""
        var title: String?
        var artist: String?
        var cover: String?
        var metadataShuffle = false
        if let metadata = musicMetadata(from: mode) {
            title = firstNonEmptyString(in: metadata, keys: ["title", "name", "songname", "songName"])
            artist = firstNonEmptyString(in: metadata, keys: ["artist", "singer", "creator", "creatorName"])
            cover = firstNonEmptyString(in: metadata, keys: ["cover", "coverUrl", "coverURL", "cover_url", "image", "imageUrl", "image_url"])
            metadataShuffle = booleanValue(metadata["shuffle"]) || booleanValue(metadata["random"])
        } else if !mode.isEmpty && mode != "random" && mode != "shuffle" {
            return nil
        }

        return MusicMarker(
            id: id,
            type: type,
            shuffle: mode == "random" || mode == "shuffle" || metadataShuffle,
            title: title,
            artist: artist,
            cover: cover
        )
    }

    /// Creates the same compact marker format as the web editor. Metadata is
    /// optional, preserving compatibility with manually entered old markers.
    static func makeMusicSpec(
        id: String,
        type: String,
        shuffle: Bool = false,
        title: String? = nil,
        artist: String? = nil,
        cover: String? = nil
    ) -> String {
        let cleanID = id.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanType = type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let cleanTitle = title?.trimmedNonEmpty
        let cleanArtist = artist?.trimmedNonEmpty
        let cleanCover = cover?.trimmedNonEmpty
        let suffix = shuffle ? ":random" : ""

        guard cleanTitle != nil || cleanArtist != nil || cleanCover != nil else {
            return "qqvip:\(cleanID):\(cleanType)\(suffix)"
        }

        var metadata: [String: String] = [:]
        if let cleanTitle { metadata["title"] = cleanTitle }
        if let cleanArtist { metadata["artist"] = cleanArtist }
        if let cleanCover { metadata["cover"] = cleanCover }
        if shuffle { metadata["shuffle"] = "true" }
        guard let data = try? JSONSerialization.data(withJSONObject: metadata, options: []),
              let json = String(data: data, encoding: .utf8) else {
            return "qqvip:\(cleanID):\(cleanType)\(suffix)"
        }

        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-_.!~*'()")
        let encoded = json.addingPercentEncoding(withAllowedCharacters: allowed) ?? json
        return "qqvip:\(cleanID):\(cleanType):meta-\(encoded)"
    }

    private static func nonEmptyString(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        return value.trimmedNonEmpty
    }

    static func reference(from payload: String, references: [ArticleReferenceSnapshot]) -> ArticleReferenceSnapshot? {
        let cleanPayload = normalizedMarkerLine(payload)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let found = references.first(where: { referenceToken(for: $0) == cleanPayload }) {
            return found
        }

        let candidates = [
            cleanPayload.removingPercentEncoding,
            decodeBase64URL(cleanPayload),
        ].compactMap { $0 }
        for candidate in candidates {
            guard let data = candidate.data(using: .utf8) else { continue }
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            var objects = [object]
            for key in ["reference", "article", "data", "snapshot"] {
                if let nested = object[key] as? [String: Any] {
                    objects.append(nested)
                }
            }
            for object in objects {
                if let normalized = normalizedReferenceJSON(object),
                   let normalizedData = try? JSONSerialization.data(withJSONObject: normalized),
                   let snapshot = try? JSONDecoder().decode(ArticleReferenceSnapshot.self, from: normalizedData) {
                    return snapshot
                }
            }
        }

        // Older content sometimes stores only the URL after `!reference:`.
        // Preserve a useful native card instead of exposing an unresolved
        // marker when the server did not send a snapshot alongside the post.
        if let url = cleanMediaURL(cleanPayload),
           let parsed = URL(string: url),
           let scheme = parsed.scheme?.lowercased(), scheme == "http" || scheme == "https" {
            return ArticleReferenceSnapshot(
                url: url,
                canonicalURL: url,
                title: nil,
                source: nil,
                author: nil,
                publishedAt: nil,
                cover: nil,
                coverURL: nil,
                description: nil,
                summary: nil,
                keyPoints: nil
            )
        }
        return nil
    }

    /// Mirrors the blog's stable short token for `!reference:<token>`.
    static func referenceToken(for reference: ArticleReferenceSnapshot) -> String {
        let value = (reference.canonicalURL ?? reference.url ?? "")
        var first: UInt32 = 2_166_136_261
        var second: UInt32 = 2_246_825_519
        for scalar in value.unicodeScalars {
            first = (first ^ scalar.value) &* 16_777_619
            second = (second ^ scalar.value) &* 3_266_489_917
        }
        return "r\(base36(first))\(base36(second))"
    }

    private static func appendReference(_ payload: String, references: [ArticleReferenceSnapshot], to result: inout [MarkdownBlock]) {
        if let reference = reference(from: payload, references: references) {
            result.append(.reference(reference))
        } else {
            result.append(.unresolvedReference(payload))
        }
    }

    private static func normalizedReferenceJSON(_ object: [String: Any]) -> [String: Any]? {
        let value: ([String]) -> Any? = { keys in
            keys.lazy.compactMap { key in
                object[key] ?? object.first { $0.key.caseInsensitiveCompare(key) == .orderedSame }?.value
            }.first
        }
        guard let url = value(["u", "url", "link", "href", "canonicalUrl", "canonical_url", "c"]) else { return nil }
        var normalized: [String: Any] = ["url": url]
        let fields: [(String, [String])] = [
            ("canonicalUrl", ["c", "canonicalUrl", "canonical_url", "canonicalURL"]),
            ("title", ["t", "title", "name"]),
            ("source", ["s", "source", "sourceName", "source_name", "site", "domain"]),
            ("author", ["a", "author"]),
            ("publishedAt", ["d", "publishedAt", "published_at"]),
            ("cover", ["v", "cover", "image", "imageUrl", "image_url"]),
            ("cover_url", ["coverURL", "coverUrl", "cover_url"]),
            ("description", ["x", "description", "excerpt"]),
            ("summary", ["y", "summary"]),
            ("keyPoints", ["p", "keyPoints", "key_points"]),
        ]
        for (key, keys) in fields {
            if let item = value(keys) { normalized[key] = item }
        }
        return normalized
    }

    private static func decodeBase64URL(_ value: String) -> String? {
        let base64 = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            .padding(toLength: ((value.count + 3) / 4) * 4, withPad: "=", startingAt: 0)
        guard let data = Data(base64Encoded: base64) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func base36(_ value: UInt32) -> String {
        let result = String(value, radix: 36)
        return String(repeating: "0", count: max(0, 7 - result.count)) + result
    }

    private static func fencedCodeStart(_ line: String) -> FenceStart? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let marker = trimmed.first, marker == "`" || marker == "~" else { return nil }
        let markerCount = trimmed.prefix { $0 == marker }.count
        guard markerCount >= 3 else { return nil }
        let language = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespacesAndNewlines)
        return FenceStart(language: language.isEmpty ? nil : language.lowercased(), marker: marker)
    }

    private static func isFenceEnd(_ line: String, marker: Character) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.first == marker else { return false }
        return trimmed.prefix { $0 == marker }.count >= 3
    }

    private static func heading(in line: String) -> (level: Int, text: String)? {
        let leading = line.prefix { $0 == "#" }
        guard !leading.isEmpty, leading.count <= 6 else { return nil }
        let rest = line.dropFirst(leading.count)
        guard rest.first == " " || rest.first == "\t" else { return nil }
        return (leading.count, String(rest).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func image(in line: String) -> (url: String, alt: String)? {
        let value = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.hasPrefix("!["), let endAlt = value.firstIndex(of: "]"), endAlt < value.endIndex else { return nil }
        let afterAlt = value.index(after: endAlt)
        guard afterAlt < value.endIndex, value[afterAlt] == "(" else { return nil }
        guard value.last == ")" else { return nil }
        let urlStart = value.index(after: afterAlt)
        let inside = String(value[urlStart..<value.index(before: value.endIndex)])
        let parts = inside.split(separator: " ", maxSplits: 1).map(String.init)
        guard let url = parts.first, !url.isEmpty else { return nil }
        let altStart = value.index(value.startIndex, offsetBy: 2)
        return (url, String(value[altStart..<endAlt]))
    }

    private static func unorderedItem(in line: String) -> String? {
        let value = line.trimmingCharacters(in: .whitespaces)
        for marker in ["- ", "* ", "+ "] where value.hasPrefix(marker) {
            return String(value.dropFirst(marker.count))
        }
        return nil
    }

    private static func orderedItem(in line: String) -> String? {
        let value = line.trimmingCharacters(in: .whitespaces)
        guard let dot = value.firstIndex(of: "."), dot > value.startIndex else { return nil }
        let number = value[..<dot]
        guard !number.isEmpty, number.allSatisfy({ $0.isNumber }) else { return nil }
        let after = value.index(after: dot)
        guard after < value.endIndex, value[after] == " " else { return nil }
        return String(value[value.index(after: after)...])
    }

    private static func isDivider(_ line: String) -> Bool {
        let value = line.trimmingCharacters(in: .whitespaces)
        return value == "---" || value == "***" || value == "___"
    }

    private static func isStructuralLine(_ line: String) -> Bool {
        fencedCodeStart(line) != nil || referencePayload(in: line) != nil || heading(in: line) != nil
            || musicPayload(in: line) != nil || videoURL(in: line) != nil || image(in: line) != nil || isDivider(line) || line.trimmingCharacters(in: .whitespaces).hasPrefix(">")
            || unorderedItem(in: line) != nil || orderedItem(in: line) != nil
    }

    private static func normalizedMarkerLine(_ value: String) -> String {
        var result = value.trimmingCharacters(in: .whitespacesAndNewlines)
        while result.count >= 2,
              result.first == "`" && result.last == "`" {
            result.removeFirst()
            result.removeLast()
            result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return result
    }

    private static func normalizedMusicSpec(_ value: String) -> String {
        var result = normalizedMarkerLine(value)
        if result.lowercased().hasPrefix("!music") {
            result = musicPayload(in: result) ?? result
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func cleanMediaURL(_ value: String) -> String? {
        var result = value.trimmingCharacters(in: .whitespacesAndNewlines)
        while result.count >= 2,
              ((result.first == "`" && result.last == "`") || (result.first == "<" && result.last == ">")
               || (result.first == "\"" && result.last == "\"") || (result.first == "'" && result.last == "'")) {
            result.removeFirst()
            result.removeLast()
            result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let separator = result.firstIndex(of: "|") {
            result = String(result[..<separator]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return result.isEmpty ? nil : result
    }

    private static func providerVideoURL(in value: String) -> String? {
        let parts = value.split(separator: ":", maxSplits: 2).map(String.init)
        guard parts.count >= 2 else { return nil }

        let platform = parts[0].lowercased()
        let identifier = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !identifier.isEmpty else { return nil }

        if platform == "bilibili" {
            let lowercasedID = identifier.lowercased()
            let isBV = lowercasedID.hasPrefix("bv")
                && identifier.count > 2
                && identifier.dropFirst(2).unicodeScalars.allSatisfy(Self.isVideoIdentifierScalar)
            let isAV = lowercasedID.hasPrefix("av")
                && identifier.count > 2
                && identifier.dropFirst(2).unicodeScalars.allSatisfy { $0.value >= 48 && $0.value <= 57 }
            guard isBV || isAV else { return nil }

            var components = URLComponents(string: "https://www.bilibili.com/video/\(identifier)")
            if parts.count == 3,
               let page = Int(parts[2].trimmingCharacters(in: .whitespacesAndNewlines)),
               page > 1 {
                components?.queryItems = [URLQueryItem(name: "p", value: String(page))]
            }
            return components?.url?.absoluteString
        }

        guard platform == "youtube",
              identifier.count == 11,
              identifier.unicodeScalars.allSatisfy(Self.isVideoIdentifierScalar) else {
            return nil
        }
        var components = URLComponents(string: "https://www.youtube.com/watch")
        components?.queryItems = [URLQueryItem(name: "v", value: identifier)]
        return components?.url?.absoluteString
    }

    private static func isVideoIdentifierScalar(_ scalar: Unicode.Scalar) -> Bool {
        (scalar.value >= 48 && scalar.value <= 57)
            || (scalar.value >= 65 && scalar.value <= 90)
            || (scalar.value >= 97 && scalar.value <= 122)
            || scalar.value == 45
            || scalar.value == 95
    }

    private static func attributeValue(_ name: String, in value: String) -> String? {
        let escapedName = NSRegularExpression.escapedPattern(for: name)
        let pattern = #"(?i)\b\#(escapedName)\s*=\s*[\"']([^\"']+)[\"']"#
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
              let range = Range(match.range(at: 1), in: value) else { return nil }
        return cleanMediaURL(String(value[range]))
    }

    private static func musicMetadata(from mode: String) -> [String: Any]? {
        let prefixes = ["meta-", "meta_", "meta:", "json-"]
        guard let prefix = prefixes.first(where: { mode.lowercased().hasPrefix($0) }) else { return nil }
        let encoded = String(mode.dropFirst(prefix.count))
        let candidates = [
            encoded.removingPercentEncoding,
            decodeBase64URL(encoded),
            Data(base64Encoded: encoded).flatMap { String(data: $0, encoding: .utf8) },
        ].compactMap { $0 }
        for candidate in candidates {
            guard let data = candidate.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            return object
        }
        return nil
    }

    private static func firstNonEmptyString(in object: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = nonEmptyString(object[key]) { return value }
            if let value = object.first(where: { $0.key.caseInsensitiveCompare(key) == .orderedSame }).flatMap({ nonEmptyString($0.value) }) {
                return value
            }
        }
        return nil
    }

    private static func booleanValue(_ value: Any?) -> Bool {
        if let value = value as? Bool { return value }
        if let value = value as? NSNumber { return value.boolValue }
        guard let value = (value as? String)?.lowercased() else { return false }
        return value == "1" || value == "true" || value == "yes" || value == "random" || value == "shuffle"
    }
}
