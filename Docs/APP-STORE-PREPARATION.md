# Bound website and App Store preparation

The intended listing name is **Bound - Game Emulator**. The public website is a
static GitHub Pages site in `Docs/site`, deployed by `.github/workflows/pages.yml`.
Directory case is significant on the Linux deployment runner.

## Listing URLs

- Marketing: `https://evanvonessen.github.io/bound/`
- Support: `https://evanvonessen.github.io/bound/support.html`
- Privacy: `https://evanvonessen.github.io/bound/privacy.html`
- Community rules: `https://evanvonessen.github.io/bound/moderation.html`

The website describes a development version and contains no download button or
availability, price, or regional-release promise. The support address is the
existing public `developer@evanvonessen.com` address.

## Approved icon

`Resources/AppIcon.icon/Assets/BoundIcon.png` restores the previous orange pixel B
artwork, byte-for-byte from `Artwork/AppIcons/BoundIcon-red-pixel.png`. Its original
supplied reference is also restored at `Artwork/BoundIcon-reference.png`. The same
opaque 1024 × 1024 artwork is used for both light and dark in-app primary-icon
previews. Icon Composer uses the original matching orange fill with glass, shadow,
and translucency disabled; iOS applies the Home Screen mask. Existing Xcode asset
wiring and website artwork are preserved.

Active app asset SHA-256:
`c1a0fb65767430b231e18497cc3593188ce5a3ee52742f9305777f969dbf1046`.

The handwritten gray b icon is preserved unchanged at
`Artwork/AppIcons/BoundIcon-handwritten.png`, and the exact supplied
`Untitled_Artwork.png` is archived at
`Artwork/AppIcons/BoundIcon-handwritten-reference.png`.
Archived handwritten app asset SHA-256:
`72f1ac342c042c2aea880b8f1fa08d8cfbd3c1abb8bba6527d8ba349aae3eeec`.

## Privacy source checks

These pages describe the current Delta-based implementation, not the older mGBA
application. The following distinctions are intentional:

- `Delta/Bound/BoundNotesStore.swift`: per-game notes use local app storage.
- `Delta/Bound/BoundFriendAccount.swift`: Supabase sign-in and session refresh;
  session credentials use non-synchronizing, device-only Keychain storage.
- `Delta/Bound/FriendSharingSession.swift` and `AgoraSharingTransport.swift`:
  optional game-video sharing; no published camera, microphone, or game-audio
  stream. Stopping or backgrounding stops sharing; foregrounding does not restart it.
- `Delta/Database/Model/Human/Game.swift`, `SaveState.swift`, and
  `Delta/Syncing/SyncManager.swift`: inherited optional Google Drive/Dropbox sync
  can transfer game files, artwork, saves, and other library files. This is separate
  from Bound friend accounts and must not be described as local-only storage.
- New source includes email/password account creation and email-confirmed account
  deletion. The deletion backend email contract is prepared but not deployed;
  reviewed build 1.0 (4) lacks this UI. See `Backend/account-deletion/README.md`
  for deployment and replacement-build requirements. The public policy subpage describes the upcoming controls without claiming
  they are available in reviewed build 1.0 (4). See `APP-REVIEW-SETUP.md` for
  the draft reply and replacement-build/physical-recording requirements.

The static site has no scripts, forms, external fonts, or site-owned analytics.
GitHub hosting and linked providers have their own privacy practices.

## Validation and release boundaries

Before publication, check all three pages at phone and desktop widths, local links
and anchors, image loading, and icon compilation; follow `AGENTS.md` for the Release
iPhone build. Publishing these informational pages does not distribute an app.

App Store identity must be inspected in the existing account before saving listing
changes. The old record's bundle identity and the current prototype bundle identity
must not be silently reconciled. Do not create a record, choose a permanent bundle
ID or SKU, change signing/team credentials, accept agreements, upload builds, or
distribute the app as part of this preparation. The Agora/AGPL licensing review
remains a distribution gate.
