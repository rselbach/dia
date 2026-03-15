package main

import (
	"encoding/json"
	"fmt"
	"strings"
)

// PreviewTheme bundles a theme's visual info with its Mermaid JS config.
type PreviewTheme struct {
	ID                string
	PreviewBackground string
	ErrorColor        string
	MermaidConfigJS   string
}

func diagramHTML(source string, pt *PreviewTheme) string {
	sourceJSON, err := json.Marshal(source)
	if err != nil {
		escaped := htmlEscape(fmt.Sprintf("failed to encode source: %s", err))
		return fmt.Sprintf(
			`<!doctype html><html><body style='background:%s'><pre style='color:%s'>%s</pre></body></html>`,
			pt.PreviewBackground, pt.ErrorColor, escaped,
		)
	}

	// The HTML template below is a direct port of the Rust linux-ui/src/main.rs
	// diagram_html function. The mermaid library requires innerHTML to render SVG
	// diagrams -- the source variable is safely JSON-encoded above, and the SVG
	// output comes from mermaid.render which is sandboxed via securityLevel: "strict".
	return fmt.Sprintf(`<!doctype html>
<html>
  <head>
    <meta charset="utf-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1" />
    <style>
      html, body {
        margin: 0;
        height: 100%%;
        font-family: "Iosevka", "Fira Code", monospace;
        background: %s;
      }
      #root {
        height: 100%%;
        display: flex;
        align-items: center;
        justify-content: center;
        padding: 16px;
        box-sizing: border-box;
      }
      #diagram {
        width: 100%%;
        height: 100%%;
        min-width: 0;
        min-height: 0;
        display: flex;
        align-items: center;
        justify-content: center;
        overflow: hidden;
        touch-action: none;
        cursor: grab;
        user-select: none;
        -webkit-user-select: none;
      }
      #diagram.is-panning {
        cursor: grabbing;
      }
      #diagram .pan-inner {
        width: 100%%;
        height: 100%%;
        display: flex;
        align-items: center;
        justify-content: center;
      }
      #diagram .zoom-inner {
        width: 100%%;
        height: 100%%;
        display: flex;
        align-items: center;
        justify-content: center;
      }
      #diagram .zoom-inner svg {
        width: 100%%;
        height: 100%%;
        max-width: 100%%;
        max-height: 100%%;
        user-select: none;
        -webkit-user-select: none;
      }
      #error {
        color: %s;
        white-space: pre-wrap;
        font-family: monospace;
      }
    </style>
    <script src="mermaid.min.js"></script>
  </head>
  <body>
    <div id="root">
      <div id="diagram"></div>
      <pre id="error"></pre>
    </div>
    <script>
      const source = %s;
      const diagramEl = document.getElementById("diagram");
      const errorEl = document.getElementById("error");
      const zoomInnerClass = "zoom-inner";
      const panInnerClass = "pan-inner";
      const zoomMin = 0.25;
      const zoomMax = 4;
      let zoomLevel = 1;
      let panX = 0;
      let panY = 0;

      function hasRenderedSVG() {
        return diagramEl.querySelector("svg") !== null;
      }

      function applyPan() {
        const panInner = diagramEl.querySelector("." + panInnerClass);
        if (!panInner) return;
        panInner.style.transform = "translate(" + panX + "px, " + panY + "px)";
      }

      function panBounds(level) {
        const zoom = Number.isFinite(level) ? level : zoomLevel;
        const width = diagramEl ? diagramEl.clientWidth : 0;
        const height = diagramEl ? diagramEl.clientHeight : 0;
        const maxX = Math.max(0, ((width * zoom) - width) / 2);
        const maxY = Math.max(0, ((height * zoom) - height) / 2);
        return { maxX: maxX, maxY: maxY };
      }

      function clampPan(x, y, level) {
        const bounds = panBounds(level);
        return {
          x: Math.max(-bounds.maxX, Math.min(bounds.maxX, x)),
          y: Math.max(-bounds.maxY, Math.min(bounds.maxY, y)),
        };
      }

      window.setPan = function(x, y) {
        const clamped = clampPan(x, y, zoomLevel);
        panX = clamped.x;
        panY = clamped.y;
        applyPan();
        return { x: panX, y: panY };
      };

      function applyZoom() {
        const zoomInner = diagramEl.querySelector("." + zoomInnerClass);
        if (!zoomInner) return;
        zoomInner.style.transform = "scale(" + zoomLevel + ")";
        zoomInner.style.transformOrigin = "center center";
      }

      window.setZoom = function(level) {
        const newZoom = Math.min(zoomMax, Math.max(zoomMin, level));
        const clamped = clampPan(panX, panY, newZoom);
        panX = clamped.x;
        panY = clamped.y;
        zoomLevel = newZoom;
        applyPan();
        applyZoom();
        return zoomLevel;
      };

      window.zoomIn = function() {
        return window.setZoom(Math.round((zoomLevel + 0.1) * 100) / 100);
      };

      window.zoomOut = function() {
        return window.setZoom(Math.round((zoomLevel - 0.1) * 100) / 100);
      };

      window.resetZoom = function() {
        return window.setZoom(1);
      };

      function bindInteractions() {
        if (diagramEl.dataset.interactionsBound === "1") return;
        diagramEl.dataset.interactionsBound = "1";

        var isPanning = false;
        var activePointerId = null;
        var lastX = 0;
        var lastY = 0;
        var gestureStartZoom = 1;

        diagramEl.addEventListener("pointerdown", function(event) {
          if (event.button !== 0 || !hasRenderedSVG() || zoomLevel <= 1) return;
          isPanning = true;
          activePointerId = event.pointerId;
          lastX = event.clientX;
          lastY = event.clientY;
          diagramEl.classList.add("is-panning");
          diagramEl.setPointerCapture(event.pointerId);
          event.preventDefault();
        });

        diagramEl.addEventListener("pointermove", function(event) {
          if (!isPanning || event.pointerId !== activePointerId) return;
          var dx = event.clientX - lastX;
          var dy = event.clientY - lastY;
          lastX = event.clientX;
          lastY = event.clientY;
          window.setPan(panX + dx, panY + dy);
          event.preventDefault();
        });

        function stopPanning(event) {
          if (!isPanning) return;
          if (activePointerId !== null && event.pointerId !== activePointerId) return;
          isPanning = false;
          activePointerId = null;
          diagramEl.classList.remove("is-panning");
        }

        diagramEl.addEventListener("pointerup", stopPanning);
        diagramEl.addEventListener("pointercancel", stopPanning);
        diagramEl.addEventListener("lostpointercapture", stopPanning);

        diagramEl.addEventListener("wheel", function(event) {
          if (!hasRenderedSVG()) return;
          event.preventDefault();
          var delta = event.deltaY === 0 ? event.deltaX : event.deltaY;
          if (delta === 0) return;
          var scaleFactor = Math.exp(-delta * 0.002);
          window.setZoom(zoomLevel * scaleFactor);
        }, { passive: false });

        document.addEventListener("gesturestart", function(event) {
          gestureStartZoom = zoomLevel;
          event.preventDefault();
        }, { passive: false });

        document.addEventListener("gesturechange", function(event) {
          event.preventDefault();
          window.setZoom(gestureStartZoom * event.scale);
        }, { passive: false });
      }

      if (typeof mermaid === "undefined") {
        errorEl.textContent = "failed to load local Mermaid bundle";
      } else {
        mermaid.initialize(%s);
        bindInteractions();

        if (!source.trim()) {
          diagramEl.textContent = "";
          panX = 0;
          panY = 0;
          errorEl.textContent = "";
        } else {
          mermaid.render("dia-preview", source)
            .then(function(result) {
              // mermaid.render returns sanitized SVG via securityLevel: "strict"
              diagramEl.insertAdjacentHTML("beforeend",
                '<div class="' + panInnerClass + '"><div class="' + zoomInnerClass + '">' + result.svg + '</div></div>');
              var svg = diagramEl.querySelector("." + zoomInnerClass + " svg");
              if (svg) {
                var padding = 16;
                var bbox = svg.getBBox();
                if (bbox.width > 0 && bbox.height > 0) {
                  var minX = bbox.x - padding;
                  var minY = bbox.y - padding;
                  var w = bbox.width + (padding * 2);
                  var h = bbox.height + (padding * 2);
                  svg.setAttribute("viewBox", minX + " " + minY + " " + w + " " + h);
                }

                svg.setAttribute("width", "100%%");
                svg.setAttribute("height", "100%%");
                svg.setAttribute("preserveAspectRatio", "xMidYMid meet");
                svg.style.display = "block";
                svg.style.maxWidth = "100%%";
                svg.style.maxHeight = "100%%";
              }
              window.setPan(panX, panY);
              applyZoom();
              errorEl.textContent = "";
            })
            .catch(function(err) {
              diagramEl.textContent = "";
              errorEl.textContent = String(err);
            });
        }
      }
    </script>
  </body>
</html>
`, pt.PreviewBackground, pt.ErrorColor, string(sourceJSON), pt.MermaidConfigJS)
}

func htmlEscape(s string) string {
	s = strings.ReplaceAll(s, "&", "&amp;")
	s = strings.ReplaceAll(s, "<", "&lt;")
	s = strings.ReplaceAll(s, ">", "&gt;")
	s = strings.ReplaceAll(s, `"`, "&quot;")
	return s
}
