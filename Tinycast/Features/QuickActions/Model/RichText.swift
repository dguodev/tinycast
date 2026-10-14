import Foundation

/// Composers copy and paste HTML, but a model keeps formatting intact only as Markdown.
enum RichText {
    struct Rendering: Equatable, Sendable {
        /// Nil when nothing is formatted, so delivery keeps the plain path it always had.
        let html: String?
        let plain: String
    }

    /// Nil when the HTML holds nothing beyond paragraphs and line breaks.
    static func markdown(fromHTML html: String) -> String? {
        let blocks = HTMLReader.blocks(in: html)
        guard blocks.contains(where: \.isFormatted) else { return nil }
        let markdown = MarkdownWriter.write(blocks)
        return markdown.isEmpty ? nil : markdown
    }

    /// A single newline is a line break here, as it is in every composer the reader typed into.
    static func render(markdown: String) -> Rendering? {
        guard
            let parsed = try? AttributedString(
                markdown: markdown, options: .init(interpretedSyntax: .full))
        else { return nil }
        let leaves = Leaf.group(parsed)
        let plain = PlainRenderer.render(leaves)
        guard leaves.contains(where: \.isFormatted) else { return Rendering(html: nil, plain: plain) }
        return Rendering(html: HTMLRenderer.render(leaves), plain: plain)
    }

    // MARK: - The shared inline model

    struct Style: Hashable {
        var link: String?
        var bold = false
        var italic = false
        var strike = false
        var code = false

        /// Link outermost, so a partly bold link stays one anchor.
        var marks: [Mark] {
            var marks: [Mark] = []
            if let link { marks.append(.link(link)) }
            if bold { marks.append(.bold) }
            if italic { marks.append(.italic) }
            if strike { marks.append(.strike) }
            return marks
        }

        var isPlain: Bool { self == Style() }

        func shared(with other: Style) -> Style {
            Style(
                link: link == other.link ? link : nil, bold: bold && other.bold,
                italic: italic && other.italic, strike: strike && other.strike)
        }
    }

    enum Mark: Hashable {
        case link(String)
        case bold
        case italic
        case strike
    }

    enum Inline: Equatable {
        case text(String, Style)
        case lineBreak
    }

    indirect enum Block: Equatable {
        case paragraph([Inline])
        /// An empty line the reader left between paragraphs.
        case blank
        case heading(Int, [Inline])
        case list(ordered: Bool, start: Int, items: [[Block]])
        case quote([Block])
        case code(String)

        var isFormatted: Bool {
            switch self {
            case .paragraph(let inlines):
                return inlines.contains {
                    if case .text(_, let style) = $0 { return !style.isPlain }
                    return false
                }
            case .blank: return false
            case .heading, .list, .quote, .code: return true
            }
        }
    }
}

// MARK: - Inline serialisation

extension RichText {
    enum InlineSyntax {
        case markdown
        case html
    }

    /// Delimiters hug the words they mark: `** bold **` is not emphasis, so spaces move outside.
    static func serialize(_ inlines: [Inline], as syntax: InlineSyntax) -> String {
        var output = ""
        var open: [Mark] = []
        var pendingSpace = false

        func atLineStart() -> Bool {
            output.isEmpty || output.hasSuffix(syntax == .markdown ? "\n" : "<br>")
        }
        func close(keeping marks: [Mark]) {
            guard let firstStale = open.firstIndex(where: { !marks.contains($0) }) else { return }
            for mark in open[firstStale...].reversed() { output += closer(mark, syntax) }
            open.removeSubrange(firstStale...)
        }
        func openMissing(_ marks: [Mark]) {
            for mark in marks where !open.contains(mark) {
                output += opener(mark, syntax)
                open.append(mark)
            }
        }
        func flushSpace() {
            if pendingSpace, !atLineStart() { output += " " }
            pendingSpace = false
        }

        for inline in normalized(inlines) {
            switch inline {
            case .lineBreak:
                close(keeping: [])
                pendingSpace = false
                output += syntax == .markdown ? "\n" : "<br>"
            case .text(let text, let style):
                let core = text.trimmingCharacters(in: htmlWhitespace)
                guard !core.isEmpty else {
                    pendingSpace = true
                    continue
                }
                close(keeping: style.marks)
                if text.first.map(isHTMLWhitespace) == true { pendingSpace = true }
                flushSpace()
                let lineStart = atLineStart() && style.marks.allSatisfy(open.contains)
                openMissing(style.marks)
                output += style.code
                    ? codeSpan(core, syntax)
                    : escaped(core, syntax, atLineStart: lineStart)
                pendingSpace = text.last.map(isHTMLWhitespace) == true
            }
        }
        close(keeping: [])
        return output
    }

