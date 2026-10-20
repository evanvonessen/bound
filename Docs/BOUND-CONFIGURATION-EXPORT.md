# Configuration export

The shared Settings home has **Enable Developer Features** immediately below
**Reset Settings to Default**. It defaults to off and reveals **Export All Config**.
Export opens the system Files save picker with a `Bound-Config-<timestamp>.json`
document. The user chooses the destination. Canceling allows another export;
resetting settings turns Developer Features off again.

Export is read-only. It does not apply a new default profile, change mappings,
perform an import, or alter the current layouts. Saved controller mappings are
included even when the controller is disconnected. Finish Arrange Views with
Done and save binding edits before exporting.

## JSON schema 1

`format` is `bound-configuration`. The file includes the app version/build,
export time, screen dimensions in points, and device model family. It contains:

- `preferences.settings`: global controls, opacity, audio/display preferences,
  UI/layout choices, companion button assignments, and each PiP view's settings.
- `preferences.touchControlLayouts`: every saved skin's portrait and landscape
  button positions and sizes.
- `preferences.landscapeCommon`: landscape option and common companion settings.
- `preferences.controllerModeOff` and `preferences.controllerModeOn`: separate
  game screen placement, saved options, view placements, opacities, layer order,
  button positions and visibility. The on namespace is `controller-unified`.
- `preferences.legacyControllerLayouts`: retained old mode arrangements, kept
  distinct from the current active namespace.
- `controllerMappings`: complete custom bindings, grouped by zero-based player,
  game type and controller type. Each physical input maps to an action identifier,
  input type and continuous-input flag. None and system Overlay are distinct
  actions. Missing inputs in a saved map are unbound.
- `connectedControllerDefaults`: default maps for currently connected controllers,
  to interpret maps that have not been customized.
- `effectiveInterface`: the actual UI, theme, screen layout and mode selection.

Preference keys retain their runtime spelling. Data values have a `storageType`
of `data`, their exact `base64` bytes, and `decodedJSON` when readable as JSON.
This preserves placement structures without requiring opaque archives to be
decoded by hand. Positions, size fractions, opacity, overlap and canvas flags
remain unchanged. Shared implicit defaults are materialized; missing option
placement keys still refer to that app build's bundled geometry defaults.

The export uses a settings allowlist, not a full UserDefaults or database dump.
It excludes accounts, credentials, ROMs, saves, notes, per-ROM progress, service
state, developer-tool state, and database record identifiers. The file is a
reviewable input for preparing future bundled defaults, not an automatic import
format. Confirm the intended preset before promoting values to shipping defaults.

## Validation

The Simulator UI check verifies row order, the export gate, persistence across
launches, cancel and retry, saving through Files, and reset. The saved JSON was
read back from the Files destination and parsed successfully; temporary files
from the save and cancel attempts were removed. An unsigned Release iPhone build
passed. Physical iPhone Files providers and real wireless controllers were not
exercised in this change.

Ten focused integration checks passed, covering exact arrangement bytes and
opacities, disconnected/custom controller mappings, fresh-install values,
non-mutating export, temporary-file cleanup, and reset preserving accounts,
ROMs and saves.
