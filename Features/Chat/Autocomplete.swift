import Foundation

/// A readable token the composer inserted ("@Aurora", "#general",
/// ":ship_it:") and what Discord gets for it ("<@id>", "<#id>", "<:ship_it:id>").
nonisolated struct ComposerToken: Equatable, Hashable, Sendable {
    var display: String
    var wire: String
    /// The exact occurrence in the draft, measured in Characters.
    var range: Range<Int>
}

/// Composer autocomplete: finds the `@`, `:` or `#` word being typed at the
/// cursor, ranks suggestions for it, and turns the readable tokens it
/// inserted back into Discord's wire form on send. Offsets are in
/// Characters, as the composer counts them.
nonisolated enum Autocomplete {
    enum Trigger: Character, Sendable {
        case mention = "@", emoji = ":", channel = "#"
    }

    struct Query: Equatable, Hashable, Sendable {
        var trigger: Trigger
        /// What follows the trigger, up to the cursor.
        var text: String
        /// The trigger through the end of the word: replaced on accept.
        var range: Range<Int>
    }

    /// Emoji suggestions wait for two characters (":)" and "12:30" stay quiet).
    static let emojiMinimum = 2

    // MARK: Finding the query

    /// The suggestion query at `cursor`, if the word there starts with a
    /// trigger at a word boundary and isn't inside code.
    static func query(in text: String, cursor: Int) -> Query? {
        let chars = Array(text)
        let cursor = min(max(cursor, 0), chars.count)
        var index = cursor - 1
        while index >= 0, !chars[index].isWhitespace {
            if let trigger = Trigger(rawValue: chars[index]) {
                // "a@b", "12:30" and "https://" aren't triggers.
                if index > 0, isWordChar(chars[index - 1]) || Trigger(rawValue: chars[index - 1]) != nil { return nil }
                let typed = chars[(index + 1)..<cursor]
                guard isValid(typed, for: trigger) else { return nil }
                guard !codeMask(chars, unclosedIsCode: true)[index] else { return nil }
                var end = cursor
                while end < chars.count, !chars[end].isWhitespace { end += 1 }
                return Query(trigger: trigger, text: String(typed), range: index..<end)
            }
            index -= 1
        }
        return nil
    }

    private static func isValid(_ typed: ArraySlice<Character>, for trigger: Trigger) -> Bool {
        switch trigger {
        case .mention, .channel:
            return typed.count <= 32 && !typed.contains { "<>`".contains($0) }
        case .emoji:
            return typed.count >= emojiMinimum && typed.count <= 32
                && typed.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "_-+".contains($0)) }
        }
    }

    static func isWordChar(_ char: Character) -> Bool {
        char.isLetter || char.isNumber || char == "_" || char == "-"
    }

    /// Which characters sit inside inline code or a code block (backticks
    /// included). While typing, an unclosed backtick or fence already counts
    /// as code; Discord itself only treats closed ones as code.
    static func codeMask(_ chars: [Character], unclosedIsCode: Bool) -> [Bool] {
        var mask = Array(repeating: false, count: chars.count)
        func starts(_ token: String, at i: Int) -> Bool {
            let t = Array(token)
            return i + t.count <= chars.count && Array(chars[i..<(i + t.count)]) == t
        }
        func find(_ token: String, from start: Int) -> Int? {
            var i = start
            while i < chars.count {
                if starts(token, at: i) { return i }
                i += 1
            }
            return nil
        }
        var i = 0
        while i < chars.count {
            if chars[i] == "\\" { i += 2; continue }
            let fence = starts("```", at: i)
            let token = fence ? "```" : "`"
            guard chars[i] == "`" else { i += 1; continue }
            if let close = find(token, from: i + token.count) {
                let end = close + token.count
                for j in i..<end { mask[j] = true }
                i = end
            } else {
                if unclosedIsCode { for j in i..<chars.count { mask[j] = true } }
                break
            }
        }
        return mask
    }

    // MARK: Inserting and sending

    /// Replaces the query with `display` and one space; the cursor lands after the space.
    static func insert(_ display: String, replacing range: Range<Int>, in text: String) -> (text: String, cursor: Int) {
        let chars = Array(text)
        let lower = min(range.lowerBound, chars.count), upper = min(max(range.upperBound, lower), chars.count)
        let rest = chars[upper...]
        let spaced = rest.first?.isWhitespace == true
        let result = String(chars[..<lower]) + display + (spaced ? "" : " ") + String(rest)
        return (result, lower + display.count + 1)
    }

    /// Moves tokens through one known text replacement. Editing a token
    /// invalidates it; equal-looking text elsewhere never inherits its ID.
    static func rebase(_ tokens: [ComposerToken], replacing range: Range<Int>, replacementCount: Int) -> [ComposerToken] {
        let delta = replacementCount - range.count
        return tokens.compactMap { token in
            if token.range.upperBound <= range.lowerBound { return token }
            if token.range.lowerBound >= range.upperBound {
                var moved = token
                moved.range = (token.range.lowerBound + delta)..<(token.range.upperBound + delta)
                return moved
            }
            return nil
        }
    }

    /// UIKit edits use UTF-16 offsets. Map each untouched occurrence through
    /// those offsets first, then find its new Character range. A replacement
    /// can merge adjacent graphemes even when its own Character count is one.
    static func rebase(_ tokens: [ComposerToken], in old: String, replacing edit: NSRange, with replacement: String) -> [ComposerToken] {
        guard let edited = Range(edit, in: old) else { return [] }
        let new = old.replacingCharacters(in: edited, with: replacement)
        let delta = replacement.utf16.count - edit.length
        var boundaries = Set(new.indices)
        boundaries.insert(new.endIndex)
        return tokens.compactMap { token in
            guard token.range.lowerBound >= 0, token.range.upperBound <= old.count else { return nil }
            let start = old.index(old.startIndex, offsetBy: token.range.lowerBound)
            let end = old.index(old.startIndex, offsetBy: token.range.upperBound)
            var range = NSRange(start..<end, in: old)
            if NSMaxRange(range) <= edit.location { /* untouched before the edit */ }
            else if range.location >= NSMaxRange(edit) { range.location += delta }
            else { return nil }
            guard let mapped = Range(range, in: new), boundaries.contains(mapped.lowerBound), boundaries.contains(mapped.upperBound),
                  String(new[mapped]) == token.display else { return nil }
            var moved = token
            moved.range = new.distance(from: new.startIndex, to: mapped.lowerBound)..<new.distance(from: new.startIndex, to: mapped.upperBound)
            return moved
        }
    }

    /// String bindings supply old/new text rather than an edit range. Find
    /// the smallest replacement. Repeated text can make its location
    /// ambiguous: retain a token only if both possible extremes preserve
    /// the same occurrence. Dropping metadata is safer than guessing an ID.
    static func rebase(_ tokens: [ComposerToken], from old: String, to new: String) -> [ComposerToken] {
        guard old != new, !tokens.isEmpty else { return tokens }
        let before = Array(old), after = Array(new)
        let shorter = min(before.count, after.count)
        var prefix = 0, suffix = 0
        while prefix < shorter, before[prefix] == after[prefix] { prefix += 1 }
        while suffix < shorter, before[before.count - suffix - 1] == after[after.count - suffix - 1] { suffix += 1 }
        let kept = min(shorter, prefix + suffix)
        let first = max(0, kept - suffix), last = min(prefix, kept)
        let removed = before.count - kept, inserted = after.count - kept
        return tokens.compactMap { token in
            let left = rebase([token], replacing: first..<(first + removed), replacementCount: inserted).first
            let right = rebase([token], replacing: last..<(last + removed), replacementCount: inserted).first
            return left == right ? left : nil
        }
    }

    /// Serialize only selected occurrences that are still intact, at word
    /// boundaries and outside code. Literal names stay literal.
    static func wireText(_ text: String, tokens: [ComposerToken]) -> String {
        let chars = Array(text)
        let code = codeMask(chars, unclosedIsCode: false)
        var output = "", cursor = 0
        for token in tokens.sorted(by: { $0.range.lowerBound < $1.range.lowerBound }) {
            let start = token.range.lowerBound, end = token.range.upperBound
            guard start >= cursor, start >= 0, end <= chars.count, start < end,
                  String(chars[start..<end]) == token.display,
                  !code[start..<end].contains(true),
                  start == 0 || !isWordChar(chars[start - 1]),
                  end == chars.count || !isWordChar(chars[end]) || token.display.last.map(isWordChar) != true else { continue }
            output += String(chars[cursor..<start]) + token.wire
            cursor = end
        }
        return output + String(chars[cursor...])
    }

    /// Typed `:name:` shortcodes (closing the colon instead of picking a
    /// suggestion) become emoji when `resolve` knows them, as Discord's
    /// clients do on send. Code and existing `<…>` tokens are left alone.
    static func replacingShortcodes(in text: String, resolve: (String) -> String?) -> String {
        guard text.contains(":") else { return text }
        let chars = Array(text)
        let code = codeMask(chars, unclosedIsCode: false)
        var output = ""
        var i = 0
        while i < chars.count {
            if chars[i] == "<", !code[i], let close = chars[i...].prefix(120).firstIndex(of: ">") {
                output += String(chars[i...close])
                i = close + 1
                continue
            }
            if chars[i] == ":", !code[i], i == 0 || !isWordChar(chars[i - 1]),
               let close = chars[(i + 1)...].prefix(33).firstIndex(of: ":"), close > i + 1,
               close + 1 == chars.count || !isWordChar(chars[close + 1]) {
                let name = String(chars[(i + 1)..<close])
                if name.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "_-+".contains($0)) }), let emoji = resolve(name) {
                    output += emoji
                    i = close + 1
                    continue
                }
            }
            output.append(chars[i])
            i += 1
        }
        return output
    }

    /// Standard emoji, in picker order, for suggestions.
    static let standardEntries: [EmojiEntry] = EmojiCatalog.groups.flatMap(\.entries)

    /// Shortcode → standard emoji ("red_heart" → "❤️"); the first of any duplicates wins.
    static let standardEmoji: [String: String] = Dictionary(
        standardEntries.compactMap { entry in entry.emoji.name.map { (shortcode(entry.name), $0) } },
        uniquingKeysWith: { first, _ in first })

    /// Wire form back to readable text and tokens (editing a sent message):
    /// mentions, channels and custom emoji outside code. Unknown IDs stay raw.
    static func readable(_ content: String, user: (Snowflake) -> String?, role: (Snowflake) -> String?,
                         channel: (Snowflake) -> String?) -> (text: String, tokens: [ComposerToken]) {
        let chars = Array(content)
        let code = codeMask(chars, unclosedIsCode: false)
        var output = ""
        var tokens: [ComposerToken] = []
        var i = 0
        while i < chars.count {
            if chars[i] == "<", !code[i], let close = chars[i...].prefix(120).firstIndex(of: ">") {
                let wire = String(chars[i...close])
                let inner = String(chars[(i + 1)..<close])
                var display: String?
                if inner.hasPrefix("@&"), let id = Snowflake(String(inner.dropFirst(2))) {
                    display = role(id).map { "@\($0)" }
                } else if inner.hasPrefix("@"), let id = Snowflake(String(inner.drop { $0 == "@" || $0 == "!" })) {
                    display = user(id).map { "@\($0)" }
                } else if inner.hasPrefix("#"), let id = Snowflake(String(inner.dropFirst())) {
                    display = channel(id).map { "#\($0)" }
                } else if inner.hasPrefix(":") || inner.hasPrefix("a:") {
                    let parts = inner.dropFirst(inner.hasPrefix("a:") ? 2 : 1).split(separator: ":")
                    if parts.count == 2, Snowflake(String(parts[1])) != nil { display = ":\(parts[0]):" }
                }
                if let display {
                    let start = output.count
                    output += display
                    tokens.append(ComposerToken(display: display, wire: wire, range: start..<(start + display.count)))
                    i = close + 1
                    continue
                }
            }
            output.append(chars[i])
            i += 1
        }
        return (output, tokens)
    }

    // MARK: Suggestions

    enum Suggestion: Equatable, Identifiable, Sendable {
        case member(User, name: String)
        case role(Role)
        /// "everyone" or "here".
        case mass(String)
        /// `name` is the shortcode without colons.
        case emoji(Emoji, name: String)
        case channel(Channel)

        var id: String {
            switch self {
            case .member(let user, _): "u\(user.id)"
            case .role(let role): "r\(role.id)"
            case .mass(let word): "m\(word)"
            case .emoji(let emoji, let name): "e\(emoji.id?.description ?? name)"
            case .channel(let channel): "c\(channel.id)"
            }
        }

        /// What the field shows, and what Discord gets when that differs.
        var insertion: (display: String, wire: String?) {
            switch self {
            case .member(let user, let name): ("@\(name)", "<@\(user.id)>")
            case .role(let role): ("@\(role.name)", "<@&\(role.id)>")
            case .mass(let word): ("@\(word)", nil)
            case .emoji(let emoji, let name):
                if let id = emoji.id { (":\(name):", "<\(emoji.animated == true ? "a" : ""):\(name):\(id)>") } else { (emoji.name ?? "", nil) }
            case .channel(let channel): ("#\(channel.name ?? "")", "<#\(channel.id)>")
            }
        }
    }

    struct MentionCandidate: Sendable {
        var user: User
        /// The name shown in this conversation (nickname first).
        var name: String
        var nick: String?
        /// Position among the conversation's recent authors (0 newest); nil if not recent.
        var recency: Int?
    }

    static func fold(_ string: String) -> String {
        string.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }

    /// 0 exact, 1 prefix, 2 a later word starts with it, 3 contains; nil no match.
    /// `query` must already be folded.
    static func tier(_ name: String?, _ query: String, allowContains: Bool = true) -> Int? {
        guard let name, !name.isEmpty else { return nil }
        if query.isEmpty { return 1 }
        let folded = fold(name)
        if folded == query { return 0 }
        if folded.hasPrefix(query) { return 1 }
        let words = folded.split(whereSeparator: { " _-.".contains($0) })
        if words.dropFirst().contains(where: { $0.hasPrefix(query) }) { return 2 }
        return allowContains && folded.contains(query) ? 3 : nil
    }

    /// Members by best match on name, nickname, global name or username;
    /// recent authors first within a tier, then alphabetical.
    static func rankMembers(_ candidates: [MentionCandidate], query: String, limit: Int) -> [MentionCandidate] {
        let q = fold(query)
        let scored: [(MentionCandidate, Int)] = candidates.compactMap { candidate in
            let tiers = [candidate.name, candidate.nick, candidate.user.globalName, candidate.user.username].compactMap { tier($0, q) }
            return tiers.min().map { (candidate, $0) }
        }
        return scored.sorted { a, b in
            if a.1 != b.1 { return a.1 < b.1 }
            let ra = a.0.recency ?? .max, rb = b.0.recency ?? .max
            if ra != rb { return ra < rb }
            let na = fold(a.0.name), nb = fold(b.0.name)
            return na != nb ? na < nb : a.0.user.id < b.0.user.id
        }.prefix(limit).map(\.0)
    }

    /// Members, then roles, then @everyone/@here (when allowed), as Discord
    /// lists them; up to three slots stay for roles when members overflow.
    static func mentionSuggestions(members: [MentionCandidate], roles: [Role], massMentions: Bool, query: String,
                                   limit: Int = 10) -> [Suggestion] {
        let q = fold(query)
        let matchedRoles = roles.compactMap { role in tier(role.name, q).map { (role, $0) } }
            .sorted { $0.1 != $1.1 ? $0.1 < $1.1 : $0.0.position > $1.0.position }
            .map { Suggestion.role($0.0) }
        let mass = massMentions ? ["everyone", "here"].filter { tier($0, q) != nil }.map(Suggestion.mass) : []
        let others = matchedRoles + mass
        let people = rankMembers(members, query: query, limit: limit - min(others.count, 3))
        return Array((people.map { Suggestion.member($0.user, name: $0.name) } + others).prefix(limit))
    }

    /// The server's own emoji first, then standard emoji; recently used
    /// (then popular, as the caller lists them) first within each match tier.
    static func emojiSuggestions(custom: [Emoji], unicode: [EmojiEntry], recent: [String], query: String,
                                 limit: Int = 10) -> [Suggestion] {
        let q = fold(query)
        let recentRank = Dictionary(recent.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        // Shorter names first within a tier ("fire" before "firecracker").
        func rank<T>(_ items: [(T, tier: Int, key: String, length: Int, order: Int)]) -> [T] {
            items.sorted { a, b in
                if a.tier != b.tier { return a.tier < b.tier }
                let ra = recentRank[a.key] ?? .max, rb = recentRank[b.key] ?? .max
                if ra != rb { return ra < rb }
                return a.length != b.length ? a.length < b.length : a.order < b.order
            }.map(\.0)
        }
        let server = rank(custom.enumerated().compactMap { index, emoji -> (Suggestion, tier: Int, key: String, length: Int, order: Int)? in
            guard let name = emoji.name, let t = tier(name, q) else { return nil }
            return (.emoji(emoji, name: name), t, emoji.reactionKey, name.count, index)
        })
        // Standard names are words ("red heart"); typed shortcodes use underscores.
        let spaced = q.replacingOccurrences(of: "_", with: " ")
        var standard: [(Suggestion, tier: Int, key: String, length: Int, order: Int)] = []
        for (index, entry) in unicode.enumerated() {
            guard let t = tier(entry.name, spaced, allowContains: false) else { continue }
            standard.append((.emoji(entry.emoji, name: shortcode(entry.name)), t, entry.emoji.reactionKey, entry.name.count, index))
        }
        return Array((server + rank(standard)).prefix(limit))
    }

    /// "red heart" → "red_heart", the form Discord shows as `:red_heart:`.
    static func shortcode(_ name: String) -> String {
        var result = ""
        for char in name.lowercased() {
            if char == " " || char == "-" { result.append("_") } else if char.isLetter || char.isNumber || char == "_" { result.append(char) }
        }
        return result
    }

    /// Channels by name match, keeping the given (sidebar) order within a tier.
    static func channelSuggestions(_ channels: [Channel], query: String, limit: Int = 10) -> [Suggestion] {
        let q = fold(query)
        var matches: [(channel: Channel, tier: Int, order: Int)] = []
        for (index, channel) in channels.enumerated() {
            if let t = tier(channel.name, q) { matches.append((channel, t, index)) }
        }
        matches.sort { $0.tier != $1.tier ? $0.tier < $1.tier : $0.order < $1.order }
        return matches.prefix(limit).map { Suggestion.channel($0.channel) }
    }
}
