const STORAGE_KEY = "dia-settings";

const DEFAULTS = {
    fontFamily: "monospace",
    fontSize: 14,
    diagramTheme: "default",
};

export const FONT_OPTIONS = [
    "monospace",
    "JetBrains Mono",
    "Fira Code",
    "Source Code Pro",
    "Cascadia Code",
    "Ubuntu Mono",
];

export const THEME_OPTIONS = [
    { value: "default", label: "Default" },
    { value: "dark", label: "Dark" },
    { value: "forest", label: "Forest" },
    { value: "neutral", label: "Neutral" },
];

export function load() {
    try {
        const raw = localStorage.getItem(STORAGE_KEY);
        if (!raw) return { ...DEFAULTS };
        return { ...DEFAULTS, ...JSON.parse(raw) };
    } catch {
        return { ...DEFAULTS };
    }
}

export function save(settings) {
    localStorage.setItem(STORAGE_KEY, JSON.stringify(settings));
}
