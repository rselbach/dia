package main

import (
	"os"

	"github.com/diamondburned/gotk4/pkg/gio/v2"
	"github.com/diamondburned/gotk4/pkg/gtk/v4"
)

const appID = "com.rselbach.dia"

func main() {
	app := gtk.NewApplication(appID, gio.ApplicationHandlesOpen)

	var ui *UIState

	app.ConnectActivate(func() {
		if ui == nil {
			ui = newUIState(app)
		}
		ui.startup()
	})

	app.ConnectOpen(func(files []gio.Filer, _ string) {
		if ui == nil {
			ui = newUIState(app)
		}
		ui.startup()
		ui.handleOpenFiles(files)
	})

	os.Exit(app.Run(os.Args))
}
