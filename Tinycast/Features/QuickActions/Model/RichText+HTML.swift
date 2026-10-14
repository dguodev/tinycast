import Foundation

/// Pasteboard HTML is tag soup, not XML: unclosed `li`, stray end tags and bare `&` are normal.
extension RichText {
    enum HTMLReader {
        static func blocks(in html: String) -> [Block] {
            var builder = BlockBuilder()
            builder.walk(Tree.parse(html).children, style: Style())
            return builder.finish()
        }
    }

    final class Element {
        let name: String
        let attributes: [String: String]
        var children: [Node] = []

        init(name: String, attributes: [String: String]) {
            self.name = name
            self.attributes = attributes
        }
    }

    enum Node {
        case text(String)
        case element(Element)
    }
}

// MARK: - Tokenising into a tree

extension RichText {
    struct Tree {
        private static let voidElements: Set<String> = [
            "area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "source",
            "track", "wbr",
        ]
        private static let rawTextElements: Set<String> = [
            "script", "style", "title", "textarea", "xmp",
        ]
        private static let blockElements: Set<String> = [
            "address", "article", "aside", "blockquote", "div", "dl", "fieldset", "figure", "footer",
            "h1", "h2", "h3", "h4", "h5", "h6", "header", "hr", "li", "main", "nav", "ol", "p", "pre",
            "section", "table", "ul",
        ]

        private let scalars: [Unicode.Scalar]
        private var index = 0
        private var stack: [Element]

        static func parse(_ html: String) -> Element {
            var tree = Tree(scalars: Array(html.unicodeScalars))
            tree.run()
            return tree.stack[0]
        }

        private init(scalars: [Unicode.Scalar]) {
            self.scalars = scalars
            self.stack = [Element(name: "#root", attributes: [:])]
        }

        private mutating func run() {
            var text = String.UnicodeScalarView()
            while index < scalars.count {
                guard scalars[index] == "<", let next = scalar(at: index + 1),
                    next == "/" || next == "!" || next == "?" || next.properties.isAlphabetic
                else {
                    text.append(scalars[index])
                    index += 1
                    continue
                }
                appendText(String(text))
                text = String.UnicodeScalarView()
                if next == "!" || next == "?" {
                    skipMarkup()
                } else if next == "/" {
                    index += 2
                    let name = readName()
                    skip(past: ">")
                    close(name)
                } else {
                    index += 1
                    readStartTag()
                }
            }
            appendText(String(text))
        }

        private func scalar(at position: Int) -> Unicode.Scalar? {
            position < scalars.count ? scalars[position] : nil
        }

        private func starts(with literal: String, at position: Int) -> Bool {
            var cursor = position
            for expected in literal.unicodeScalars {
                guard let actual = scalar(at: cursor),
                    actual.properties.lowercaseMapping == expected.properties.lowercaseMapping
                else { return false }
                cursor += 1
            }
            return true
        }

        /// `<!--StartFragment-->`, doctypes and processing instructions carry nothing to keep.
        private mutating func skipMarkup() {
            if starts(with: "<!--", at: index) {
                index += 4
                while index < scalars.count, !starts(with: "-->", at: index) { index += 1 }
                index = min(index + 3, scalars.count)
            } else {
                skip(past: ">")
            }
        }

        private mutating func skip(past terminator: Unicode.Scalar) {
            while index < scalars.count, scalars[index] != terminator { index += 1 }
            index = min(index + 1, scalars.count)
        }

        private mutating func readName() -> String {
            var name = String.UnicodeScalarView()
            while let scalar = scalar(at: index),
                !scalar.properties.isWhitespace, scalar != ">", scalar != "/", scalar != "="
            {
                name.append(scalar)
                index += 1
            }
            return String(name).lowercased()
        }