    /// A whitespace run between two marked runs keeps what they share, so `**a b**` stays whole.
    private static func normalized(_ inlines: [Inline]) -> [Inline] {
        var restyled = inlines
        for index in restyled.indices {
            guard case .text(let text, let style) = restyled[index],
                !style.code, text.trimmingCharacters(in: htmlWhitespace).isEmpty
            else { continue }
            let before = index > 0 ? styleOf(restyled[index - 1]) : nil
            let after = index + 1 < restyled.count ? styleOf(restyled[index + 1]) : nil
            let shared = before.flatMap { before in after.map { before.shared(with: $0) } }
            restyled[index] = .text(" ", shared ?? Style())
        }
        var merged: [Inline] = []
        for inline in restyled {
            if case .text(let text, let style) = inline,
                case .text(let previous, let previousStyle) = merged.last, previousStyle == style
            {
                merged[merged.count - 1] = .text(previous + text, style)
            } else {
                merged.append(inline)
            }
        }
        return merged.map {
            guard case .text(let text, let style) = $0, !style.code else { return $0 }
            return .text(collapsingHTMLWhitespace(text), style)
        }
    }

    private static func styleOf(_ inline: Inline) -> Style? {
        guard case .text(_, let style) = inline else { return nil }
        return style
    }

    private static func opener(_ mark: Mark, _ syntax: InlineSyntax) -> String {
        switch (mark, syntax) {
        case (.link, .markdown): return "["
        case (.link(let url), .html): return "<a href=\"\(escapedHTML(url, attribute: true))\">"
        case (.bold, .markdown): return "**"
        case (.bold, .html): return "<b>"
        case (.italic, .markdown): return "*"
        case (.italic, .html): return "<i>"
        case (.strike, .markdown): return "~~"
        case (.strike, .html): return "<s>"
        }
    }

    private static func closer(_ mark: Mark, _ syntax: InlineSyntax) -> String {
        switch (mark, syntax) {
        case (.link(let url), .markdown): return "](\(markdownDestination(url)))"
        case (.link, .html): return "</a>"
        case (.bold, .markdown): return "**"
        case (.bold, .html): return "</b>"
        case (.italic, .markdown): return "*"
        case (.italic, .html): return "</i>"
        case (.strike, .markdown): return "~~"
        case (.strike, .html): return "</s>"
        }
    }

    private static func markdownDestination(_ url: String) -> String {
        url.contains(where: { $0 == " " || $0 == "(" || $0 == ")" || $0 == "<" || $0 == ">" })
            ? "<" + url.replacingOccurrences(of: ">", with: "%3E") + ">"
            : url
    }

    private static func codeSpan(_ code: String, _ syntax: InlineSyntax) -> String {
        guard syntax == .markdown else { return "<code>" + escapedHTML(code) + "</code>" }
        let fence = String(repeating: "`", count: longestRun(of: "`", in: code) + 1)
        let padding = code.hasPrefix("`") || code.hasSuffix("`") ? " " : ""
        return fence + padding + code + padding + fence
    }

    static func longestRun(of character: Character, in text: String) -> Int {
        var longest = 0
        var current = 0
        for scalar in text {
            current = scalar == character ? current + 1 : 0
            longest = max(longest, current)
        }
        return longest
    }

    private static func escaped(_ text: String, _ syntax: InlineSyntax, atLineStart: Bool) -> String {
        syntax == .markdown
            ? escapedMarkdown(text, atLineStart: atLineStart) : escapedHTML(text)
    }

