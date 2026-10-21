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

## Delivery after Codex publishes

After a validated code change is published to `origin/main`, check that the
Cloud run for that exact commit reaches TestFlight. If Cloud's usage limit
blocks the run, report delivery as blocked and stop delivery work. Normal code
validation, commits and pushes may continue. Do not automatically create a local
distribution archive or upload from this Mac, including through Xcode Organizer,
when Cloud minutes are exhausted or Cloud otherwise cannot deliver. Leave the
existing Cloud workflow in place for when capacity becomes available.

A local upload requires an explicit human request for that upload. Implementing,
committing or pushing a change alone does not authorize a local upload. After
that explicit request, the signed-in Mac can use:

```sh
python3 PrototypeTools/deliver-testflight.py --revision <published-commit> --check
python3 PrototypeTools/deliver-testflight.py --revision <published-commit> --upload
```

The Cloud check is part of the Codex publication procedure in `AGENTS.md`.
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
