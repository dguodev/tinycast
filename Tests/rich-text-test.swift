import Foundation

@main
@MainActor
struct RichTextTests {
    static var failures = 0
    static var passes = 0

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if condition() {
            passes += 1
        } else {
            failures += 1
            print("FAIL: \(message)")
        }
    }

    static func expectEqual(_ actual: String?, _ expected: String?, _ message: String) {
        expect(
            actual == expected,
            "\(message)\n  expected: \(expected.debugDescription)\n  actual:   \(actual.debugDescription)")
    }

    static func main() {
        slackMarkupBecomesMarkdown()
        slackMessageFixtureKeepsItsLines()
        chromiumInlineStylesCountAsFormatting()
        googleDocsWrapperIsNotBold()
        blockBoundariesAreLines()
        entitiesDecode()
        listsKeepTheirNesting()
        markupWithoutFormattingIsLeftToPlainText()
        literalMarkdownInTheTextStaysLiteral()
        renderEmitsEachConstruct()
        renderLeavesUnformattedMarkdownPlain()
        formattingSurvivesTheRoundTrip()

        print("\(passes) passed, \(failures) failed")
        if failures > 0 { exit(1) }
    }

    /// The shape Slack's composer puts on the pasteboard: `data-stringify-*` tags and emoji images.
    static let slackHTML = """
        <meta charset='utf-8'><b data-stringify-type="bold">Ship</b> it <i data-stringify-type="italic">today</i>, \
        <s data-stringify-type="strike">tomorrow</s> — run <code data-stringify-type="code" \
        class="c-mrkdwn__code">make test</code> and read \
        <a target="_blank" class="c-link" data-stringify-link="https://example.com/runbook" \
        delay="150" href="https://example.com/runbook" rel="noopener noreferrer">the runbook</a> \
        <img data-stringify-type="emoji" data-stringify-emoji=":rocket:" class="c-emoji c-emoji__small" \
        src="https://a.slack-edge.com/rocket.png" alt=":rocket:" aria-label="rocket emoji"><br>\
        <ul data-stringify-type="bulleted-list"><li data-stringify-indent="0" data-stringify-border="0">\
        first</li><li data-stringify-indent="1" data-stringify-border="0">under it</li>\
        <li data-stringify-indent="0" data-stringify-border="0">second</li></ul>\
        <ol data-stringify-type="numbered-list"><li data-stringify-indent="0">one</li>\
        <li data-stringify-indent="0">two</li></ol>\
        <blockquote type="cite" class="c-mrkdwn__quote" data-stringify-type="quote">quoted \
        <b data-stringify-type="bold">line</b><br>and more</blockquote>\
        <pre class="c-mrkdwn__pre" data-stringify-type="pre">let x = 1\n  y</pre>
        """

    static let slackMarkdown = """
        **Ship** it *today*, ~~tomorrow~~ — run `make test` and read \
        [the runbook](https://example.com/runbook) :rocket:
        - first
          - under it
        - second

        1. one
        2. two

        > quoted **line**
        > and more

        ```
        let x = 1
          y
        ```
        """

    static func slackMarkupBecomesMarkdown() {
        expectEqual(
            RichText.markdown(fromHTML: slackHTML), slackMarkdown,
            "Slack's bold, italics, strike, code, link, emoji, lists, quote and block all carry over")
    }

    /// Copied from posted Slack messages: bullets are `•` text between `<br>`s, not a list.
    static func slackMessageFixtureKeepsItsLines() {
        guard let data = FileManager.default.contents(atPath: "Tests/rich-text-fixtures/slack-message.html"),
            let html = String(bytes: data, encoding: .utf8)
        else {
            expect(false, "the Slack message fixture is readable")
            return
        }
        let expected = """
            the first batch was only a start -- we saw steady traffic over the next hour, retries included.

            [12:47 PM]
            here is the impact, maybe some of it is the cause?

            > **Impact:**
            > • The service received 3,123 requests and completed **none** (no 5xx errors — just hangs).
            > • Token grant: 1,658 failures, `access_denied` (403).
            > • All other APIs were also blocked.
            """
        let markdown = RichText.markdown(fromHTML: html)
        expectEqual(
            markdown, expected,
            "nested wrappers collapse, each <br> stays a line and one blank line separates messages")
        let rendered = markdown.flatMap(RichText.render(markdown:))
        expect(
            rendered?.html?.contains(
                "<blockquote><div><b>Impact:</b><br>• The service received 3,123 requests") == true,
            "the quote renders with its bold and each bullet on its own line")
        expectEqual(
            rendered?.html.flatMap(RichText.markdown(fromHTML:)), expected,
            "pasting our HTML back into Slack and copying it again changes nothing")

        let bullets = RichText.render(markdown: "**Steps**\n• a\n• b")
        expectEqual(
            bullets?.html, "<meta charset=\"utf-8\"><div><b>Steps</b><br>• a<br>• b</div>",
            "a single newline renders as a line break, never a joined line")
        expectEqual(bullets?.plain, "Steps\n• a\n• b", "and as a newline in the plain flavour")
    }

    static func chromiumInlineStylesCountAsFormatting() {
        let html = """
            <meta charset='utf-8'><span style="color: rgb(29, 28, 29); font-weight: 400;">Keep \
            <span style="font-weight: 700;">this</span> and <span style="font-style: italic;">that</span> \
            but <span style="text-decoration: line-through;">not this</span></span>
            """
        expectEqual(
            RichText.markdown(fromHTML: html), "Keep **this** and *that* but ~~not this~~",
            "a Chromium copy carries emphasis as inline CSS rather than tags")
    }

    static func googleDocsWrapperIsNotBold() {
        let html = """
            <meta charset="utf-8"><b style="font-weight:normal;" id="docs-internal-guid-1a2b"><p dir="ltr" \
            style="line-height:1.38;margin-top:0pt;margin-bottom:0pt;"><span style="font-size:11pt;\
            font-weight:400;">Plain then </span><span style="font-size:11pt;font-weight:700;">bold</span>\
            </p><br><p dir="ltr"><span style="font-weight:400;">next</span></p></b>
            """
        expectEqual(
            RichText.markdown(fromHTML: html), "Plain then **bold**\n\nnext",
            "Docs wraps everything in a normal-weight <b>, so only the 700 span is bold")
    }

    /// Composers draw each line as a block and a blank line as a block holding only a `<br>`.
    static func blockBoundariesAreLines() {
        let html = """
            <div><b>one</b></div><div>two</div><div><br></div><div>three<br><br></div><div>four</div>\
            <br>five<ul><li>a<li>b</ul>
            """
        expectEqual(
            RichText.markdown(fromHTML: html), "**one**\ntwo\n\nthree\n\nfour\n\nfive\n- a\n- b",
            "adjacent blocks stay adjacent lines, an empty one is a gap, and `<li>` closes the last")
    }

    static func entitiesDecode() {
        let html = "<b>Tom &amp; Jerry</b> &lt;3 &quot;hi&quot; it&#39;s &#233;t&#xE9; &#128512;&nbsp;! &bogus;"
        expectEqual(
            RichText.markdown(fromHTML: html),
            "**Tom & Jerry** <3 \"hi\" it's été 😀\u{00A0}! \\&bogus;",
            "named, decimal and hex entities decode; an unknown one stays literal")
    }

    static func listsKeepTheirNesting() {
        let html = """
            <ul><li>a<ul><li>b<ol start="4"><li>c</li><li>d</li></ol></li></ul></li><li>e</ul>
            """
        expectEqual(
            RichText.markdown(fromHTML: html), "- a\n  - b\n\n    4. c\n    5. d\n- e",
            "nested lists indent under their item and an ordered start carries over")
        let quill = """
            <ol><li class="ql-indent-0">one</li><li class="ql-indent-1">deeper</li>\
            <li class="ql-indent-2">deepest</li><li>two</li></ol>
            """
        expectEqual(
            RichText.markdown(fromHTML: quill), "1. one\n   1. deeper\n      1. deepest\n2. two",
            "an indent class nests a flat list the way the editor drew it")
    }

    static func markupWithoutFormattingIsLeftToPlainText() {
        let samples = [
            "<p>one</p><p>two<br>three</p>",
            "<meta charset='utf-8'><span style=\"font-weight: 400; font-style: normal;\">just text</span>",
            "<html><head><style>b { color: red }</style><title>T</title></head><body>"
                + "<!--StartFragment-->text<!--EndFragment--></body></html>",
            "<script>document.write('<b>x</b>')</script>words",
            "<u>underlined</u> only",
        ]
        for html in samples {
            expect(
                RichText.markdown(fromHTML: html) == nil,
                "no formatting means nil, so the plain path is untouched: \(html)")
        }
    }

    static func literalMarkdownInTheTextStaysLiteral() {
        let html = "<b>2 * 3</b> is `six` [not](a link)<br>1. not a list<br># not a heading<br>_under_ snake_case"
        let markdown = RichText.markdown(fromHTML: html)
        expectEqual(
            markdown,
            "**2 \\* 3** is \\`six\\` [not\\](a link)\n1\\. not a list\n\\# not a heading\n\\_under\\_ snake_case",
            "Markdown characters in the reader's text are escaped where they would change meaning")
        expectEqual(
            markdown.flatMap(RichText.render(markdown:))?.plain,
            "2 * 3 is `six` [not](a link)\n1. not a list\n# not a heading\n_under_ snake_case",
            "and parse back to exactly the text the reader typed")
    }

    static func renderEmitsEachConstruct() {
        let cases: [(markdown: String, html: String, plain: String)] = [
            ("**b** *i* ~~s~~ `c`", "<div><b>b</b> <i>i</i> <s>s</s> <code>c</code></div>", "b i s c"),
            (
                "[the site](https://example.com/?a=1&b=2)",
                "<div><a href=\"https://example.com/?a=1&amp;b=2\">the site</a></div>", "the site"
            ),
            ("- a\n- b", "<ul><li>a</li><li>b</li></ul>", "• a\n• b"),
            ("3. c\n4. d", "<ol start=\"3\"><li>c</li><li>d</li></ol>", "3. c\n4. d"),
            ("- a\n  - b", "<ul><li>a<ul><li>b</li></ul></li></ul>", "• a\n  • b"),
            ("> q **b**", "<blockquote><div>q <b>b</b></div></blockquote>", "q b"),
            ("## Title", "<h2>Title</h2>", "Title"),
            ("```\nx < y\n```", "<pre><code>x &lt; y</code></pre>", "x < y"),
            ("**a**\nb\n\nc", "<div><b>a</b><br>b</div><div><br></div><div>c</div>", "a\nb\n\nc"),
            ("**bold***it*", "<div><b>bold</b><i>it</i></div>", "boldit"),
        ]
        for (markdown, html, plain) in cases {
            let rendered = RichText.render(markdown: markdown)
            expectEqual(rendered?.html, "<meta charset=\"utf-8\">" + html, "HTML for \(markdown.debugDescription)")
            expectEqual(rendered?.plain, plain, "plain text for \(markdown.debugDescription)")
        }
    }

    static func renderLeavesUnformattedMarkdownPlain() {
        let rendered = RichText.render(markdown: "Just \\*words\\*\non two lines")
        expect(rendered?.html == nil, "nothing formatted means no HTML, so delivery stays plain")
        expectEqual(rendered?.plain, "Just *words*\non two lines", "escapes resolve and line breaks stay")
    }

    static func formattingSurvivesTheRoundTrip() {
        guard let rendered = RichText.render(markdown: slackMarkdown), let html = rendered.html else {
            expect(false, "Slack's Markdown renders to HTML")
            return
        }
        for tag in [
            "<b>Ship</b>", "<i>today</i>", "<s>tomorrow</s>", "<code>make test</code>",
            "<a href=\"https://example.com/runbook\">the runbook</a>", "<ul><li>first<ul><li>under it",
            "<ol><li>one</li>", "<blockquote><div>quoted <b>line</b><br>and more</div></blockquote>",
            "<pre><code>let x = 1\n  y</code></pre>",
        ] {
            expect(html.contains(tag), "the rendered HTML keeps \(tag)")
        }
        expectEqual(
            RichText.markdown(fromHTML: html), slackMarkdown,
            "reading our own HTML back yields the same Markdown, so nothing drifts on a second run")
        expectEqual(
            rendered.plain,
            "Ship it today, tomorrow — run make test and read the runbook :rocket:\n• first\n  • under it\n"
                + "• second\n1. one\n2. two\nquoted line\nand more\nlet x = 1\n  y",
            "the plain flavour carries the words without the markup")
    }
}
