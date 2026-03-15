package main

// #cgo pkg-config: gtk4 webkitgtk-6.0
// #include <gtk/gtk.h>
// #include <webkit/webkit.h>
//
// extern void _gotk4_gio2_AsyncReadyCallback(GObject*, GAsyncResult*, gpointer);
//
// static GtkAlertDialog* _dia_new_alert_dialog(void) {
//   return (GtkAlertDialog*)g_object_new(GTK_TYPE_ALERT_DIALOG, NULL);
// }
//
// static void _dia_webview_get_snapshot(
//   WebKitWebView *webview,
//   int region,
//   int options,
//   GCancellable *cancellable,
//   GAsyncReadyCallback callback,
//   gpointer user_data
// ) {
//   webkit_web_view_get_snapshot(
//     webview,
//     (WebKitSnapshotRegion)region,
//     (WebKitSnapshotOptions)options,
//     cancellable,
//     callback,
//     user_data
//   );
// }
import "C"
import (
	"context"
	"runtime"
	"unsafe"

	"github.com/diamondburned/gotk4-webkitgtk/pkg/webkit/v6"
	"github.com/diamondburned/gotk4/pkg/core/gbox"
	"github.com/diamondburned/gotk4/pkg/core/gcancel"
	coreglib "github.com/diamondburned/gotk4/pkg/core/glib"
	"github.com/diamondburned/gotk4/pkg/gio/v2"
	"github.com/diamondburned/gotk4/pkg/gtk/v4"
)

// newAlertDialog creates a GtkAlertDialog with the given message.
// The generated bindings omit the constructor because the C function
// uses printf-style varargs.
func newAlertDialog(message string) *gtk.AlertDialog {
	obj := C._dia_new_alert_dialog()
	alert := coreglib.AssumeOwnership(unsafe.Pointer(obj)).Cast().(*gtk.AlertDialog)
	alert.SetMessage(message)
	return alert
}

// webViewSnapshot starts an asynchronous snapshot of the WebView.
// The generated bindings only include SnapshotFinish; this wraps the
// C start function so the full async round-trip works.
func webViewSnapshot(
	webView *webkit.WebView,
	region webkit.SnapshotRegion,
	options webkit.SnapshotOptions,
	ctx context.Context,
	callback gio.AsyncReadyCallback,
) {
	cWebView := (*C.WebKitWebView)(unsafe.Pointer(coreglib.InternObject(webView).Native())) //nolint:govet // standard gotk4 CGo interop pattern

	cancellable := gcancel.GCancellableFromContext(ctx)
	defer runtime.KeepAlive(cancellable)
	cCancellable := (*C.GCancellable)(unsafe.Pointer(cancellable.Native())) //nolint:govet // standard gotk4 CGo interop pattern

	var cCallback C.GAsyncReadyCallback
	var cUserData C.gpointer
	if callback != nil {
		cCallback = (*[0]byte)(C._gotk4_gio2_AsyncReadyCallback)
		cUserData = C.gpointer(gbox.AssignOnce(callback)) //nolint:govet // standard gotk4 CGo interop pattern
	}

	C._dia_webview_get_snapshot(
		cWebView,
		C.int(region),
		C.int(options),
		cCancellable,
		cCallback,
		cUserData,
	)
	runtime.KeepAlive(webView)
	runtime.KeepAlive(ctx)
	runtime.KeepAlive(callback)
}
