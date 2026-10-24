# Local Bound builds and TestFlight

Install dependencies using a managed Ruby (not macOS system Ruby) and Bundler:

```sh
bundle config set --local path .build/gems
bundle install
```

From the repository root, run:

```sh
bundle exec fastlane ios verify
```

This builds `Bound.xcodeproj` / `Bound` in Release for a generic arm64 iPhone.
Build products remain in `.build/ReleaseDerivedData`; raw Xcode logs are saved
under `.build/fastlane/logs`. Swift package versions stay pinned to
`Package.resolved`. The lane does not sign, install, archive, or upload the app,
and does not require Apple credentials.

Running this command directly in Terminal uses no Codex tokens. Asking Codex to
run it still uses tokens for the request, tool calls, and interpreting results;
there is no fixed savings percentage. Keeping repetitive commands and full
build logs outside chat reduces the work Codex needs to do.

This lane covers compilation only. Run checks relevant to each change before
publishing. It does not validate physical-device performance or live networking.
No CI trigger or Xcode Cloud change is configured.

## Personal internal TestFlight

For the latest validated commit already published to `origin/main`:

```sh
bundle exec fastlane beta check:true
bundle exec fastlane beta
```

`beta` reuses `PrototypeTools/deliver-testflight.py`: it checks the remote,
archives a clean snapshot of the published commit, verifies pinned sources,
privacy manifests and signing, then uploads for internal TestFlight testing.
Uncommitted and untracked files are excluded. Xcode uses its existing signed-in
Apple developer account and automatic distribution signing. No new API key,
password file, or signing repository is required. Xcode manages build numbering.

To validate signing without uploading:

```sh
bundle exec fastlane beta archive_only:true
```

Receipts and logs remain under `.build/testflight-delivery/`. An accepted upload
still needs Apple processing; it is not confirmation of TestFlight availability.
Check the processed build in the existing personal internal testing group.
Inspect App Store Connect before retrying an uncertain upload. Do not delete
receipts to force a retry. See [delivery details](../Docs/TESTFLIGHT-DELIVERY.md).
