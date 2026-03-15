import AppKit
import SwiftUI

private let syntaxCore = DiaCoreBridge()

private enum EditorTheme {
    private struct Palette {
        let background: NSColor
        let gutterBackground: NSColor
        let text: NSColor
        let cursor: NSColor
        let selection: NSColor
        let lineNumber: NSColor
        let keyword: NSColor
        let arrow: NSColor
        let comment: NSColor
        let label: NSColor
    }

    private static let darkPalette = Palette(
        background: NSColor(srgbRed: 30 / 255, green: 30 / 255, blue: 46 / 255, alpha: 1),
        gutterBackground: NSColor(srgbRed: 24 / 255, green: 24 / 255, blue: 37 / 255, alpha: 1),
        text: NSColor(srgbRed: 205 / 255, green: 214 / 255, blue: 244 / 255, alpha: 1),
        cursor: NSColor(srgbRed: 245 / 255, green: 224 / 255, blue: 220 / 255, alpha: 1),
        selection: NSColor(srgbRed: 69 / 255, green: 71 / 255, blue: 90 / 255, alpha: 1),
        lineNumber: NSColor(srgbRed: 88 / 255, green: 91 / 255, blue: 112 / 255, alpha: 1),
        keyword: NSColor(srgbRed: 137 / 255, green: 180 / 255, blue: 250 / 255, alpha: 1),
        arrow: NSColor(srgbRed: 249 / 255, green: 226 / 255, blue: 175 / 255, alpha: 1),
        comment: NSColor(srgbRed: 108 / 255, green: 112 / 255, blue: 134 / 255, alpha: 1),
        label: NSColor(srgbRed: 166 / 255, green: 227 / 255, blue: 161 / 255, alpha: 1)
    )

    private static let lightPalette = Palette(
        background: NSColor(srgbRed: 239 / 255, green: 241 / 255, blue: 245 / 255, alpha: 1),
        gutterBackground: NSColor(srgbRed: 230 / 255, green: 233 / 255, blue: 239 / 255, alpha: 1),
        text: NSColor(srgbRed: 76 / 255, green: 79 / 255, blue: 105 / 255, alpha: 1),
        cursor: NSColor(srgbRed: 220 / 255, green: 138 / 255, blue: 120 / 255, alpha: 1),
        selection: NSColor(srgbRed: 204 / 255, green: 208 / 255, blue: 218 / 255, alpha: 1),
        lineNumber: NSColor(srgbRed: 156 / 255, green: 160 / 255, blue: 176 / 255, alpha: 1),
        keyword: NSColor(srgbRed: 30 / 255, green: 102 / 255, blue: 245 / 255, alpha: 1),
        arrow: NSColor(srgbRed: 223 / 255, green: 142 / 255, blue: 29 / 255, alpha: 1),
        comment: NSColor(srgbRed: 140 / 255, green: 143 / 255, blue: 161 / 255, alpha: 1),
        label: NSColor(srgbRed: 64 / 255, green: 160 / 255, blue: 43 / 255, alpha: 1)
    )

    private static func color(_ keyPath: KeyPath<Palette, NSColor>) -> NSColor {
        NSColor(name: nil) { appearance in
            switch appearance.bestMatch(from: [.darkAqua, .aqua]) {
            case .darkAqua:
                darkPalette[keyPath: keyPath]
            default:
                lightPalette[keyPath: keyPath]
            }
        }
    }

    static let background = color(\.background)
    static let gutterBackground = color(\.gutterBackground)
    static let text = color(\.text)
    static let cursor = color(\.cursor)
    static let selection = color(\.selection)
    static let lineNumber = color(\.lineNumber)
    static let keyword = color(\.keyword)
    static let arrow = color(\.arrow)
    static let comment = color(\.comment)
    static let label = color(\.label)
}

struct CodeEditorView: NSViewRepresentable {
    @Binding var text: String
    let font: NSFont

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> EditorContainerView {
        let scrollView = configuredScrollView()
        let textView = configuredTextView(in: scrollView)
        let gutterView = LineNumberGutterView(textView: textView, scrollView: scrollView)
        let containerView = EditorContainerView(scrollView: scrollView, gutterView: gutterView)

        context.coordinator.textView = textView
        context.coordinator.scrollView = scrollView
        textView.delegate = context.coordinator

        containerView.onLayout = { [self, weak textView, weak scrollView] in
            guard let textView,
                  let scrollView
            else { return }

            synchronizeLayout(for: textView, in: scrollView)
        }

        context.coordinator.installBoundsObserver()

        updateTextView(textView, with: text)
        updateFont(for: textView)
        synchronizeLayout(for: textView, in: scrollView)
        return containerView
    }

