/**
 * @typedef {"system" | "popular" | "specialty"} FontCategory
 *
 * @typedef {object} CodingFont
 * @property {string} id               - Slug identifier
 * @property {string} name             - Display name (doubles as CSS font-family)
 * @property {FontCategory} category
 * @property {boolean} ligatures
 * @property {string} [nerdFontVariant] - Nerd Font name, if one exists
 */

/** @type {CodingFont[]} */
export const CODING_FONTS = [
    // ── System ───────────────────────────────────────────────────────
    { id: "sf-mono",        name: "SF Mono",        category: "system", ligatures: false },
    { id: "menlo",          name: "Menlo",          category: "system", ligatures: false, nerdFontVariant: "MesloLGS Nerd Font" },
    { id: "monaco",         name: "Monaco",         category: "system", ligatures: false },
    { id: "consolas",       name: "Consolas",       category: "system", ligatures: false },
    { id: "cascadia-code",  name: "Cascadia Code",  category: "system", ligatures: true,  nerdFontVariant: "CaskaydiaCove Nerd Font" },
    { id: "cascadia-mono",  name: "Cascadia Mono",  category: "system", ligatures: false, nerdFontVariant: "CaskaydiaMono Nerd Font" },
    { id: "courier-new",    name: "Courier New",    category: "system", ligatures: false },

    // ── Popular ──────────────────────────────────────────────────────
    { id: "fira-code",         name: "Fira Code",         category: "popular", ligatures: true,  nerdFontVariant: "FiraCode Nerd Font" },
    { id: "jetbrains-mono",    name: "JetBrains Mono",    category: "popular", ligatures: true,  nerdFontVariant: "JetBrainsMono Nerd Font" },
    { id: "source-code-pro",   name: "Source Code Pro",   category: "popular", ligatures: false, nerdFontVariant: "SauceCodePro Nerd Font" },
    { id: "hack",              name: "Hack",              category: "popular", ligatures: false, nerdFontVariant: "Hack Nerd Font" },
    { id: "inconsolata",       name: "Inconsolata",       category: "popular", ligatures: false, nerdFontVariant: "Inconsolata Nerd Font" },
    { id: "monaspace-neon",    name: "Monaspace Neon",    category: "popular", ligatures: true },
    { id: "monaspace-argon",   name: "Monaspace Argon",   category: "popular", ligatures: true },
    { id: "monaspace-krypton", name: "Monaspace Krypton", category: "popular", ligatures: true },
    { id: "monaspace-xenon",   name: "Monaspace Xenon",   category: "popular", ligatures: true },
    { id: "monaspace-radon",   name: "Monaspace Radon",   category: "popular", ligatures: true },

    // ── Specialty ────────────────────────────────────────────────────
    { id: "iosevka",           name: "Iosevka",           category: "specialty", ligatures: true,  nerdFontVariant: "Iosevka Nerd Font" },
    { id: "victor-mono",       name: "Victor Mono",       category: "specialty", ligatures: true,  nerdFontVariant: "VictorMono Nerd Font" },
    { id: "ibm-plex-mono",     name: "IBM Plex Mono",     category: "specialty", ligatures: false, nerdFontVariant: "BlexMono Nerd Font" },
    { id: "roboto-mono",       name: "Roboto Mono",       category: "specialty", ligatures: false, nerdFontVariant: "RobotoMono Nerd Font" },
    { id: "ubuntu-mono",       name: "Ubuntu Mono",       category: "specialty", ligatures: false, nerdFontVariant: "UbuntuMono Nerd Font" },
    { id: "dejavu-sans-mono",  name: "DejaVu Sans Mono",  category: "specialty", ligatures: false, nerdFontVariant: "DejaVuSansMono Nerd Font" },
    { id: "hasklig",           name: "Hasklig",           category: "specialty", ligatures: true,  nerdFontVariant: "Hasklug Nerd Font" },
    { id: "noto-sans-mono",    name: "Noto Sans Mono",    category: "specialty", ligatures: false, nerdFontVariant: "NotoSansMono Nerd Font" },
    { id: "anonymous-pro",     name: "Anonymous Pro",     category: "specialty", ligatures: false, nerdFontVariant: "AnonymousPro Nerd Font" },
    { id: "droid-sans-mono",   name: "Droid Sans Mono",   category: "specialty", ligatures: false, nerdFontVariant: "DroidSansMono Nerd Font" },
    { id: "meslo-lg-s",        name: "Meslo LG S",        category: "specialty", ligatures: false, nerdFontVariant: "MesloLGS Nerd Font" },
    { id: "meslo-lg-m",        name: "Meslo LG M",        category: "specialty", ligatures: false, nerdFontVariant: "MesloLGM Nerd Font" },
];

const CATEGORY_ORDER = { system: 0, popular: 1, specialty: 2 };

const CATEGORY_LABELS = {
    system:    "System",
    popular:   "Popular",
    specialty: "Specialty",
};

/**
 * Check whether a font is available for rendering.
 * Uses document.fonts.check — may return false positives when the browser
 * silently substitutes a fallback, but that's acceptable (the user sees a
 * live preview and can tell).
 *
 * @param {string} fontName
 * @returns {boolean}
 */
export function isFontAvailable(fontName) {
    return document.fonts.check(`16px "${fontName}"`);
}

/**
 * Return only the fonts from CODING_FONTS that are installed on this system.
 *
 * - If both a base font and its Nerd Font variant are installed, both appear.
 * - If only the Nerd Font variant is installed, it appears (with that name).
 * - Results are sorted: system -> popular -> specialty, alphabetical within.
 *
 * @returns {CodingFont[]}
 */
export function getAvailableFonts() {
    const results = [];

    for (const font of CODING_FONTS) {
        const baseOK = isFontAvailable(font.name);
        const nerdOK = font.nerdFontVariant && isFontAvailable(font.nerdFontVariant);

        if (baseOK) results.push(font);
        if (nerdOK) {
            results.push({
                ...font,
                id: font.id + "-nerd",
                name: font.nerdFontVariant,
            });
        }
    }

    results.sort((a, b) => {
        const cat = CATEGORY_ORDER[a.category] - CATEGORY_ORDER[b.category];
        if (cat !== 0) return cat;
        return a.name.localeCompare(b.name);
    });

    return results;
}

/**
 * Group fonts by category label for building <optgroup> elements.
 * @param {CodingFont[]} fonts
 * @returns {{ label: string, fonts: CodingFont[] }[]}
 */
export function groupByCategory(fonts) {
    const groups = new Map();
    for (const f of fonts) {
        const label = CATEGORY_LABELS[f.category] || f.category;
        if (!groups.has(label)) groups.set(label, []);
        groups.get(label).push(f);
    }
    return [...groups.entries()].map(([label, items]) => ({ label, fonts: items }));
}
