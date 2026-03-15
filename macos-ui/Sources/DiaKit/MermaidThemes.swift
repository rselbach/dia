import Foundation

public struct MermaidThemeInfo: Identifiable, Hashable, Sendable {
    public let id: String
    public let label: String
    public let previewBackground: String
    public let errorColor: String

    public init(id: String, label: String, previewBackground: String, errorColor: String) {
        self.id = id
        self.label = label
        self.previewBackground = previewBackground
        self.errorColor = errorColor
    }
}

public enum MermaidThemeCatalog {
    public static let defaultThemeID = "default"

    private struct ThemeDef {
        let id: String
        let label: String
        let previewBackground: String
        let errorColor: String
        let themeVariables: [(String, String)]?
    }

    private static let catppuccinVars: [(String, String)] = [
        ("primaryColor", "#89b4fa"),
        ("primaryBorderColor", "#74c7ec"),
        ("secondaryColor", "#cba6f7"),
        ("secondaryBorderColor", "#b4befe"),
        ("tertiaryColor", "#a6e3a1"),
        ("tertiaryBorderColor", "#94e2d5"),
        ("lineColor", "#bac2de"),
        ("textColor", "#cdd6f4"),
    ]

    private static let draculaVars: [(String, String)] = [
        ("primaryColor", "#bd93f9"),
        ("primaryBorderColor", "#6272a4"),
        ("secondaryColor", "#ff79c6"),
        ("secondaryBorderColor", "#ff79c6"),
        ("tertiaryColor", "#50fa7b"),
        ("tertiaryBorderColor", "#50fa7b"),
        ("lineColor", "#f8f8f2"),
        ("textColor", "#f8f8f2"),
    ]

    private static let nordVars: [(String, String)] = [
        ("primaryColor", "#5e81ac"),
        ("primaryBorderColor", "#4c566a"),
        ("secondaryColor", "#a3be8c"),
        ("secondaryBorderColor", "#4c566a"),
        ("tertiaryColor", "#d08770"),
        ("tertiaryBorderColor", "#4c566a"),
        ("lineColor", "#4c566a"),
        ("textColor", "#2e3440"),
    ]

    private static let synthwaveVars: [(String, String)] = [
        ("primaryColor", "#f72585"),
        ("primaryBorderColor", "#ff6ec7"),
        ("secondaryColor", "#7209b7"),
        ("secondaryBorderColor", "#b5179e"),
        ("tertiaryColor", "#4361ee"),
        ("tertiaryBorderColor", "#4cc9f0"),
        ("lineColor", "#ff6ec7"),
        ("textColor", "#f0e6ff"),
    ]

    private static let roseVars: [(String, String)] = [
        ("primaryColor", "#e11d48"),
        ("primaryBorderColor", "#be123c"),
        ("secondaryColor", "#fb7185"),
        ("secondaryBorderColor", "#f43f5e"),
        ("tertiaryColor", "#fda4af"),
        ("tertiaryBorderColor", "#fb7185"),
        ("lineColor", "#881337"),
        ("textColor", "#4c0519"),
    ]

    private static let oceanVars: [(String, String)] = [
        ("primaryColor", "#0077b6"),
        ("primaryBorderColor", "#023e8a"),
        ("secondaryColor", "#00b4d8"),
        ("secondaryBorderColor", "#0096c7"),
        ("tertiaryColor", "#48cae4"),
        ("tertiaryBorderColor", "#0096c7"),
        ("lineColor", "#03045e"),
        ("textColor", "#03045e"),
    ]

    private static let solarizedVars: [(String, String)] = [
        ("primaryColor", "#268bd2"),
        ("primaryBorderColor", "#2aa198"),
        ("secondaryColor", "#859900"),
        ("secondaryBorderColor", "#859900"),
        ("tertiaryColor", "#b58900"),
        ("tertiaryBorderColor", "#cb4b16"),
        ("lineColor", "#586e75"),
        ("textColor", "#657b83"),
    ]

    private static let themeDefs: [ThemeDef] = [
        ThemeDef(id: "default", label: "Default", previewBackground: "#ffffff", errorColor: "#b91c1c", themeVariables: nil),
        ThemeDef(id: "dark", label: "Dark", previewBackground: "#333333", errorColor: "#f38ba8", themeVariables: nil),
        ThemeDef(id: "forest", label: "Forest", previewBackground: "#ffffff", errorColor: "#b91c1c", themeVariables: nil),
        ThemeDef(id: "neutral", label: "Neutral", previewBackground: "#ffffff", errorColor: "#b91c1c", themeVariables: nil),
        ThemeDef(id: "catppuccin", label: "Catppuccin", previewBackground: "#1e1e2e", errorColor: "#f38ba8", themeVariables: catppuccinVars),
        ThemeDef(id: "dracula", label: "Dracula", previewBackground: "#282a36", errorColor: "#f38ba8", themeVariables: draculaVars),
        ThemeDef(id: "nord", label: "Nord", previewBackground: "#eceff4", errorColor: "#b91c1c", themeVariables: nordVars),
        ThemeDef(id: "synthwave", label: "Synthwave", previewBackground: "#1a1a2e", errorColor: "#f38ba8", themeVariables: synthwaveVars),
        ThemeDef(id: "rose", label: "Rose", previewBackground: "#fff1f2", errorColor: "#b91c1c", themeVariables: roseVars),
        ThemeDef(id: "ocean", label: "Ocean", previewBackground: "#eaf8ff", errorColor: "#b91c1c", themeVariables: oceanVars),
        ThemeDef(id: "solarized", label: "Solarized", previewBackground: "#fdf6e3", errorColor: "#b91c1c", themeVariables: solarizedVars),
    ]

    public static let themes: [MermaidThemeInfo] = themeDefs.map { def in
        MermaidThemeInfo(
            id: def.id,
            label: def.label,
            previewBackground: def.previewBackground,
            errorColor: def.errorColor
        )
    }

    public static func normalizeThemeID(_ themeID: String) -> String {
        guard themeDefs.contains(where: { $0.id == themeID }) else {
            return defaultThemeID
        }
        return themeID
    }

    public static func mermaidConfigJS(for themeID: String) -> String {
        let def = themeDefs.first(where: { $0.id == themeID }) ?? themeDefs[0]
        var parts = [
            "startOnLoad: false",
            "securityLevel: \"strict\"",
        ]

        if let variables = def.themeVariables {
            parts.append("theme: \"base\"")
            let varParts = variables.map { key, value in
                "\(key): \"\(value)\""
            }
            parts.append("themeVariables: { \(varParts.joined(separator: ", ")) }")
        } else {
            parts.append("theme: \"\(def.id)\"")
        }

        return "{ \(parts.joined(separator: ", ")) }"
    }
}