    func updateNSView(_ nsView: EditorContainerView, context: Context) {
        guard let textView = nsView.textView else { return }

        if textView.string != text {
            context.coordinator.isUpdatingFromSwiftUI = true
            let selectedRanges = textView.selectedRanges
            updateTextView(textView, with: text)
            textView.selectedRanges = selectedRanges
            context.coordinator.isUpdatingFromSwiftUI = false
        }

        updateFont(for: textView)

        synchronizeLayout(for: textView, in: nsView.scrollView)
        nsView.needsLayout = true
        nsView.gutterView.needsDisplay = true
    }

    private func configuredScrollView() -> NSScrollView {
        let scrollView = NSScrollView(frame: .zero)
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.drawsBackground = true
        scrollView.backgroundColor = EditorTheme.background
        scrollView.contentView.postsBoundsChangedNotifications = true
        return scrollView
    }

    private func configuredTextView(in scrollView: NSScrollView) -> NSTextView {
        let textView: NSTextView
        if let existingTextView = scrollView.documentView as? NSTextView {
            textView = existingTextView
        } else {
            let textStorage = NSTextStorage()
            let layoutManager = NSLayoutManager()
            let textContainer = NSTextContainer(size: NSSize(width: 1, height: CGFloat.greatestFiniteMagnitude))
            textContainer.widthTracksTextView = true
            layoutManager.addTextContainer(textContainer)
            textStorage.addLayoutManager(layoutManager)

            let createdTextView = CodeTextView(frame: .zero, textContainer: textContainer)
            scrollView.documentView = createdTextView
            textView = createdTextView
        }

        let contentSize = scrollView.contentSize

        fputs("[editor] configured textViewClass=\(String(describing: type(of: textView))) scrollViewClass=\(String(describing: type(of: scrollView))) contentSize=\(contentSize.debugDescription)\n", stderr)

        textView.minSize = NSSize(width: 0, height: contentSize.height)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainerInset = NSSize(width: 8, height: 12)
        textView.postsFrameChangedNotifications = true

        textView.textContainer?.containerSize = NSSize(
            width: contentSize.width,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainer?.widthTracksTextView = true

        textView.isEditable = true
        textView.isSelectable = true
        textView.allowsUndo = true
        textView.isRichText = false
        textView.importsGraphics = false
        textView.usesFindPanel = true
        textView.font = font
        textView.drawsBackground = true
        textView.backgroundColor = EditorTheme.background
        textView.textColor = EditorTheme.text
        textView.insertionPointColor = EditorTheme.cursor
        textView.selectedTextAttributes = [
            .backgroundColor: EditorTheme.selection,
        ]
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.typingAttributes = MermaidHighlighter.baseAttributes(font: font)

        let seededSize = NSSize(
            width: max(contentSize.width, 1),
            height: max(contentSize.height, 1)
        )
        textView.frame = NSRect(origin: .zero, size: seededSize)

        return textView
    }

    private func updateTextView(_ textView: NSTextView, with text: String) {
        textView.string = text
        MermaidHighlighter.apply(to: textView, font: font)
        textView.typingAttributes = MermaidHighlighter.baseAttributes(font: font)
    }

    private func updateFont(for textView: NSTextView) {
        guard textView.font?.fontName != font.fontName || textView.font?.pointSize != font.pointSize else {
            return
        }

        textView.font = font
        MermaidHighlighter.apply(to: textView, font: font)
        textView.typingAttributes = MermaidHighlighter.baseAttributes(font: font)
    }

    private func synchronizeLayout(for textView: NSTextView, in scrollView: NSScrollView) {
        guard let textContainer = textView.textContainer,
              let layoutManager = textView.layoutManager
        else { return }

        let clipBounds = scrollView.contentView.bounds
        let availableWidth = max(clipBounds.width, scrollView.contentSize.width, 1)
        let availableHeight = max(clipBounds.height, scrollView.contentSize.height, 1)

        textView.minSize = NSSize(width: 0, height: availableHeight)
        textView.setFrameSize(NSSize(width: availableWidth, height: max(textView.frame.height, availableHeight)))

        let inset = textView.textContainerInset
        let containerWidth = max(availableWidth - (inset.width * 2), 1)
        textContainer.containerSize = NSSize(
            width: containerWidth,
            height: CGFloat.greatestFiniteMagnitude
        )

        layoutManager.ensureLayout(for: textContainer)

        let usedHeight = layoutManager.usedRect(for: textContainer).height
        let targetHeight = max(usedHeight + (inset.height * 2), availableHeight)
        if abs(textView.frame.height - targetHeight) > 0.5 {
            textView.setFrameSize(NSSize(width: availableWidth, height: targetHeight))
        }

        textView.needsDisplay = true
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CodeEditorView
        var isUpdatingFromSwiftUI = false
        weak var textView: NSTextView?
        weak var scrollView: NSScrollView?
        var boundsObserver: NSObjectProtocol?

        init(_ parent: CodeEditorView) {
            self.parent = parent
        }

        deinit {
            if let boundsObserver {
                NotificationCenter.default.removeObserver(boundsObserver)
            }
        }

        func installBoundsObserver() {
            guard boundsObserver == nil,
                  let scrollView
            else { return }

            boundsObserver = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: scrollView.contentView,
                queue: .main
            ) { [weak self] _ in
                guard let self,
                      let textView = self.textView,
                      let scrollView = self.scrollView
                else { return }

                self.parent.synchronizeLayout(for: textView, in: scrollView)
            }
        }

        func textDidChange(_ notification: Notification) {
            guard !isUpdatingFromSwiftUI,
                  let textView = notification.object as? NSTextView
            else { return }

            parent.text = textView.string
            MermaidHighlighter.apply(to: textView, font: parent.font)
            textView.typingAttributes = MermaidHighlighter.baseAttributes(font: parent.font)
            if let scrollView = self.scrollView {
                parent.synchronizeLayout(for: textView, in: scrollView)
            }
            textView.enclosingScrollView?.superview?.needsDisplay = true
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard commandSelector == #selector(NSResponder.insertNewline(_:)),
                  let selectedRange = textView.selectedRanges.first?.rangeValue
            else { return false }

            let content = textView.string as NSString
            let location = min(selectedRange.location, content.length)
            let lineRange = content.lineRange(for: NSRange(location: location, length: 0))
            let line = content.substring(with: lineRange)
            let insertion = (try? syntaxCore.autoIndentInsertion(prefix: line)) ?? "\n"
            textView.insertText(insertion, replacementRange: selectedRange)
            return true
        }
    }
}

