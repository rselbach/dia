import "./style.css";

import { EditorView, basicSetup } from "codemirror";
import { EditorState, Prec, Compartment } from "@codemirror/state";
import { oneDark } from "@codemirror/theme-one-dark";
import { keymap } from "@codemirror/view";
import { indentWithTab } from "@codemirror/commands";
import { mermaid as mermaidLang } from "codemirror-lang-mermaid";
import mermaid from "mermaid";
import DOMPurify from "dompurify";

import { load as loadSettings, save as saveSettings, mermaidConfig, themeEntry, FONT_OPTIONS, THEME_OPTIONS } from "./settings.js";
import { EventsOn } from "../wailsjs/runtime/runtime";
import {
    OpenFile,
    SaveWithContent,
    SaveAsWithContent,
    SetDirty,
    ConfirmDiscard,
} from "../wailsjs/go/main/App";

// -- Settings --------------------------------------------------------------

let currentSettings = loadSettings();

function fontTheme(family, size) {
    return EditorView.theme({
        ".cm-content, .cm-gutters": {
            fontFamily: family,
            fontSize: `${size}px`,
        },
    });
}

const fontCompartment = new Compartment();
const previewPane = document.getElementById("preview-pane");

function applyTheme(themeValue) {
    mermaid.initialize(mermaidConfig(themeValue));
    previewPane.style.background = themeEntry(themeValue).previewBg || "#ffffff";
    renderDiagram();
}

function applySettings(s) {
    currentSettings = s;
    editor.dispatch({
        effects: fontCompartment.reconfigure(fontTheme(s.fontFamily, s.fontSize)),
    });
    applyTheme(s.diagramTheme);
}

// -- Mermaid init ----------------------------------------------------------

mermaid.initialize(mermaidConfig(currentSettings.diagramTheme));
previewPane.style.background = themeEntry(currentSettings.diagramTheme).previewBg || "#ffffff";

// -- Default content -------------------------------------------------------

const DEFAULT_CONTENT = `flowchart TD
    A[Start] --> B{Is it working?}
    B -->|Yes| C[Great!]
    B -->|No| D[Debug]
    D --> B
`;

// -- State -----------------------------------------------------------------

let renderCounter = 0;
let debounceTimer = null;

// -- DOM refs --------------------------------------------------------------

const editorPane = document.getElementById("editor-pane");
const previewEl = document.getElementById("preview");
const errorBar = document.getElementById("error-bar");

// -- CodeMirror setup ------------------------------------------------------

const editor = new EditorView({
    parent: editorPane,
    state: EditorState.create({
        doc: DEFAULT_CONTENT,
        extensions: [
            basicSetup,
            oneDark,
            fontCompartment.of(fontTheme(currentSettings.fontFamily, currentSettings.fontSize)),
            Prec.highest(keymap.of([indentWithTab, {
                key: "Enter",
                run: (view) => {
                    const head = view.state.selection.main.head;
                    const line = view.state.doc.lineAt(head);
                    const leading = line.text.match(/^\s*/)[0];
                    view.dispatch(
                        view.state.replaceSelection("\n" + leading),
                        { scrollIntoView: true }
                    );
                    return true;
                },
            }])),
            mermaidLang(),
            EditorView.updateListener.of((update) => {
                if (update.docChanged) {
                    SetDirty(true);
                    scheduleRender();
                }
            }),
        ],
    }),
});

// -- Mermaid rendering -----------------------------------------------------

function showError(msg) {
    errorBar.textContent = msg;
    errorBar.classList.remove("hidden");
}

function clearError() {
    errorBar.classList.add("hidden");
    errorBar.textContent = "";
}

// DOMPurify config: allow SVG elements and attributes that Mermaid uses
const PURIFY_CONFIG = {
    USE_PROFILES: { svg: true, svgFilters: true },
    ADD_TAGS: ["foreignObject"],
    ADD_ATTR: ["dominant-baseline", "marker-end", "marker-start"],
};

async function renderDiagram() {
    const source = editor.state.doc.toString().trim();
    if (!source) {
        previewEl.textContent = "";
        clearError();
        return;
    }

    renderCounter++;
    const id = `mermaid-${renderCounter}`;

    try {
        const { svg } = await mermaid.render(id, source);
        const clean = DOMPurify.sanitize(svg, PURIFY_CONFIG);
        previewEl.replaceChildren();
        previewEl.insertAdjacentHTML("afterbegin", clean);
        const svgEl = previewEl.querySelector("svg");
        if (svgEl) {
            svgEl.removeAttribute("width");
            svgEl.removeAttribute("height");
            svgEl.removeAttribute("style");
            svgEl.setAttribute("preserveAspectRatio", "xMidYMid meet");
        }
        clearError();
    } catch (err) {
        showError(err.message || String(err));
        // mermaid may leave an orphan element on failed render
        const orphan = document.getElementById(id);
        if (orphan) orphan.remove();
    }
}

function scheduleRender() {
    clearTimeout(debounceTimer);
    debounceTimer = setTimeout(renderDiagram, 300);
}

// Initial render
renderDiagram();

// -- Splitter drag ---------------------------------------------------------

const splitter = document.getElementById("splitter");
let isDragging = false;

splitter.addEventListener("mousedown", (e) => {
    isDragging = true;
    splitter.classList.add("dragging");
    e.preventDefault();
});

document.addEventListener("mousemove", (e) => {
    if (!isDragging) return;
    const containerWidth = document.getElementById("app").offsetWidth;
    const newWidth = Math.max(200, Math.min(e.clientX, containerWidth - 200));
    editorPane.style.flex = `0 0 ${newWidth}px`;
});

