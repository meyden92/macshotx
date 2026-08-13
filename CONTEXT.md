# macshot

A free and open-source screenshot utility for macOS power users — capture,
annotate, and route screenshots through automated post-capture actions.

## Language

**Capture hotkey**:
The single global shortcut that begins a capture. It carries no intent — it always presents the capture overlay, whatever the user means to capture.
_Avoid_: Capture shortcut, region hotkey, per-mode hotkey

**Capture overlay**:
The surface presented on every display when a capture begins. Hosts the selection, window snap, and all annotation tools; there is no separate window-picking UI, and no capture bypasses it.
_Avoid_: Region picker, capture window, overlay window

**Selection**:
The adjustable rectangle inside the capture overlay that will become the captured image. Confined to a single display; committed by confirming the capture. Seeded three ways — dragged freehand, filled to the whole display, or snapped to a window — after which it is one and the same rectangle however it began.
_Avoid_: Region, capture rect, selection rect

**Window snap**:
Capture-overlay behavior where hovering highlights the window under the cursor and clicking makes that window the Selection. Toggleable mid-capture; respects window z-order.
_Avoid_: Window detection, window picking, hover-to-pick

**Boundary snap**:
Selection edges magnetically snapping to strong color edges in the frozen screen image while drawing, moving, or resizing the selection. Bypassable with a modifier key.
_Avoid_: Edge snap, magnetic edges, pixel snap

**Resolution box**:
The editable width × height control attached to the selection, including aspect-ratio locks and size presets (armable before or after drawing).
_Avoid_: Dimension readout, size badge, W×H label

**Annotation**:
A visual element placed on a capture — shape, line, arrow, drawing, text, callout, step marker, redaction, measure, loupe, or spotlight. Annotations bake into the final image when the capture is confirmed.
_Avoid_: Markup, element, overlay item

**Measure**:
An annotation that draws a dimension line between two points, with end caps and a readout of the distance in device pixels. Nearly-axis-aligned drags snap to the axis; holding a direction key scans the frozen screen image for the nearest colour boundaries and offers that span instead.
_Avoid_: Ruler, dimension tool, measurement line

**Loupe**:
An annotation that magnifies: a source circle over the detail, a lens circle showing it enlarged, and a connector between them. Magnification is the ratio of the two radii. Distinct from the colour sampler's live magnifier, which is not an annotation.
_Avoid_: Magnifier, zoom bubble, callout zoom

**Spotlight**:
An annotation that emphasises by subtraction: its region keeps full brightness while a single composed layer dims everything else. Several spotlights cooperate — every region stays bright and the dim never stacks.
_Avoid_: Vignette, mask, dim layer, focus region

**Selected set**:
The annotations currently selected for group editing (moving, deleting, duplicating, restyling together). A single selected annotation is the one-element case.
_Avoid_: Selection (reserved for the capture rectangle), multi-selection

**Marquee**:
The transient rectangle a select-tool drag inside the Selection sweeps across the canvas; every annotation it touches joins the selected set.
_Avoid_: Lasso, rubber band (reserved for drawing the Selection), selection box

**Tool-options row**:
The contextual strip of style controls (color, widths, styles, fonts) reflecting the active tool or the selected set.
_Avoid_: Style strip, options bar

**Beautify**:
The capture-overlay toggle that wraps the Selection's content in a decorative backdrop with padding, rounded corners, a drop shadow and an optional macOS window frame. Previewed live; never persisted as a toggle, only as a look.
_Avoid_: Prettify, frame, decorate

**Backdrop**:
The decorative surface — solid colour, linear gradient or mesh gradient — a beautified capture is composited onto.
_Avoid_: Background, wallpaper, canvas

**Composition**:
The composited result of the capture plus its post-processing — the single image the pipeline receives when a capture is confirmed.
_Avoid_: Output, final image, render

**Image effects**:
The non-destructive brightness, contrast, saturation and sharpness adjustment of the capture content. Applies to the capture only: never to annotations, never to the backdrop.
_Avoid_: Filters, adjustments, colour correction

**Overlay chrome**:
The non-image UI the capture overlay floats above the frozen screenshot — toolbar strip, tool-options row, resolution box, helper and hint cards, tooltips, floating affordances and post-processing panels — as distinct from the capture content beneath them. All of it is Liquid Glass built through one kit.
_Avoid_: HUD, panel, controls

**Pipeline**:
The ordered list of actions executed after a capture is taken. One pipeline is configured in Settings and runs after every capture.
_Avoid_: Workflow, action chain

**Pipeline action**:
A single unit of work in a pipeline (open in editor, copy image, save to disk, upload, copy URL, run shell command, open in app, extract text). Actions execute in order; the pipeline halts on the first failure.
_Avoid_: Step, task

**Destination**:
A configured upload target (S3-compatible, SFTP, FTP, WebDAV, or custom HTTP uploader). Reusable — any pipeline "Upload to destination" action picks one by name.
_Avoid_: Target, upload target, endpoint

**Filename template**:
A ShareX-style token string used by the Save to disk action, and as the local filename for any temporary file an Upload action sends.
_Avoid_: Naming pattern, filename pattern
