# Bound App Review setup and reply draft

**Draft only. The user submits it.** The previously reviewed build is **1.0 (4)**.
The account/report/block/settings changes in this branch need a **new uploaded
build**; changing review notes cannot add them to build 4. No upload, submission,
App Store Connect edit, review reply, demo credentials or recording was produced
by this work.

## Before sending the reply

1. Finish the approved Bound backend deployment and verify deployed source,
   privileges and safe rejection paths. The interrupted migration did not apply:
   email deletion and moderation remain pending. Then perform authenticated QA
   with separately approved disposable accounts. Never delete a real account or
   send a real abuse report as a test.
2. Resolve distribution licensing questions for Agora/AGPL, OperatorKit and
   Pokémon artwork. This preparation does not attest full compliance or rights
   to all existing app content. Keep upstream notices and dependency pins.
3. After separate upload authorization, upload a new build using the existing
   app/bundle identity and signing setup. Once processed, select that build under
   the iOS version's Build section and save. Confirm the displayed build number.
   See Apple's [build selection instructions](https://developer.apple.com/help/app-store-connect/manage-builds/choose-a-build-to-submit/).
4. In App Review Information, enter actual reviewer sign-in credentials in the
   designated fields if required. Use placeholders below until the user supplies
   working accounts; do not put passwords in source control or a public link.
   A second consenting account/device is needed to demonstrate actual live sharing.
5. Record on a **physical iPhone running the latest publicly released iOS**,
   using the new uploaded build. Include launch → Library → +/Files import →
   gameplay → save/load → Notes → Types → Friends → account creation and email
   confirmation/sign-in → invite/connect/share → Report/Block/Unblock →
   DELETE MY ACCOUNT confirmation and cancel. Hide passwords, tokens and private
   email contents. Show destructive completion only with separately approved
   disposable-account testing; otherwise label it as confirmation/cancel.
   Simulator footage and synthetic tests do not meet this recording requirement.
6. Use the Desktop Tobu Tobu Girl Deluxe ROM and credit it as described in
   `DEMO-ROM.md`. It is GB/GBC, not GBA. Include the license link and accurate
   edit disclosure in public screenshots/footage. No personal/commercial ROMs
   or unapproved artwork should appear.
7. Attach the actual recording and any requested evidence, fill all placeholders,
   and remove claims not verified on the selected build. Reply through Apps →
   unresolved issues → Resolve → Reply to App Review. Apple supports attachments
   and saving a draft. See [Apple's reply instructions](https://developer.apple.com/help/app-store-connect/manage-submissions-to-app-review/reply-to-app-review-messages/).

## App navigation to verify

- Import: Library → + → Files → select the authorized `.gb` / `.gba` file.
- Gameplay: open its Library entry. Menu provides native save/load controls and
  Friends. The companion button cycles Notes, Types and Friend.
- Account: Menu → Friends → Create Account → **Email + Password only**.
  If requested, confirm the email then return to Sign in. Display name is entered
  for friend invitations, independently of account creation.
- Safety: Friends → actions beside a connected friend → Report or Block;
  Blocked → Unblock. Unblocking requires a new invite to reconnect.
- Deletion: signed-in Friends → red **DELETE MY ACCOUNT** → type the account's
  email. Cancel before submitting when demonstrating the UI with a real account.
  An authenticated successful deletion needs the deployed endpoint and disposable
  QA; interrupted deletion can be retried by its saved operation capability.
- Settings: Library Settings exposes controller opacity and GBA core settings;
  Menu → Bound Settings contains About Bound and Source and licenses.

## Reply draft — use only after the preceding checks

> Thank you for reviewing Bound. We have prepared a replacement build,
> **[version and NEW build number]**, for the changes described below; these
> changes were not present in the previously reviewed build 1.0 (4).
>
> Bound is free and provides the same functionality in every region where it is
> offered. Games are imported by the user; no games are included in the app.
>
> To create an account, open a game, then Menu → Friends → Create Account and
> enter an email and password. Confirm the email if prompted, then return to
> Sign in. Display names are entered separately when inviting a friend.
>
> Report and Block are in the actions beside a friend; Unblock is in the
> Blocked list. Community rules and contact details are available at
> https://evanvonessen.github.io/bound/moderation.html. Limited display-name
> filtering does not inspect all live gameplay video. Reports contain minimal
> metadata and do not automatically capture or upload video or other media.
>
> Account deletion is in signed-in Friends → DELETE MY ACCOUNT and requires
> typing the account's email. It removes that account and its Bound cloud data;
> local games/notes and separate storage-provider copies remain.
>
> Reviewer sign-in details are in App Review Information. **[Enter actual
> working credentials there; remove this placeholder.]** The attached physical
> device recording **[filename, iPhone model, OS version]** shows launch,
> import/play/save, Notes, Types and the account/safety/deletion flows.
> **[State exactly what the recording and disposable QA show; do not claim
> successful deletion or live sharing without that evidence.]**

The free/same-regions sentence reflects the user's explicit confirmation; listing
settings were not changed here. This draft makes no comprehensive legal rights
or compliance certification. Do not send it as a claim that the pending backend,
replacement build or physical recording is already complete.
