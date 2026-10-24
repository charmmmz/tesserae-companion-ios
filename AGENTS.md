# UI conventions

For SwiftUI work, follow the UI conventions in `DESIGN.md` and reuse
`App/Sources/DesignSystem/TesseraeToolbarActions.swift` and `TesseraeTheme`.

- Put page actions in one `TesseraeToolbarActions` capsule. Root pages use
  `TesseraeRootToolbar`, which adds the shared Send and Settings actions.
  Do not create separate trailing toolbar items, local button sizing, or custom
  capsule backgrounds in feature views.
- Pushed selection pages use the same capsule, including single Done actions.
  Custom sheet-header icons use `.tesseraeModalChromeButtonStyle()`; preview
  overlays use `.tesseraeIconActionLabel()` so Dynamic Type cannot overflow
  their action targets. These shared helpers own sizing and icon styling.
- Keep native Back and modal Cancel/Done in their semantic placements. Use
  accessible SF Symbol labels for simple Save/Done, Cancel/Close, Back, and Add
  actions. Keep complex operations and destructive confirmations descriptive.
- Use `.tesseraeScreenBackground()` on ordinary pages. For Forms/Lists, hide the
  system scroll background. Preserve deliberate photo/camera canvases and the
  original colours of display previews.
- Preserve disabled/loading states, permissions, draft protection, localized
  accessibility names, and minimum 44-point action targets.
- Run `python3 Scripts/check_ui_conventions.py` and relevant existing simulator
  UI flows after UI changes; inspect captured images before updating screenshots.
- When a README screen changes, refresh its original simulator capture and
  update both the image `src` and link `href`. Use a new descriptive filename
  for a visibly changed capture, remove superseded unused images, and update
  `docs/images/readme/README.md` with the capture point and provenance.
