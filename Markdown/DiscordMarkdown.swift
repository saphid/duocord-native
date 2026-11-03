import Foundation

/// Discord's markdown dialect as a small AST.
nonisolated indirect enum MDInline: Equatable, Sendable {
    case text(String)
    case bold([MDInline])
    case italic([MDInline])
    case underline([MDInline])
    case strike([MDInline])
    case spoiler([MDInline])
    case code(String)
    case link(label: [MDInline], url: String)
    case autolink(String)
    case userMention(Snowflake)
    case roleMention(Snowflake)
    case channelMention(Snowflake)
    case everyone(String)
    case customEmoji(name: String, id: Snowflake, animated: Bool)
    case timestamp(Int, style: Character)
    case lineBreak
}

nonisolated enum MDBlock: Equatable, Sendable {
    case paragraph([MDInline])
    case heading(level: Int, [MDInline])
    case subtext([MDInline])
    case quote([MDBlock])
    case codeBlock(language: String?, code: String)
    case listItem(marker: String, depth: Int, [MDInline])
}

nonisolated enum DiscordMarkdown {
    static func parse(_ source: String) -> [MDBlock] {
        var blocks: [MDBlock] = []
        var paragraph: [String] = []
        var quoteLines: [String] = []
        let lines = source.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var index = 0

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            blocks.append(.paragraph(parseInline(paragraph.joined(separator: "\n"))))
            paragraph.removeAll()
        }
        func flushQuote() {
            guard !quoteLines.isEmpty else { return }
            blocks.append(.quote(parse(quoteLines.joined(separator: "\n"))))
            quoteLines.removeAll()
        }

        while index < lines.count {
            var line = lines[index]
            // A fence can start mid-line: text before it is a paragraph.
            if let fence = line.range(of: "```"), !line[..<fence.lowerBound].trimmingCharacters(in: .whitespaces).isEmpty,
               line[fence.upperBound...].range(of: "```") == nil || lines.count > index + 1 {
                let before = String(line[..<fence.lowerBound])
                if line[fence.upperBound...].range(of: "```") == nil {
                    flushQuote()
                    paragraph.append(before)
                    flushParagraph()
                    line = String(line[fence.lowerBound...])
                }
            }
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Fenced code block (may start mid-line content-wise but Discord needs ``` at line start or inline).
            if trimmed.hasPrefix("```") {
                flushParagraph(); flushQuote()
                var afterFence = String(trimmed.dropFirst(3))
                // Single-line ```code```.
                if afterFence.hasSuffix("```"), afterFence.count >= 3 {
                    afterFence.removeLast(3)
                    blocks.append(.codeBlock(language: nil, code: afterFence))
                    index += 1
                    continue
                }
                let language = afterFence.trimmingCharacters(in: .whitespaces)
                var code: [String] = []
                let hasLanguage = !language.isEmpty && !language.contains(" ")
                if !hasLanguage, !afterFence.isEmpty { code.append(afterFence) }
                index += 1
                var closed = false
                while index < lines.count {
                    let codeLine = lines[index]
                    if let range = codeLine.range(of: "```") {
                        let before = String(codeLine[..<range.lowerBound])
                        if !before.isEmpty { code.append(before) }
                        closed = true
                        index += 1
                        break
                    }
                    code.append(codeLine)
                    index += 1
                }
                if !closed && code.isEmpty {
                    paragraph.append(line)
                    continue
                }
                blocks.append(.codeBlock(language: hasLanguage ? language : nil, code: code.joined(separator: "\n")))
                continue
            }

            if trimmed.hasPrefix(">>> ") || trimmed == ">>>" {
                flushParagraph(); flushQuote()
                var rest = [String(trimmed.dropFirst(trimmed == ">>>" ? 3 : 4))]
                rest += lines[(index + 1)...]
                blocks.append(.quote(parse(rest.joined(separator: "\n"))))
                return blocks
            }
            if trimmed.hasPrefix("> ") || trimmed == ">" {
                flushParagraph()
                quoteLines.append(String(trimmed.dropFirst(trimmed == ">" ? 1 : 2)))
                index += 1
                continue
            }
            flushQuote()

            if let (level, text) = heading(trimmed) {
                flushParagraph()
                blocks.append(.heading(level: level, parseInline(text)))
            } else if trimmed.hasPrefix("-# ") {
                flushParagraph()
                blocks.append(.subtext(parseInline(String(trimmed.dropFirst(3)))))
            } else if let (marker, depth, text) = listItem(line) {
                flushParagraph()
                blocks.append(.listItem(marker: marker, depth: depth, parseInline(text)))
            } else {
                paragraph.append(line)
            }
            index += 1
        }
        flushParagraph(); flushQuote()
        return blocks
    }

    private static func heading(_ line: String) -> (Int, String)? {
        for level in 1...3 {
            let prefix = String(repeating: "#", count: level) + " "
            if line.hasPrefix(prefix) {
                let text = String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
                return text.isEmpty ? nil : (level, text)
            }
        }
        return nil
    }

    private static func listItem(_ line: String) -> (String, Int, String)? {
        let leading = line.prefix { $0 == " " }.count
        let rest = line.dropFirst(leading)
        let depth = min(leading / 2, 3)
        if rest.hasPrefix("- ") || rest.hasPrefix("* ") {
            return ("•", depth, String(rest.dropFirst(2)))
        }
        let digits = rest.prefix { $0.isNumber }
        if !digits.isEmpty, digits.count <= 9, rest.dropFirst(digits.count).hasPrefix(". ") {
            return ("\(digits).", depth, String(rest.dropFirst(digits.count + 2)))
        }
        return nil
    }

    // MARK: Inline

    static func parseInline(_ source: String) -> [MDInline] {
        var parser = InlineParser(Array(source))
        return parser.parse(until: nil)
    }
}