        private mutating func readStartTag() {
            let name = readName()
            var attributes: [String: String] = [:]
            var selfClosing = false
            while let scalar = scalar(at: index) {
                if scalar.properties.isWhitespace {
                    index += 1
                } else if scalar == ">" {
                    index += 1
                    break
                } else if scalar == "/" {
                    selfClosing = true
                    index += 1
                } else {
                    let attribute = readName()
                    guard !attribute.isEmpty else {
                        index += 1
                        continue
                    }
                    attributes[attribute] = readAttributeValue()
                }
            }
            if Self.rawTextElements.contains(name) {
                skipRawText(closing: name)
                return
            }
            open(Element(name: name, attributes: attributes), selfClosing: selfClosing)
        }

        private mutating func readAttributeValue() -> String {
            var cursor = index
            while let scalar = scalar(at: cursor), scalar.properties.isWhitespace { cursor += 1 }
            guard scalar(at: cursor) == "=" else { return "" }
            cursor += 1
            while let scalar = scalar(at: cursor), scalar.properties.isWhitespace { cursor += 1 }
            var value = String.UnicodeScalarView()
            if let quote = scalar(at: cursor), quote == "\"" || quote == "'" {
                cursor += 1
                while let scalar = scalar(at: cursor), scalar != quote {
                    value.append(scalar)
                    cursor += 1
                }
                cursor += 1
            } else {
                while let scalar = scalar(at: cursor), !scalar.properties.isWhitespace, scalar != ">" {
                    value.append(scalar)
                    cursor += 1
                }
            }
            index = min(cursor, scalars.count)
            return RichText.decodingEntities(String(value))
        }

        /// A `<style>` body is CSS, never markup, so a `<b>` inside one must not open anything.
        private mutating func skipRawText(closing name: String) {
            while index < scalars.count, !starts(with: "</" + name, at: index) { index += 1 }
            skip(past: ">")
        }

        private mutating func appendText(_ text: String) {
            guard !text.isEmpty else { return }
            stack[stack.count - 1].children.append(.text(RichText.decodingEntities(text)))
        }

        private mutating func open(_ element: Element, selfClosing: Bool) {
            if element.name == "li" { closeOpenItem() }
            if Self.blockElements.contains(element.name),
                let paragraph = stack.lastIndex(where: { $0.name == "p" })
            {
                stack.removeSubrange(paragraph...)
            }
            stack[stack.count - 1].children.append(.element(element))
            guard !selfClosing, !Self.voidElements.contains(element.name) else { return }
            stack.append(element)
        }

        /// An `li` start closes the open one in the same list, which is how `<li>a<li>b` reads.
        private mutating func closeOpenItem() {
            guard let item = stack.lastIndex(where: { ["li", "ul", "ol"].contains($0.name) }),
                stack[item].name == "li"
            else { return }
            stack.removeSubrange(item...)
        }

        private mutating func close(_ name: String) {
            guard let match = stack.lastIndex(where: { $0.name == name }), match > 0 else { return }
            stack.removeSubrange(match...)
        }
    }

    private static let namedEntities: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{00A0}",
        "ndash": "–", "mdash": "—", "hellip": "…", "lsquo": "‘", "rsquo": "’", "ldquo": "“",
        "rdquo": "”", "bull": "•", "middot": "·", "copy": "©", "reg": "®", "trade": "™",
        "zwj": "\u{200D}", "zwnj": "\u{200C}",
    ]

    static func decodingEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var output = ""
        var remainder = Substring(text)
        while let ampersand = remainder.firstIndex(of: "&") {
            output += remainder[..<ampersand]
            let afterAmpersand = remainder.index(after: ampersand)
            let candidate = remainder[afterAmpersand...].prefix(32)
            if let semicolon = candidate.firstIndex(of: ";"),
                let decoded = decodedEntity(candidate[..<semicolon])
            {
                output += decoded
                remainder = remainder[remainder.index(after: semicolon)...]
            } else {
                output += "&"
                remainder = remainder[afterAmpersand...]
            }
        }
        return output + remainder
    }

    private static func decodedEntity(_ name: Substring) -> String? {
        guard name.first == "#" else { return namedEntities[String(name)] }
        let digits = name.dropFirst()
        let value: UInt32? =
            digits.first == "x" || digits.first == "X"
            ? UInt32(digits.dropFirst(), radix: 16) : UInt32(digits, radix: 10)
        return value.flatMap(Unicode.Scalar.init).map { String(Character($0)) }
    }
}