    static func escapedHTML(_ text: String, attribute: Bool = false) -> String {
        var output = ""
        output.reserveCapacity(text.count)
        for character in text {
            switch character {
            case "&": output += "&amp;"
            case "<": output += "&lt;"
            case ">": output += "&gt;"
            case "\"" where attribute: output += "&quot;"
            default: output.append(character)
            }
        }
        return output
    }

    /// Only what would change meaning is escaped, so the model reads the reader's text, not noise.
    static func escapedMarkdown(_ text: String, atLineStart: Bool) -> String {
        let characters = Array(text)
        let blockMarker = atLineStart ? blockMarkerIndex(characters) : nil
        var output = ""
        for index in characters.indices {
            let character = characters[index]
            let previous = index > 0 ? characters[index - 1] : nil
            let next = index + 1 < characters.count ? characters[index + 1] : nil
            let escapes: Bool
            switch character {
            case "\\", "*", "`", "~":
                escapes = true
            case "_":
                escapes = !isWordCharacter(previous) || !isWordCharacter(next)
            case "]":
                escapes = next == "(" || next == "[" || next == ":"
            case "<":
                escapes = next.map { $0.isLetter || $0 == "/" || $0 == "!" || $0 == "?" } ?? false
            case "&":
                escapes = startsEntity(characters, at: index)
            default:
                escapes = false
            }
            if escapes || index == blockMarker { output += "\\" }
            output.append(character)
        }
        return output
    }

    /// The character that would open a heading, quote, list, rule or table at the start of a line.
    private static func blockMarkerIndex(_ characters: [Character]) -> Int? {
        guard let first = characters.first else { return nil }
        if "#>-+=|".contains(first) { return 0 }
        let digits = characters.prefix(while: { $0.isASCII && $0.isNumber }).count
        guard digits > 0, digits < characters.count,
            characters[digits] == "." || characters[digits] == ")"
        else { return nil }
        return digits
    }

    private static func isWordCharacter(_ character: Character?) -> Bool {
        character.map { $0.isLetter || $0.isNumber } ?? false
    }

    private static func startsEntity(_ characters: [Character], at index: Int) -> Bool {
        var cursor = index + 1
        while cursor < characters.count, cursor - index <= 32 {
            let character = characters[cursor]
            if character == ";" { return cursor > index + 1 }
            guard isWordCharacter(character) || character == "#" else { return false }
            cursor += 1
        }
        return false
    }
}

// MARK: - Blocks to Markdown

extension RichText {
    enum MarkdownWriter {
        static func write(_ blocks: [Block]) -> String {
            var output = ""
            var previous: Block?
            var sawBlank = false
            for block in blocks {
                if case .blank = block {
                    sawBlank = true
                    continue
                }
                let text = write(block)
                guard !text.isEmpty else { continue }
                if let previous {
                    output += sawBlank || !continuesLine(after: previous, with: block) ? "\n\n" : "\n"
                }
                output += text
                previous = block
                sawBlank = false
            }
            return output
        }

        /// A list may interrupt a paragraph, but anything after a list would join its last item.
        private static func continuesLine(after previous: Block, with block: Block) -> Bool {
            guard case .paragraph = previous else { return false }
            switch block {
            case .paragraph: return true
            case .list(let ordered, let start, _): return !ordered || start == 1
            default: return false
            }
        }

        private static func write(_ block: Block) -> String {
            switch block {
            case .paragraph(let inlines):
                return serialize(inlines, as: .markdown)
            case .blank:
                return ""
            case .heading(let level, let inlines):
                let line = inlines.map { $0 == .lineBreak ? .text(" ", Style()) : $0 }
                let text = serialize(line, as: .markdown)
                return text.isEmpty ? "" : String(repeating: "#", count: level) + " " + text
            case .list(let ordered, let start, let items):
                return items.enumerated().map { offset, item in
                    let marker = ordered ? "\(start + offset). " : "- "
                    let body = write(item)
                    guard !body.isEmpty else { return marker.trimmingCharacters(in: .whitespaces) }
                    return marker + indented(body, by: marker.count)
                }.joined(separator: "\n")
            case .quote(let blocks):
                return write(blocks).split(separator: "\n", omittingEmptySubsequences: false)
                    .map { $0.isEmpty ? ">" : "> " + $0 }
                    .joined(separator: "\n")
            case .code(let code):
                let fence = String(repeating: "`", count: max(3, longestRun(of: "`", in: code) + 1))
                return fence + "\n" + code + "\n" + fence
            }
        }