nonisolated private struct InlineParser {
    let chars: [Character]
    var index = 0

    init(_ chars: [Character]) { self.chars = chars }

    mutating func parse(until terminator: String?) -> [MDInline] {
        var result: [MDInline] = []
        var text = ""
        func flush() {
            if !text.isEmpty { result.append(.text(text)); text = "" }
        }
        while index < chars.count {
            if let terminator, matches(terminator) { break }
            let c = chars[index]
            if c == "\\", index + 1 < chars.count, "*_~|`<>#-:[]()\\@".contains(chars[index + 1]) {
                text.append(chars[index + 1]); index += 2; continue
            }
            if c == "\n" { flush(); result.append(.lineBreak); index += 1; continue }
            if c == "`" {
                let fence = matches("``") ? "``" : "`"
                if let close = find(fence, from: index + fence.count), close > index + fence.count {
                    flush()
                    var code = String(chars[(index + fence.count)..<close])
                    if fence == "``" { code = code.trimmingCharacters(in: .whitespaces) }
                    result.append(.code(code))
                    index = close + fence.count
                    continue
                }
            }
            if let (node, length) = delimited(at: index) {
                flush(); result.append(node); index += length; continue
            }
            if c == "<", let (node, length) = angle(at: index) {
                flush(); result.append(node); index += length; continue
            }
            if c == "[", let (node, length) = maskedLink(at: index) {
                flush(); result.append(node); index += length; continue
            }
            if c == "h", let (url, length) = autolink(at: index) {
                flush(); result.append(.autolink(url)); index += length; continue
            }
            if c == "@", matches("@everyone") || matches("@here") {
                flush()
                let word = matches("@everyone") ? "@everyone" : "@here"
                result.append(.everyone(word)); index += word.count; continue
            }
            text.append(c)
            index += 1
        }
        flush()
        return result
    }

    private func matches(_ token: String) -> Bool {
        let tokenChars = Array(token)
        guard index + tokenChars.count <= chars.count else { return false }
        for (offset, char) in tokenChars.enumerated() where chars[index + offset] != char { return false }
        return true
    }

    private func find(_ token: String, from start: Int) -> Int? {
        let tokenChars = Array(token)
        var i = start
        while i + tokenChars.count <= chars.count {
            var ok = true
            for (offset, char) in tokenChars.enumerated() where chars[i + offset] != char { ok = false; break }
            if ok { return i }
            i += 1
        }
        return nil
    }

    /// **bold**, __underline__, ~~strike~~, ||spoiler||, *italic*, _italic_.
    private mutating func delimited(at start: Int) -> (MDInline, Int)? {
        let options: [(String, ([MDInline]) -> MDInline)] = [
            ("***", { .bold([.italic($0)]) }),
            ("**", { .bold($0) }), ("__", { .underline($0) }), ("~~", { .strike($0) }), ("||", { .spoiler($0) }),
            ("*", { .italic($0) }), ("_", { .italic($0) }),
        ]
        for (token, make) in options where matches(token) {
            let open = start + token.count
            guard open < chars.count, !chars[open].isWhitespace || token == "||" else { continue }
            guard let close = findClosing(token, from: open), close > open else { continue }
            // Underscore italics need word boundaries.
            if token == "_", close + 1 < chars.count, chars[close + 1].isLetter || chars[close + 1].isNumber { continue }
            var inner = InlineParser(Array(chars[open..<close]))
            let children = inner.parse(until: nil)
            return (make(children), close + token.count - start)
        }
        return nil
    }

    private func findClosing(_ token: String, from start: Int) -> Int? {
        var i = start
        let tokenChars = Array(token)
        while i + tokenChars.count <= chars.count {
            if chars[i] == "\\" { i += 2; continue }
            if chars[i] == "`" , let close = find("`", from: i + 1) { i = close + 1; continue }
            var ok = true
            for (offset, char) in tokenChars.enumerated() where chars[i + offset] != char { ok = false; break }
            if ok {
                // For single * don't close on ** (part of bold) unless it is the end.
                if token == "*", i + 1 < chars.count, chars[i + 1] == "*" { i += 2; continue }
                if token != "||", i > start, chars[i - 1].isWhitespace { i += 1; continue }
                return i
            }
            i += 1
        }
        return nil
    }

    /// <@id>, <@!id>, <@&id>, <#id>, <:name:id>, <a:name:id>, <t:unix:style>, <https://...>.
    private func angle(at start: Int) -> (MDInline, Int)? {
        guard let close = find(">", from: start + 1), close - start < 200 else { return nil }
        let inner = String(chars[(start + 1)..<close])
        let length = close - start + 1
        if inner.hasPrefix("@&"), let id = Snowflake(String(inner.dropFirst(2))) { return (.roleMention(id), length) }
        if inner.hasPrefix("@!"), let id = Snowflake(String(inner.dropFirst(2))) { return (.userMention(id), length) }
        if inner.hasPrefix("@"), let id = Snowflake(String(inner.dropFirst(1))) { return (.userMention(id), length) }
        if inner.hasPrefix("#"), let id = Snowflake(String(inner.dropFirst(1))) { return (.channelMention(id), length) }
        if inner.hasPrefix("t:") {
            let parts = inner.split(separator: ":")
            if parts.count >= 2, let unix = Int(parts[1]) {
                let style = parts.count > 2 ? parts[2].first ?? "f" : "f"
                return (.timestamp(unix, style: style), length)
            }
        }
        if inner.hasPrefix(":") || inner.hasPrefix("a:") {
            let animated = inner.hasPrefix("a:")
            let parts = inner.dropFirst(animated ? 2 : 1).split(separator: ":")
            if parts.count == 2, let id = Snowflake(String(parts[1])) {
                return (.customEmoji(name: String(parts[0]), id: id, animated: animated), length)
            }
        }
        if inner.hasPrefix("http://") || inner.hasPrefix("https://"), !inner.contains(" ") {
            return (.autolink(inner), length)
        }
        return nil
    }

    private func maskedLink(at start: Int) -> (MDInline, Int)? {
        guard let closeBracket = find("](", from: start + 1),
              let closeParen = find(")", from: closeBracket + 2) else { return nil }
        let label = String(chars[(start + 1)..<closeBracket])
        var url = String(chars[(closeBracket + 2)..<closeParen])
        if url.hasPrefix("<"), url.hasSuffix(">") { url = String(url.dropFirst().dropLast()) }
        guard url.hasPrefix("https://") || url.hasPrefix("http://"), !url.contains(" "), !label.isEmpty else { return nil }
        var parser = InlineParser(Array(label))
        return (.link(label: parser.parse(until: nil), url: url), closeParen - start + 1)
    }

    private func autolink(at start: Int) -> (String, Int)? {
        guard matches("https://") || matches("http://") else { return nil }
        var end = start
        while end < chars.count, !chars[end].isWhitespace, chars[end] != "<" { end += 1 }
        // Trailing punctuation is not part of the URL.
        while end > start, ".,:;!?\"')]".contains(chars[end - 1]) {
            if chars[end - 1] == ")", chars[start..<end].contains("(") { break }
            end -= 1
        }
        let url = String(chars[start..<end])
        return url.count > 8 ? (url, end - start) : nil
    }
}