// MARK: - Tree to blocks

extension RichText {
    struct BlockBuilder {
        private static let lineContainers: Set<String> = [
            "address", "article", "aside", "body", "center", "dd", "div", "dl", "dt", "fieldset",
            "figure", "footer", "header", "html", "main", "nav", "p", "section", "table", "tr",
        ]

        private var blocks: [Block] = []
        private var line: [Inline] = []

        mutating func finish() -> [Block] {
            flushLine()
            return blocks
        }

        mutating func walk(_ nodes: [Node], style: Style) {
            for node in nodes {
                switch node {
                case .text(let text):
                    line.append(.text(collapsingHTMLWhitespace(text), style))
                case .element(let element):
                    walk(element, style: style)
                }
            }
        }

        private mutating func walk(_ element: Element, style inherited: Style) {
            let name = element.name
            let style = Self.style(of: element, inheriting: inherited)
            switch name {
            case "br":
                line.append(.lineBreak)
            case "img":
                line.append(.text(element.attributes["alt"] ?? "", style))
            case "h1", "h2", "h3", "h4", "h5", "h6":
                flushLine()
                var heading = BlockBuilder()
                heading.walk(element.children, style: style)
                let inlines = Self.trimmed(heading.line).inlines
                guard !inlines.isEmpty, let level = Int(name.dropFirst()) else { return }
                blocks.append(.heading(level, inlines))
            case "ul", "ol":
                flushLine()
                if let list = Self.list(element, style: style) { blocks.append(list) }
            case "blockquote":
                flushLine()
                var quote = BlockBuilder()
                quote.walk(element.children, style: style)
                let quoted = quote.finish()
                if !quoted.isEmpty { blocks.append(.quote(quoted)) }
            case "pre":
                flushLine()
                var code = Self.preformatted(element.children)
                if code.hasPrefix("\n") { code.removeFirst() }
                while code.hasSuffix("\n") { code.removeLast() }
                if !code.isEmpty { blocks.append(.code(code)) }
            case "td", "th":
                walk(element.children, style: style)
                line.append(.text(" ", Style()))
            default:
                let isBlock = Self.lineContainers.contains(name)
                if isBlock { flushLine() }
                walk(element.children, style: style)
                if isBlock { flushLine() }
            }
        }

        /// A `<br>` closing a line is Chromium's placeholder; a line of nothing but one is a gap.
        private mutating func flushLine() {
            defer { line = [] }
            let (inlines, leadingBreaks, trailingBreaks) = Self.trimmed(line)
            guard !inlines.isEmpty else {
                if leadingBreaks > 0 { blocks.append(.blank) }
                return
            }
            if leadingBreaks > 0 { blocks.append(.blank) }
            blocks.append(.paragraph(inlines))
            if trailingBreaks > 1 { blocks.append(.blank) }
        }

        private static func trimmed(
            _ line: [Inline]
        ) -> (inlines: [Inline], leadingBreaks: Int, trailingBreaks: Int) {
            func isFiller(_ inline: Inline) -> Bool {
                guard case .text(let text, let style) = inline else { return true }
                return !style.code && text.trimmingCharacters(in: htmlWhitespace).isEmpty
            }
            guard let first = line.firstIndex(where: { !isFiller($0) }),
                let last = line.lastIndex(where: { !isFiller($0) })
            else { return ([], line.count(where: { $0 == .lineBreak }), 0) }
            return (
                Array(line[first...last]),
                line[..<first].count(where: { $0 == .lineBreak }),
                line[(last + 1)...].count(where: { $0 == .lineBreak })
            )
        }