final class EditorContainerView: NSView {
    private enum Metrics {
        static let gutterWidth: CGFloat = 44
    }

    let scrollView: NSScrollView
    let gutterView: LineNumberGutterView
    var onLayout: (() -> Void)?

    var textView: NSTextView? {
        scrollView.documentView as? NSTextView
    }

    init(scrollView: NSScrollView, gutterView: LineNumberGutterView) {
        self.scrollView = scrollView
        self.gutterView = gutterView
        super.init(frame: .zero)
        addSubview(gutterView)
        addSubview(scrollView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let gutterWidth = min(Metrics.gutterWidth, bounds.width)
        gutterView.frame = NSRect(x: 0, y: 0, width: gutterWidth, height: bounds.height)
        scrollView.frame = NSRect(
            x: gutterWidth,
            y: 0,
            width: max(bounds.width - gutterWidth, 0),
            height: bounds.height
        )
        gutterView.needsDisplay = true
        onLayout?()
    }
}

private final class CodeTextView: NSTextView {
    override var isOpaque: Bool {
        true
    }
}

final class LineNumberGutterView: NSView {
    private weak var textView: NSTextView?
    private weak var scrollView: NSScrollView?
    private let numberFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
    private lazy var numberAttributes: [NSAttributedString.Key: Any] = [
        .font: numberFont,
        .foregroundColor: EditorTheme.lineNumber,
    ]

    override var isFlipped: Bool {
        true
    }

