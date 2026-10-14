import Foundation

/// A selection as the model sees it; `.markdown` is the reader's formatting carried as Markdown.
struct QuickActionText: Equatable, Sendable {
    enum Format: Equatable, Sendable {
        case plain
        case markdown
    }

    let text: String
    let format: Format
}