        private static func preformatted(_ nodes: [Node]) -> String {
            nodes.map { node in
                switch node {
                case .text(let text): return text
                case .element(let element) where element.name == "br": return "\n"
                case .element(let element): return preformatted(element.children)
                }
            }.joined()
        }

        // MARK: Lists

        /// Slack and Quill flatten nesting into an indent attribute instead of nested lists.
        private static func list(_ element: Element, style: Style) -> Block? {
            var items: [(indent: Int, blocks: [Block])] = []
            for child in element.children {
                guard case .element(let child) = child else { continue }
                switch child.name {
                case "li":
                    var item = BlockBuilder()
                    item.walk(child.children, style: Self.style(of: child, inheriting: style))
                    items.append((indent(of: child), item.finish()))
                case "ul", "ol":
                    guard let nested = list(child, style: style) else { continue }
                    if items.isEmpty { items.append((0, [])) }
                    items[items.count - 1].blocks.append(nested)
                default:
                    continue
                }
            }
            guard !items.isEmpty else { return nil }
            let ordered = element.name == "ol"
            let start = element.attributes["start"].flatMap { Int($0) } ?? 1
            return nest(items[...], ordered: ordered, start: start)
        }

        private static func nest(
            _ items: ArraySlice<(indent: Int, blocks: [Block])>, ordered: Bool, start: Int
        ) -> Block {
            let base = items.map(\.indent).min() ?? 0
            var nested: [[Block]] = []
            var index = items.startIndex
            while index < items.endIndex {
                guard items[index].indent > base else {
                    nested.append(items[index].blocks)
                    index += 1
                    continue
                }
                let deeper = items[index...].prefix { $0.indent > base }
                if nested.isEmpty { nested.append([]) }
                nested[nested.count - 1].append(nest(deeper, ordered: ordered, start: 1))
                index = deeper.endIndex
            }
            return .list(ordered: ordered, start: start, items: nested)
        }

        private static func indent(of item: Element) -> Int {
            if let level = item.attributes["data-stringify-indent"].flatMap({ Int($0) }) {
                return level
            }
            if let level = item.attributes["aria-level"].flatMap({ Int($0) }) { return level - 1 }
            let classes = item.attributes["class"]?.split(separator: " ") ?? []
            let indentClass = classes.first { $0.hasPrefix("ql-indent-") }
            return indentClass.flatMap { Int($0.dropFirst("ql-indent-".count)) } ?? 0
        }

        // MARK: Style

        /// Tag first, then CSS, because Google Docs wraps everything in a normal-weight `<b>`.
        private static func style(of element: Element, inheriting inherited: Style) -> Style {
            guard !inherited.code else { return inherited }
            var style = inherited
            switch element.name {
            case "b", "strong": style.bold = true
            case "i", "em", "cite", "dfn", "var": style.italic = true
            case "s", "strike", "del": style.strike = true
            case "code", "kbd", "samp", "tt": style.code = true
            case "a":
                if let href = element.attributes["href"], !href.isEmpty,
                    !href.lowercased().hasPrefix("javascript:")
                {
                    style.link = href
                }
            default: break
            }
            for (property, value) in declarations(element.attributes["style"] ?? "") {
                switch property {
                case "font-weight":
                    style.bold = value.hasPrefix("bold") || (Int(value).map { $0 >= 600 } ?? false)
                case "font-style":
                    style.italic = value.hasPrefix("italic") || value.hasPrefix("oblique")
                case "text-decoration", "text-decoration-line":
                    if value.contains("line-through") { style.strike = true }
                default: break
                }
            }
            return style
        }

        private static func declarations(_ css: String) -> [(String, String)] {
            css.split(separator: ";").compactMap { declaration in
                let parts = declaration.split(separator: ":", maxSplits: 1)
                guard parts.count == 2 else { return nil }
                return (
                    parts[0].trimmingCharacters(in: .whitespaces).lowercased(),
                    parts[1].trimmingCharacters(in: .whitespaces).lowercased()
                )
            }
        }
    }
}