document.addEventListener("mouseup", () => {
    if (!isDragging) return;
    isDragging = false;
    splitter.classList.remove("dragging");
});

// -- Context menu (Copy as PNG) --------------------------------------------

const ctxMenu = document.createElement("div");
ctxMenu.id = "context-menu";
ctxMenu.classList.add("hidden");
document.body.appendChild(ctxMenu);

const copyPngBtn = document.createElement("div");
copyPngBtn.className = "context-menu-item";
copyPngBtn.textContent = "Copy as PNG";
ctxMenu.appendChild(copyPngBtn);

document.getElementById("preview-pane").addEventListener("contextmenu", (e) => {
    const svgEl = previewEl.querySelector("svg");
    if (!svgEl) return;
    e.preventDefault();
    ctxMenu.style.left = `${e.clientX}px`;
    ctxMenu.style.top = `${e.clientY}px`;
    ctxMenu.classList.remove("hidden");
});

document.addEventListener("click", () => ctxMenu.classList.add("hidden"));
document.addEventListener("contextmenu", (e) => {
    if (!e.target.closest("#preview-pane")) ctxMenu.classList.add("hidden");
});

copyPngBtn.addEventListener("click", async () => {
    ctxMenu.classList.add("hidden");
    const svgEl = previewEl.querySelector("svg");
    if (!svgEl) return;

    try {
        await navigator.clipboard.write([
            new ClipboardItem({ "image/png": svgToPngBlob(svgEl) }),
        ]);
    } catch (err) {
        showError(`Copy failed: ${err.message || err}`);
    }
});

function svgToPngBlob(svgEl) {
    return new Promise((resolve, reject) => {
        const clone = svgEl.cloneNode(true);
        const viewBox = svgEl.getAttribute("viewBox");
        if (!viewBox) {
            reject(new Error("SVG has no viewBox"));
            return;
        }
        const [, , vbW, vbH] = viewBox.split(/[\s,]+/).map(Number);
        const scale = 2;
        const w = vbW * scale;
        const h = vbH * scale;
        clone.setAttribute("width", w);
        clone.setAttribute("height", h);
        clone.setAttribute("xmlns", "http://www.w3.org/2000/svg");

        const data = new XMLSerializer().serializeToString(clone);
        const url = `data:image/svg+xml;charset=utf-8,${encodeURIComponent(data)}`;

        const img = new Image();
        img.onload = () => {
            const canvas = document.createElement("canvas");
            canvas.width = w;
            canvas.height = h;
            const ctx = canvas.getContext("2d");
            ctx.fillStyle = previewPane.style.background || "#ffffff";
            ctx.fillRect(0, 0, w, h);
            ctx.drawImage(img, 0, 0, w, h);
            canvas.toBlob((blob) => {
                if (blob) resolve(blob);
                else reject(new Error("canvas.toBlob returned null"));
            }, "image/png");
        };
        img.onerror = () => reject(new Error("Failed to load SVG as image"));
        img.src = url;
    });
}

// -- Go event listeners ----------------------------------------------------

function setEditorContent(text) {
    editor.dispatch({
        changes: {
            from: 0,
            to: editor.state.doc.length,
            insert: text,
        },
    });
    SetDirty(false);
    scheduleRender();
}

// New file
EventsOn("file:new", async () => {
    const ok = await ConfirmDiscard();
    if (!ok) return;
    setEditorContent(DEFAULT_CONTENT);
});

// Open file
EventsOn("file:open-request", async () => {
    const ok = await ConfirmDiscard();
    if (!ok) return;

    const result = await OpenFile();
    if (result.error) {
        showError(result.error);
        return;
    }
    if (result.content !== undefined && result.content !== "") {
        setEditorContent(result.content);
    }
});

// Save
EventsOn("file:save", async () => {
    const content = editor.state.doc.toString();
    const result = await SaveWithContent(content);
    if (result.error) {
        showError(result.error);
    }
});

// Save As
EventsOn("file:save-as", async () => {
    const content = editor.state.doc.toString();
    const result = await SaveAsWithContent(content);
    if (result.error) {
        showError(result.error);
    }
});

// Live theme switch (temporary, doesn't persist)
EventsOn("theme:set", (theme) => {
    applyTheme(theme);
});

// -- Settings modal --------------------------------------------------------

const overlay = document.getElementById("settings-overlay");
const fontFamilySel = document.getElementById("set-font-family");
const fontSizeInput = document.getElementById("set-font-size");
const themeSel = document.getElementById("set-diagram-theme");

FONT_OPTIONS.forEach((f) => {
    const opt = document.createElement("option");
    opt.value = f;
    opt.textContent = f;
    fontFamilySel.appendChild(opt);
});

THEME_OPTIONS.forEach((t) => {
    const opt = document.createElement("option");
    opt.value = t.value;
    opt.textContent = t.label;
    themeSel.appendChild(opt);
});

function openSettings() {
    fontFamilySel.value = currentSettings.fontFamily;
    fontSizeInput.value = currentSettings.fontSize;
    themeSel.value = currentSettings.diagramTheme;
    overlay.classList.remove("hidden");
}

function closeSettings() {
    overlay.classList.add("hidden");
}

document.getElementById("settings-cancel").addEventListener("click", closeSettings);
overlay.addEventListener("click", (e) => {
    if (e.target === overlay) closeSettings();
});

document.getElementById("settings-save").addEventListener("click", () => {
    const s = {
        fontFamily: fontFamilySel.value,
        fontSize: parseInt(fontSizeInput.value, 10) || 14,
        diagramTheme: themeSel.value,
    };
    saveSettings(s);
    applySettings(s);
    closeSettings();
});

EventsOn("settings:open", openSettings);
