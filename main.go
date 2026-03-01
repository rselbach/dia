package main

import (
	"embed"
	goruntime "runtime"

	"github.com/wailsapp/wails/v2"
	"github.com/wailsapp/wails/v2/pkg/menu"
	"github.com/wailsapp/wails/v2/pkg/menu/keys"
	"github.com/wailsapp/wails/v2/pkg/options"
	"github.com/wailsapp/wails/v2/pkg/options/assetserver"
	"github.com/wailsapp/wails/v2/pkg/options/linux"
	"github.com/wailsapp/wails/v2/pkg/runtime"
)

// version is set via -ldflags "-X main.version=v1.2.3" at build time.
var version = "dev"

//go:embed all:frontend/dist
var assets embed.FS

//go:embed build/appicon.png
var appIcon []byte

func main() {
	app := NewApp()
	app.version = version
	appMenu := buildMenu(app)

	if err := wails.Run(&options.App{
		Title:     "dia - Untitled",
		Width:     1280,
		Height:    800,
		MinWidth:  800,
		MinHeight: 600,
		Linux: &linux.Options{
			Icon:             appIcon,
			WebviewGpuPolicy: linux.WebviewGpuPolicyNever,
		},
		AssetServer: &assetserver.Options{
			Assets: assets,
		},
		OnStartup:     app.startup,
		OnShutdown:    app.shutdown,
		OnBeforeClose: app.beforeClose,
		Menu:          appMenu,
		Bind: []any{
			app,
		},
	}); err != nil {
		panic(err)
	}
}

func showAbout(app *App) {
	runtime.EventsEmit(app.ctx, "about:open")
}

// buildMenu constructs the application menu.
//
//	macOS:         AppMenu (About, Settings, Hide, Quit)  |  File  |  Edit  |  View
//	Linux/Windows: File (+ Quit)                         |  Edit (Settings) |  View  |  Help (About)
func buildMenu(app *App) *menu.Menu {
	appMenu := menu.NewMenu()

	settingsCallback := func(_ *menu.CallbackData) {
		runtime.EventsEmit(app.ctx, "settings:open")
	}

	aboutCallback := func(_ *menu.CallbackData) { showAbout(app) }

	if goruntime.GOOS == "darwin" {
		darwinMenu := appMenu.AddSubmenu("dia")
		darwinMenu.AddText("About dia", nil, aboutCallback)
		darwinMenu.AddSeparator()
		darwinMenu.AddText("Settings...", keys.CmdOrCtrl(","), settingsCallback)
		darwinMenu.AddSeparator()
		darwinMenu.AddText("Hide dia", keys.CmdOrCtrl("h"), func(_ *menu.CallbackData) {
			runtime.Hide(app.ctx)
		})
		darwinMenu.AddSeparator()
		darwinMenu.AddText("Quit dia", keys.CmdOrCtrl("q"), func(_ *menu.CallbackData) {
			runtime.Quit(app.ctx)
		})
	}

	fileMenu := appMenu.AddSubmenu("File")
	fileMenu.AddText("New", keys.CmdOrCtrl("n"), func(_ *menu.CallbackData) {
		runtime.EventsEmit(app.ctx, "file:new")
	})
	fileMenu.AddText("Open...", keys.CmdOrCtrl("o"), func(_ *menu.CallbackData) {
		runtime.EventsEmit(app.ctx, "file:open-request")
	})
	openRecentMenu := fileMenu.AddSubmenu("Open Recent")
	app.initRecentMenu(openRecentMenu)
	fileMenu.AddSeparator()
	fileMenu.AddText("Save", keys.CmdOrCtrl("s"), func(_ *menu.CallbackData) {
		runtime.EventsEmit(app.ctx, "file:save")
	})
	fileMenu.AddText("Save As...", keys.Combo("s", keys.CmdOrCtrlKey, keys.ShiftKey), func(_ *menu.CallbackData) {
		runtime.EventsEmit(app.ctx, "file:save-as")
	})
	if goruntime.GOOS != "darwin" {
		fileMenu.AddSeparator()
		fileMenu.AddText("Quit", keys.CmdOrCtrl("q"), func(_ *menu.CallbackData) {
			runtime.Quit(app.ctx)
		})
	}

	editMenu := appMenu.AddSubmenu("Edit")
	if goruntime.GOOS != "darwin" {
		editMenu.AddText("Settings...", keys.CmdOrCtrl(","), settingsCallback)
	}

	viewMenu := appMenu.AddSubmenu("View")
	themeMenu := viewMenu.AddSubmenu("Theme")
	for _, t := range []struct{ value, label string }{
		{"default", "Default"},
		{"dark", "Dark"},
		{"forest", "Forest"},
		{"neutral", "Neutral"},
		{"catppuccin", "Catppuccin"},
		{"dracula", "Dracula"},
		{"nord", "Nord"},
		{"synthwave", "Synthwave"},
		{"rose", "Rose"},
		{"ocean", "Ocean"},
		{"solarized", "Solarized"},
	} {
		theme := t.value
		themeMenu.AddText(t.label, nil, func(_ *menu.CallbackData) {
			runtime.EventsEmit(app.ctx, "theme:set", theme)
		})
	}

	if goruntime.GOOS != "darwin" {
		helpMenu := appMenu.AddSubmenu("Help")
		helpMenu.AddText("About dia", nil, aboutCallback)
	}

	return appMenu
}
