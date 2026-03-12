import AppKit
import SwiftUI

struct EditorFontOption: Identifiable, Hashable {
    let postScriptName: String
    let displayName: String

    var id: String { postScriptName }
}

@MainActor
final class AppPreferences: ObservableObject {
    private enum Keys {
        static let defaultTheme = "defaultTheme"
        static let editorFontName = "editorFontName"
        static let editorFontSize = "editorFontSize"
    }

    static let defaultEditorFontSize: CGFloat = 14
    static let fontSizeRange: ClosedRange<Double> = 10 ... 24

    @Published var defaultTheme: MermaidTheme {
        didSet {
            defaults.set(defaultTheme.rawValue, forKey: Keys.defaultTheme)
        }
    }

    @Published var editorFontName: String {
        didSet {
            defaults.set(editorFontName, forKey: Keys.editorFontName)
        }
    }

    @Published var editorFontSize: Double {
        didSet {
            defaults.set(editorFontSize, forKey: Keys.editorFontSize)
        }
    }

    let fontOptions: [EditorFontOption]

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        fontOptions = Self.loadFontOptions()

        let storedTheme = defaults.string(forKey: Keys.defaultTheme)
            .flatMap(MermaidTheme.init(rawValue:))
            ?? .defaultTheme
        defaultTheme = storedTheme

        let fallbackFontName = Self.defaultFontOption(in: fontOptions).postScriptName
        let storedFontName = defaults.string(forKey: Keys.editorFontName)
        let resolvedFontName = fontOptions.contains { $0.postScriptName == storedFontName }
            ? storedFontName ?? fallbackFontName
            : fallbackFontName
        editorFontName = resolvedFontName

        let storedFontSize = defaults.object(forKey: Keys.editorFontSize) as? Double
        let resolvedFontSize = storedFontSize ?? Self.defaultEditorFontSize
        editorFontSize = min(max(resolvedFontSize, Self.fontSizeRange.lowerBound), Self.fontSizeRange.upperBound)
    }

    var editorFont: NSFont {
        let size = CGFloat(editorFontSize)
        return NSFont(name: editorFontName, size: size)
            ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    private static func defaultFontOption(in options: [EditorFontOption]) -> EditorFontOption {
        if let menlo = options.first(where: { $0.postScriptName == "Menlo-Regular" }) {
            return menlo
        }

        return options.first ?? EditorFontOption(
            postScriptName: NSFont.monospacedSystemFont(ofSize: defaultEditorFontSize, weight: .regular).fontName,
            displayName: "System Monospaced"
        )
    }

    private static func loadFontOptions() -> [EditorFontOption] {
        let fontManager = NSFontManager.shared

        return fontManager.availableFontFamilies.sorted().compactMap { family in
            guard let members = fontManager.availableMembers(ofFontFamily: family) else {
                return nil
            }

            let fixedPitchMembers = members.compactMap { member -> (postScriptName: String, styleName: String)? in
                guard member.count >= 2,
                      let postScriptName = member[0] as? String,
                      let styleName = member[1] as? String,
                      let font = NSFont(name: postScriptName, size: defaultEditorFontSize),
                      font.isFixedPitch
                else {
                    return nil
                }

                return (postScriptName, styleName)
            }

            guard let selectedMember = fixedPitchMembers.first(where: {
                let style = $0.styleName.lowercased()
                return style == "regular" || style == "roman"
            }) ?? fixedPitchMembers.first else {
                return nil
            }

            let lowercasedStyle = selectedMember.styleName.lowercased()
            let displayName: String
            switch lowercasedStyle {
            case "regular", "roman":
                displayName = family
            default:
                displayName = "\(family) \(selectedMember.styleName)"
            }

            return EditorFontOption(
                postScriptName: selectedMember.postScriptName,
                displayName: displayName
            )
        }
    }
}

struct PreferencesView: View {
    @EnvironmentObject private var preferences: AppPreferences

    var body: some View {
        Form {
            LabeledContent("Editor Font") {
                Picker("Editor Font", selection: $preferences.editorFontName) {
                    ForEach(preferences.fontOptions) { option in
                        Text(option.displayName)
                            .font(.custom(option.postScriptName, size: 13))
                            .tag(option.postScriptName)
                    }
                }
                .labelsHidden()
                .frame(minWidth: 320)
            }

            LabeledContent("Font Size") {
                HStack(spacing: 12) {
                    Slider(
                        value: $preferences.editorFontSize,
                        in: AppPreferences.fontSizeRange,
                        step: 1
                    )

                    Text("\(Int(preferences.editorFontSize)) pt")
                        .foregroundStyle(.secondary)
                        .frame(width: 52, alignment: .trailing)
                }
                .frame(minWidth: 320)
            }

            LabeledContent("Default Theme") {
                Picker("Default Theme", selection: $preferences.defaultTheme) {
                    ForEach(MermaidTheme.allCases) { theme in
                        Text(theme.label).tag(theme)
                    }
                }
                .labelsHidden()
                .frame(minWidth: 220)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Preview")
                    .font(.headline)

                Text("flowchart TD\n    A[Greendale] --> B[Troy Barnes]")
                    .font(.custom(preferences.editorFontName, size: preferences.editorFontSize))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .padding(.top, 4)
        }
        .formStyle(.grouped)
        .padding(20)
        .frame(width: 560)
    }
}
