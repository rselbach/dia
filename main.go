package main

import (
	"embed"
	goruntime "runtime"

	"github.com/wailsapp/wails/v2"
	"github.com/wailsapp/wails/v2/pkg/menu"
	"github.com/wailsapp/wails/v2/pkg/menu/keys"
	"github.com/wailsapp/wails/v2/pkg/options"
	"github.com/wailsapp/wails/v2/pkg/options/assetserver"
	"github.com/wailsapp/wails/v2/pkg/runtime"
)

//go:embed all:frontend/dist
var assets embed.FS

func main() {
	app := NewApp()
	appMenu := buildMenu(app)

	if err := wails.Run(&options.App{
		Title:     "dia - Untitled",
		Width:     1280,
		Height:    800,
		MinWidth:  800,
		MinHeight: 600,
		AssetServer: &assetserver.Options{
			Assets: assets,
		},
		OnStartup:  app.startup,
		OnShutdown: app.shutdown,
		Menu:       appMenu,
		Bind: []any{
			app,
		},
	}); err != nil {
		panic(err)
	}
}

// buildMenu constructs the application menu.
//
//	macOS:         AppMenu (About, Hide, Quit)  |  File  |  Edit (Settings)
//	Linux/Windows: File (+ Quit)                |  Edit (Settings)
func buildMenu(app *App) *menu.Menu {
	appMenu := menu.NewMenu()

	if goruntime.GOOS == "darwin" {
		appMenu.Append(menu.AppMenu())
	}

	fileMenu := appMenu.AddSubmenu("File")
	fileMenu.AddText("New", keys.CmdOrCtrl("n"), func(_ *menu.CallbackData) {
		runtime.EventsEmit(app.ctx, "file:new")
	})
	fileMenu.AddText("Open...", keys.CmdOrCtrl("o"), func(_ *menu.CallbackData) {
		runtime.EventsEmit(app.ctx, "file:open-request")
	})
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
	editMenu.AddText("Settings...", keys.CmdOrCtrl(","), func(_ *menu.CallbackData) {
		runtime.EventsEmit(app.ctx, "settings:open")
	})

	viewMenu := appMenu.AddSubmenu("View")
	themeMenu := viewMenu.AddSubmenu("Theme")
	for _, t := range []string{"default", "dark", "forest", "neutral"} {
		theme := t
		themeMenu.AddText(theme, nil, func(_ *menu.CallbackData) {
			runtime.EventsEmit(app.ctx, "theme:set", theme)
		})
	}

	return appMenu
}