        private static func indented(_ text: String, by width: Int) -> String {
            let padding = String(repeating: " ", count: width)
            return text.split(separator: "\n", omittingEmptySubsequences: false).enumerated()
                .map { $0.offset == 0 || $0.element.isEmpty ? String($0.element) : padding + $0.element }
                .joined(separator: "\n")
        }
    }
}

// MARK: - Markdown to HTML and plain text

extension RichText {
    /// One paragraph, heading or code block, with the lists and quotes it sits inside.
    struct Leaf {
        enum Kind: Equatable {
            case paragraph
            case heading(Int)
            case code
        }

        enum Container: Equatable {
            case list(ordered: Bool)
            case item(ordinal: Int)
            case quote

            var isList: Bool {
                if case .list = self { return true }
                return false
            }
        }

        let identity: Int
        let kind: Kind
        /// Outermost first, each with the parser's identity so two adjacent lists stay two.
        let containers: [(container: Container, identity: Int)]
        var inlines: [Inline] = []
        var code = ""

        var isFormatted: Bool {
            kind != .paragraph || !containers.isEmpty
                || Block.paragraph(inlines).isFormatted
        }

        var isInItem: Bool {
            if case .item = containers.last?.container { return true }
            return false
        }

        static func group(_ parsed: AttributedString) -> [Leaf] {
            var leaves: [Leaf] = []
            for run in parsed.runs {
                let text = String(parsed[run.range].characters)
                let components = run.presentationIntent?.components ?? []
                let identity = components.first?.identity ?? -1
                if leaves.last?.identity != identity {
                    leaves.append(leaf(for: components, identity: identity))
                }
                let index = leaves.count - 1
                if leaves[index].kind == .code {
                    leaves[index].code += text
                    continue
                }
                let inline = run.inlinePresentationIntent ?? []
                if inline.contains(.softBreak) || inline.contains(.lineBreak) {
                    leaves[index].inlines.append(.lineBreak)
                    continue
                }
                let style = Style(
                    link: run.link?.absoluteString, bold: inline.contains(.stronglyEmphasized),
                    italic: inline.contains(.emphasized), strike: inline.contains(.strikethrough),
                    code: inline.contains(.code))
                leaves[index].inlines.append(.text(text, style))
            }
            return leaves
        }

        private static func leaf(
            for components: [PresentationIntent.IntentType], identity: Int
        ) -> Leaf {
            let kind: Kind =
                switch components.first?.kind {
                case .header(let level): .heading(level)
                case .codeBlock: .code
                default: .paragraph
                }
            let containers = components.dropFirst().reversed().compactMap {
                component -> (container: Container, identity: Int)? in
                switch component.kind {
                case .orderedList: return (.list(ordered: true), component.identity)
                case .unorderedList: return (.list(ordered: false), component.identity)
                case .listItem(let ordinal): return (.item(ordinal: ordinal), component.identity)
                case .blockQuote: return (.quote, component.identity)
                default: return nil
                }
            }
            return Leaf(identity: identity, kind: kind, containers: containers)
        }
    }

    /// The reader left a blank line between these, which nothing but an empty line can show.
    static func separatesParagraphs(_ previous: Leaf?, _ leaf: Leaf) -> Bool {
        guard let previous, previous.kind == .paragraph, leaf.kind == .paragraph, !leaf.isInItem
        else { return false }
        return previous.containers.map(\.identity) == leaf.containers.map(\.identity)
    }

