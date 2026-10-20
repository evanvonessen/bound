# Configuration export

The shared Settings home has **Enable Developer Features** immediately below
**Reset Settings to Default**. It defaults to off and reveals **Export All Config**.
Export opens the system Files save picker with a `Bound-Config-<timestamp>.json`
document. The user chooses the destination. Canceling allows another export;
resetting settings turns Developer Features off again.

Export is read-only. It does not apply a new default profile, perform an import,
or alter the current layouts. Saved controller mappings are included even when
the controller is disconnected. Finish Arrange Views with Done and save binding
edits before exporting.

## Promoting an export to app defaults

An exported file can be reviewed and used to prepare the app's bundled first
install defaults. Only explicitly selected portable preference values are
promoted; device metadata and private or per-ROM data are excluded. Controller
maps use the app's separate default-mapping path.

The shipped profile is `Delta/Bound/Resources/BoundDefaultConfiguration-v1.json`.
It contains the active settings and GBA/MFi bindings from the reviewed export,
without the retired controller-mode layouts or device metadata.

Bundled preferences register as defaults, so a saved value on an existing install
continues to take precedence. Landscape layouts for Controller Mode on and off
are kept in their separate exported namespaces. When an existing install has
saved landscape arrangements, startup omits the bundled landscape defaults so
legacy layout migrations can still run. A profile marker keeps the bundled
defaults enabled after first-install migrations. Reset removes saved preference
values and re-registers the bundled profile, restoring the same settings and
layouts that a fresh install receives. Accounts, ROMs, saves and per-ROM data
remain outside preference reset.

## JSON schema 1

`format` is `bound-configuration`. The file includes the app version/build,
export time, screen dimensions in points, and device model family. It contains:

- `preferences.settings`: global controls, opacity, audio/display preferences,
  UI/layout choices, companion button assignments, and each PiP view's settings.
  This records the permanent 18-point button grid and the always-enabled
  Controller View Navigation behavior; retired toggle and spacing values do
  not affect the exported effective settings. Controller navigation routes to
  companion views in landscape when Controller Mode or Allow Controller to
  Control Multiview is enabled.
- `preferences.touchControlLayouts`: every saved skin's portrait and landscape
  button positions and sizes.
- `preferences.landscapeCommon`: landscape option and common companion settings.
- `preferences.controllerModeOff` and `preferences.controllerModeOn`: separate
  game screen placement, saved options, view placements, opacities, layer order,
  button positions and visibility. The on namespace is `controller-unified`.
  Button positions are independent between modes. Each placement records which
  buttons use full screen width; older placements without that marker retain
  their safe-area canvas until moved.
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
Menu, Friend and Multiview use a permanent 18-point grid centered on the full
screen while arranging. Button frames clamp at the horizontal screen edges and
retain the safe-area height. New or moved placements use full horizontal screen
width; older placements remain on their safe-area canvas until moved.

The export uses a settings allowlist, not a full UserDefaults or database dump.
It excludes accounts, credentials, ROMs, saves, notes, per-ROM progress, service
state, developer-tool state, and database record identifiers. The file is a
reviewable input for preparing bundled defaults, not an automatic import format.
Values promoted from it become the app's defaults for new installs and for users
who reset their settings.

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
