# iCloud ROM updates and GitHub debugging

On iPhone and Mac, open **Settings → Account, Friends, & Sync → ROM Updates**.
Choose the iCloud Drive folder containing `rrbin-integrated.gba`, choose the
existing game to update (or **Add New Game**), and confirm automatic updates.
Repeat this setup on each device. Choosing a folder grants access through the
system file picker; Bound does not need a GitHub credential to read the ROM.

The existing Mac ROM publication service refreshes the file in iCloud Drive.
iCloud must finish making that file available on the device. Bound checks while
active, on returning to the foreground, and when **Check for Updates** is pressed.
iOS does not guarantee checks while Bound is suspended.

Bound accepts only the complete integrated cartridge supported by that app
build. A newer incompatible ROM reports that it needs a matching Bound update;
it does not replace the working game or clear saves. Identical ROM contents do
not trigger another reset. Changing the file name or modification date alone
also does not reset progress.

An update waits until all games and previews have closed, including paused
games. It drains synchronization and manual save restores before changing files.
Before resetting, it copies the old ROM, battery save, save states, multiplayer
checkpoint package, run history, and recovery files to Application Support:

```
ROM Updates/Backups/<update UUID>/
```

Each backup includes a file inventory and library metadata. Backups stay local
and outside Dropbox synchronization. The transaction journal allows an
interrupted update to finish without repeating a completed reset. Do not remove
this folder while an update needs recovery. There is no in-app backup restore
control in this version.

Older ROM identities and saves from a previous reset are rejected by the sync
validation hooks. A new save carries its ROM generation in Harmony metadata.
Progress already synchronized from another device after the same ROM update is
preserved when its stored remote generation and completed local files agree.
Old local automatic/quick snapshots are still reset. Pending downloads,
conflicts, or multiplayer recovery defer the update until they are resolved;
Bound does not silently replace a fresh remote save with a reset. For a managed
ROM after a reset, manual Dropbox restoration accepts only the verified current
remote revision, because older revisions do not expose trustworthy generation
metadata through Harmony.

Unrelated games and their saves are unaffected. **Stop Automatic Updates** stops
future checks and retains completed backups and the installed game.

## Debugging Features

**Settings → Debugging Features** reveals **Sign In to GitHub** in either UI.
The button opens GitHub's device authorization page; enter the displayed code
and authorize **Bound Debugging**. Turning the switch off cancels a pending
sign-in. **Sign Out of GitHub** removes the local credential without signing out
of Bound or Dropbox.

The registered OAuth application uses a public client ID in `Info.plist`.
There is no client secret, personal access token, private repository key, or
embedded developer credential. GitHub tokens are stored in a device-only,
non-synchronizing Keychain item. The device flow requests no additional scopes
and verifies the public GitHub identity. The connection does not grant private
repository access and is independent of ROM distribution.

Official protocol reference:
[GitHub OAuth device flow](https://docs.github.com/en/apps/oauth-apps/building-oauth-apps/authorizing-oauth-apps#device-flow).
