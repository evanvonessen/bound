# Working on Bound 2

Preserve the upstream Delta module/core identities and committed dependency pins and patches. The ordinary app entry is Bound.xcodeproj / Bound. Do not introduce a nested app-build wrapper or restore the old mGBA app.

Keep feature UI concise. Do not add explanatory blurbs, implementation details,
or descriptive paragraphs beneath feature controls. Use clear labels and status
text; keep only required action instructions and consequential warnings. Put
technical explanations in documentation or explicitly opened help instead.

Before publishing changes, run focused checks and a Release iPhone build, preserve unrelated work, and report device/network validation limits. Never commit credentials, signing assets, app data or build output. Public distribution requires the unresolved dependency/SDK licensing review.

Publish completed, validated Bound changes by default unless the user explicitly says not to publish. This is standing project-wide authorization; do not ask for repeat permission. Verify the remote and push validated changes directly to `origin/main` with an explicit refspec; never push the current branch implicitly. Preserve unrelated work rather than including it in the publication. Use original upstream Delta playback smoothness as the performance baseline, and do not claim phone parity from simulator tests.

TestFlight uploads are allowed through the manually invoked Fastlane `beta`
workflow, as explicitly authorized by the user. Do not upload through other
entry points or start an Xcode Cloud run that delivers to TestFlight.
Never check Xcode Cloud usage, available minutes, or capacity. These are standing
user instructions for all chats and supersede older delivery guidance in this
repository. Normal local validation, commits, and pushes remain authorized.
Keep the existing Cloud workflow manual-only; do not enable automatic triggers.

For every Bound prompt, finish the requested work and required validation, then
start `bundle exec fastlane beta` as a detached process. Do not wait for or poll
the beta job; report only that it was started and where its log is saved. This
is the user's standing delivery instruction. Preserve existing upload receipts.

Every new TestFlight upload must automatically receive a build number higher
than the previously uploaded build. Keep Xcode-managed upload numbering enabled
with `manageAppVersionAndBuildNumber: true` in the Fastlane delivery workflow.
Do not disable it, reuse an uploaded build number, or substitute the project's
archive build number for the number assigned during upload. Preserve per-revision
upload receipts so an already accepted revision is not uploaded again.

The current feature set is the permanent Bound baseline. New features are non-experimental unless the user explicitly states otherwise. The experimental customization checkbox/options and Interface & Companion settings menu have been removed; their remaining settings live in Controls. Do not restore those entry points or erase saved customization choices. Keep unrelated upstream Delta controls under the existing `simplifiedSettings` and Debug/Release rules. Preserve saved preferences, and keep UI Version independent of companion appearance. See `Docs/BOUND-EXPERIMENTAL-FEATURES.md`.

The multiplayer additions are explicitly experimental at the user's request.
Keep Settings → Enable Experimental Multiplayer directly below Enable Developer
Features, default off, using `bound.experimental-multiplayer.enabled.v1`. Gate
live sprites, world invitations, battles and multiplayer reader/replay controls;
leave normal friend accounts/video sharing and all existing customization alone.
Disabling must close experimental sessions safely while preserving interrupted
battle recovery. Retired customization keys remain inert.

Keep `Docs/site/current/changelog.html` current when adding user-facing changes.
Use brief bullets grouped by the date each change is added, newest date first,
with no times. Use America/Los_Angeles calendar dates. Preserve the plain HTML
style of the current site and keep earlier entries as a running history.
Within each date, separate Radical Red multiplayer changes from general Bound
changes under their own labels.

## QA Python

For Python QA, use `PrototypeTools/qa-python` for scripts, unit tests, and ad hoc
checks. It selects multi_red's persistent repaired `.venv` and verifies its native
Unicorn library before loading it. Do not create temporary QA environments or
use bare system/Homebrew Python for emulator checks. If validation fails, run
`python3 ../multi_red/tools/setup_qa_python.py`; never bypass the guard or suppress
crash reporting. `BOUND_GAME_SOURCE` can select another game checkout.

## Latest integrated ROM

After pushing completed changes to `origin/main`, run
`python3 ../multi_red/tools/publish_latest_rom.py --bound-repo .` and verify
`../multi_red/build/latest-rom/status.json`. The installed Mac login service also
checks both repositories' remote main heads every minute. It publishes the
matching integrated ROM to multi_red's permanent first-README download link and
refreshes the named main iPhone 17 simulator when booted. Preserve earlier ROMs
and saves; report incompatible game/app commits or service failures accurately.
See `../multi_red/docs/main-simulator.md`. This does not replace the existing
Bound validation or the manual-only TestFlight workflow and prohibition on Cloud usage checks.
