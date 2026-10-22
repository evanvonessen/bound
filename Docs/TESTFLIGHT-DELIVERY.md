# Personal TestFlight delivery

The destination is **Evan Only Internal Testing**, internal group
`165fa14a-3c1a-4c4c-ae90-0189de227adc`, containing only
`evanvonessen.dev@gmail.com`. Its automatic distribution setting covers uploads
from Xcode. The name can change without changing the group ID.

## Xcode Cloud

Bound's existing **Default** workflow builds `main` through
`Bound.xcodeproj` / `Bound`. Its saved **TestFlight Internal Testing - iOS**
post-action distributes the **Archive - iOS** artifact to this group. This is
the step that distributes Cloud archives; the group's automatic Xcode upload
setting does not include Cloud builds by itself.

The workflow is managed in App Store Connect, not by the local manifest:

[Default workflow](https://appstoreconnect.apple.com/teams/9d720eb1-930c-481d-addb-7aca59955ee5/xcode-cloud/products/8a247e82-d842-45d7-b913-eb52ea163861/workflows/B7F71582-2706-4334-BA13-532900F2DF55).

## On-demand releases

Normal commits and pushes do not start or require TestFlight builds. Continue
local focused checks and Release validation for app changes, then batch changes
until the user asks for a TestFlight build or delivery. Documentation-only
updates do not need an app build.

The Default workflow is enabled with **Manual Start - Branch: main** as its only
start condition. Branch-change, schedule, pull-request and tag triggers are not
configured. **Clean is off**, allowing derived-data/cache restoration, and the
only action is **Archive - iOS**. A separate Build - iOS action was removed
because the distribution archive already builds the app. Keep the existing
internal distribution post-action. Use a clean build only to diagnose a concrete
cache issue, then restore caching; do not routinely pay for clean builds.

For a requested release:

1. Select the requested validated commit on main and verify the remote hash.
2. Inspect existing queued/running builds and upload receipts for that commit.
   Reuse an existing build; do not start duplicates or retry an uncertain upload.
3. Check available Cloud minutes. If exhausted, report the blocker and stop
   delivery work. Do not start a run just to test this procedure.
4. Manually start one Default workflow run for the requested main revision.
   Verify its recorded commit matches; do not substitute a newer moving main.
5. Verify Apple processing and the internal TestFlight post-action for that
   exact build. A successful push or archive alone is not completed delivery.

Do not poll Cloud after every ordinary push. Do not automatically create a local
distribution archive or upload from this Mac, including through Organizer, when
Cloud cannot deliver. The workflow remains available for requested releases.

A local upload requires an explicit human request for that upload. Implementing,
committing or pushing a change alone does not authorize a local upload. After
that explicit request, the signed-in Mac can use:

```sh
python3 PrototypeTools/deliver-testflight.py --revision <published-commit> --check
python3 PrototypeTools/deliver-testflight.py --revision <published-commit> --upload
```

The on-demand release policy is recorded in `AGENTS.md`.
The local commands above are manual delivery tools, not an automatic fallback,
a Git hook or an unattended service. They require this Mac, Xcode, network access
and a working developer account in Xcode. They do not purchase Cloud minutes.
An upload already accepted by Apple continues processing independently of this
policy; its receipt must be checked before any explicitly requested retry.

The tool checks both origin URLs and the live `origin/main` commit, builds a
temporary snapshot of that commit, checks pinned sources and audited privacy
manifests, creates a signed Release iPhone archive through the existing
project/scheme, verifies its signature, and asks Xcode to upload with automatic
distribution signing. Xcode manages a unique build number. The export is
restricted to internal TestFlight testing. Existing Xcode account authorization
is used; the tool does not store passwords, API keys, certificates or profiles
in the repository. Xcode may manage distribution signing assets while exporting.

All output and receipts stay under ignored `.build/testflight-delivery/`.
Unrelated working-tree edits and personal files are excluded from the snapshot.
The tool never pushes or rewrites Git history. `--archive-only` validates the
archive without exporting or uploading.

A successful upload receipt means Apple accepted the upload; it does not mean
processing completed or the build is available in TestFlight. Verify the
processed version/build and group membership in App Store Connect. If a retry
finds a receipt for the same commit it does not upload again. If an upload was
interrupted before a receipt was written, inspect App Store Connect before
retrying to avoid a duplicate upload.

After a local upload, check the actual exported build number and set Xcode
Cloud's **Settings → Build Number → Next Build Number** above it if necessary.
This keeps local and Cloud uploads from colliding when Cloud capacity returns.
Do not equate a successful Git push, archive, or upload with completed delivery.
If signing, authentication, processing or distribution fails, report that
specific blocker and retain the logs rather than claiming delivery succeeded.

## Automatic installation on devices

On **each phone**, use the Apple Account that accepted the internal invitation,
open **TestFlight → Bound → App Information → Automatic Updates**, and turn it
on. Apple controls when an available build installs. The group and Cloud
workflow cannot remotely enable this device setting or guarantee immediate
installation. Delivery checks do not establish phone gameplay/performance parity.

This personal internal testing setup does not resolve the separate public
distribution licensing review recorded in `TESTFLIGHT-READINESS.md`.

## Apple references

- [Cloud TestFlight distribution](https://developer.apple.com/documentation/xcode/distributing-your-xcode-cloud-builds-through-testflight)
- [Internal tester distribution](https://developer.apple.com/help/app-store-connect/test-a-beta-version/add-internal-testers)
- [Cloud build numbers](https://developer.apple.com/documentation/xcode/setting-the-next-build-number-for-xcode-cloud-builds)
- [TestFlight automatic updates](https://testflight.apple.com/)