    init(textView: NSTextView, scrollView: NSScrollView) {
        self.textView = textView
        self.scrollView = scrollView
        super.init(frame: .zero)
        wantsLayer = true

        let notificationCenter = NotificationCenter.default
        notificationCenter.addObserver(
            self,
            selector: #selector(setNeedsRedisplay),
            name: NSText.didChangeNotification,
            object: textView
        )
        notificationCenter.addObserver(
            self,
            selector: #selector(setNeedsRedisplay),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )
    }

    @available(*, unavailable)
    required init(coder _: NSCoder) { fatalError() }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func setNeedsRedisplay() {
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        guard let textView,
              let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer,
              let scrollView
        else { return }

        EditorTheme.gutterBackground.setFill()
        dirtyRect.fill()

        EditorTheme.selection.withAlphaComponent(0.4).setStroke()
        let borderX = bounds.width - 0.5
        NSBezierPath.strokeLine(
            from: NSPoint(x: borderX, y: dirtyRect.minY),
            to: NSPoint(x: borderX, y: dirtyRect.maxY)
        )

        let content = textView.string as NSString
        let visibleRect = scrollView.contentView.bounds
        let inset = textView.textContainerInset

        guard content.length > 0 else {
            drawNumber(1, y: inset.height, lineHeight: 17)
            return
        }

        let glyphRange = layoutManager.glyphRange(forBoundingRect: visibleRect, in: textContainer)
        let characterRange = layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)

        var lineNumber = 1
        let prefixEnd = min(characterRange.location, content.length)
        for index in 0 ..< prefixEnd where content.character(at: index) == 0x0A {
            lineNumber += 1
        }

        var characterIndex = characterRange.location
        while characterIndex < NSMaxRange(characterRange), characterIndex < content.length {
            let lineRange = content.lineRange(for: NSRange(location: characterIndex, length: 0))
            let glyphIndex = layoutManager.glyphIndexForCharacter(at: characterIndex)
            let lineRect = layoutManager.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: nil)
            let y = lineRect.minY + inset.height - visibleRect.minY

            drawNumber(lineNumber, y: y, lineHeight: lineRect.height)

            lineNumber += 1
            let nextCharacterIndex = NSMaxRange(lineRange)
            guard nextCharacterIndex > characterIndex else { break }
            characterIndex = nextCharacterIndex
        }
    }

    private func drawNumber(_ number: Int, y: CGFloat, lineHeight: CGFloat) {
        let string = NSAttributedString(string: "\(number)", attributes: numberAttributes)
        let size = string.size()
        string.draw(at: NSPoint(
            x: bounds.width - size.width - 8,
            y: y + (lineHeight - size.height) / 2
        ))
    }
}

private enum MermaidHighlighter {
    static func baseAttributes(font: NSFont) -> [NSAttributedString.Key: Any] {
        [
            .font: font,
            .foregroundColor: EditorTheme.text,
        ]
    }

    static func apply(to textView: NSTextView, font: NSFont) {
        guard let textStorage = textView.textStorage else { return }

        let string = textStorage.string
        let utf16Count = string.utf16.count
        let fullRange = NSRange(location: 0, length: utf16Count)

        textStorage.beginEditing()
        textStorage.setAttributes(baseAttributes(font: font), range: fullRange)

        let spans = (try? syntaxCore.mermaidHighlightSpans(source: string)) ?? []
        for span in spans {
            let range = NSRange(
                location: utf16Offset(in: string, charIndex: span.start),
                length: utf16Offset(in: string, charIndex: span.end) - utf16Offset(in: string, charIndex: span.start)
            )
            let color: NSColor
            switch span.kind {
            case "keyword":
                color = EditorTheme.keyword
            case "operator":
                color = EditorTheme.arrow
            case "comment":
                color = EditorTheme.comment
            case "label":
                color = EditorTheme.label
            default:
                continue
            }
            textStorage.addAttribute(.foregroundColor, value: color, range: range)
        }

        textStorage.endEditing()
    }

    private static func utf16Offset(in string: String, charIndex: Int) -> Int {
        guard charIndex > 0 else { return 0 }
        let clampedIndex = min(charIndex, string.count)
        let index = string.index(string.startIndex, offsetBy: clampedIndex)
        return string.utf16.distance(from: string.utf16.startIndex, to: index.samePosition(in: string.utf16) ?? string.utf16.endIndex)
    }
}
