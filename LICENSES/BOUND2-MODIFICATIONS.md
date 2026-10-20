# Bound 2 modification notice

Bound 2 contributors modified this Delta-based source tree. This notice was recorded on 2026-10-04. “Bound 2 contributors” identifies the modification project; it does not invent or assign a copyright owner. Original copyright and license notices remain in place. Root COPYING remains the unmodified GNU Affero General Public License version 3 text; this notice neither replaces third-party licenses nor grants third-party permissions.

The upstream Delta foundation is revision c1d3d068e019e6493eed45654569db3cc5beb86a. Exact component origin revisions and modified snapshot hashes are in PrototypeConfiguration/vendored-sources.json and PrototypeConfiguration/dependency-pins.json. Repository history identifies the actual changes; a release must be tied to its exact committed source and artifact hashes.

Modifications include:

- Bound 2 branding and direct native Bound.xcodeproj / Bound scheme, retaining the upstream Delta module/core identities.
- Friend video with the existing Bound backend/Agora adapter; detached native-frame capture, bounded outgoing/receive handoffs and lifecycle cleanup. DEBUG local/paired fixtures are verification-only.
- Collision-aware PiP placement reserves native/cycle hit regions, caps size uniformly to available space, and preserves complete chart fitting.
- Portrait friend-above-game layouts, landscape full-height gameplay/PiP, configurable placements, original PiP gestures/opacity preferences, notes and a type chart.
- Native haptic preferences, Classic/Minimal appearance choices, accessibility/settings/import refinements and runtime core identity display.
- Pinned, tracked dependency snapshots and generated build inputs, so ordinary Xcode Run does not require submodule initialization, Homebrew, pod install, preparation scripts or mogenerator.
- Local build compatibility patches listed in PrototypePatches, including dependency framework signing separation. Dependencies build unsigned; the containing app signs embedded frameworks with the selected existing app team.

These modifications do not claim authorship of Delta, emulator engines, controller artwork or third-party SDKs. The source repository is public at https://github.com/evanvonessen/bound (verified 2026-10-04), following the user's visibility change. The app has not been certified for public/App Store distribution. Source/permission provenance, proprietary SDK compatibility, asset permissions and exact source-to-binary release matching/completeness remain review gates described in COMPLIANCE-READINESS.md and LICENSES/DEPENDENCY-INVENTORY.md.

- 0.5.5: Bound-specific Notes editing/placeholder/pixel typography and Done bar; local font attribution; independent PiP gesture persistence and chart bounds; safe landscape companion controls; controller mode and companion controller action. Emulator engine/input defaults and Agora transport are retained.