    enum HTMLRenderer {
        /// `div` rather than `p`, because a pasted `p` brings each target's paragraph margins.
        static func render(_ leaves: [Leaf]) -> String {
            var html = "<meta charset=\"utf-8\">"
            var open: [(container: Leaf.Container, identity: Int)] = []
            var previous: Leaf?
            for leaf in leaves {
                var shared = 0
                while shared < min(open.count, leaf.containers.count),
                    open[shared].identity == leaf.containers[shared].identity
                {
                    shared += 1
                }
                for entry in open[shared...].reversed() { html += closingTag(entry.container) }
                if separatesParagraphs(previous, leaf) { html += "<div><br></div>" }
                for (offset, entry) in leaf.containers.enumerated().dropFirst(shared) {
                    let next = leaf.containers.dropFirst(offset + 1).first?.container
                    html += openingTag(entry.container, firstItem: next)
                }
                let continuesItem = leaf.isInItem && shared == leaf.containers.count && previous != nil
                open = leaf.containers
                html += body(of: leaf, continuingItem: continuesItem)
                previous = leaf
            }
            for entry in open.reversed() { html += closingTag(entry.container) }
            return html
        }

        private static func body(of leaf: Leaf, continuingItem: Bool) -> String {
            switch leaf.kind {
            case .code:
                return "<pre><code>" + escapedHTML(trimmedCode(leaf.code)) + "</code></pre>"
            case .heading(let level):
                return "<h\(level)>" + serialize(leaf.inlines, as: .html) + "</h\(level)>"
            case .paragraph:
                let inline = serialize(leaf.inlines, as: .html)
                guard !leaf.isInItem else { return (continuingItem ? "<br>" : "") + inline }
                return "<div>" + inline + "</div>"
            }
        }

        private static func openingTag(_ container: Leaf.Container, firstItem: Leaf.Container?) -> String {
            switch container {
            case .list(ordered: false): return "<ul>"
            case .list(ordered: true):
                guard case .item(let ordinal) = firstItem, ordinal != 1 else { return "<ol>" }
                return "<ol start=\"\(ordinal)\">"
            case .item: return "<li>"
            case .quote: return "<blockquote>"
            }
        }

        private static func closingTag(_ container: Leaf.Container) -> String {
            switch container {
            case .list(ordered: false): return "</ul>"
            case .list(ordered: true): return "</ol>"
            case .item: return "</li>"
            case .quote: return "</blockquote>"
            }
        }
    }

    enum PlainRenderer {
        static func render(_ leaves: [Leaf]) -> String {
            var lines: [String] = []
            var previous: Leaf?
            var openItems: Set<Int> = []
            for leaf in leaves {
                if separatesParagraphs(previous, leaf) { lines.append("") }
                var prefix = ""
                if let item = leaf.containers.last, case .item(let ordinal) = item.container {
                    let depth = leaf.containers.count(where: \.container.isList)
                    let indent = String(repeating: "  ", count: max(depth - 1, 0))
                    if openItems.insert(item.identity).inserted {
                        let ordered = leaf.containers.dropLast().last?.container == .list(ordered: true)
                        prefix = indent + (ordered ? "\(ordinal). " : "• ")
                    } else {
                        prefix = indent + "  "
                    }
                }
                let text: String =
                    leaf.kind == .code
                    ? trimmedCode(leaf.code)
                    : leaf.inlines.map {
                        if case .text(let text, _) = $0 { return text }
                        return "\n"
                    }.joined()
                lines.append(prefix + text)
                previous = leaf
            }
            return lines.joined(separator: "\n")
        }
    }

    private static func trimmedCode(_ code: String) -> String {
        code.hasSuffix("\n") ? String(code.dropLast()) : code
    }
}

extension RichText {
    /// HTML collapses these and nothing else, so a non-breaking space survives.
    static let htmlWhitespace = CharacterSet(charactersIn: " \t\n\r\u{0C}")

    static func isHTMLWhitespace(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy(htmlWhitespace.contains)
    }

    static func collapsingHTMLWhitespace(_ text: String) -> String {
        var output = ""
        output.reserveCapacity(text.count)
        var inSpace = false
        for character in text {
            if isHTMLWhitespace(character) {
                if !inSpace { output.append(" ") }
                inSpace = true
            } else {
                output.append(character)
                inSpace = false
            }
        }
        return output
    }
}
