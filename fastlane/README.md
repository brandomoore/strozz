<!-- BEGIN manually-maintained section (kept above the auto-generated docs below).
     If you ever run `fastlane docs`, re-add this section afterward. -->

# TestFlight & App Store Connect credentials

Uploads (`fastlane beta`, `fastlane release`, `fastlane metadata`) authenticate
with an **App Store Connect API key** — no Apple ID or 2FA, so it runs
unattended. The key is a `.p8` file referenced by three environment variables:

| Variable        | Meaning                                                        |
| --------------- | -------------------------------------------------------------- |
| `ASC_KEY_ID`    | The key's "Key ID" (App Store Connect › Users and Access › Integrations › App Store Connect API). |
| `ASC_ISSUER_ID` | The "Issuer ID" (a UUID) at the top of that same Integrations page. |
| `ASC_KEY_PATH`  | Absolute path to the downloaded `AuthKey_XXXXXX.p8`, kept **outside** the repo (e.g. a local `~/.appstoreconnect/keys/` directory). |

## How the values are provided

These live in a **gitignored `.env.fastlane` at the repo root**, created from the
committed [`.env.fastlane.example`](../.env.fastlane.example), and loaded with the
`--env fastlane` flag:

```bash
cp .env.fastlane.example .env.fastlane   # then fill in the three values
fastlane beta --env fastlane             # archive a Release build + upload to TestFlight
```

`.env.fastlane` and any `*.p8` file are gitignored and must **never** be
committed. The `.p8` itself is stored outside the repo (in the local keys
directory `ASC_KEY_PATH` points at); only its path is referenced.

## Shipping a build

The project and scheme are `Strozz`. `APP_IDENTIFIER` is
`com.thatcube.Strozz`, the new universal app record (`6819913170`).
The legacy `com.thatcube.Twozz` record (`6782643545`, **Strozz Old**) is a
separate app and remains available; new builds must not be uploaded to it.
The new app uses App Group `group.com.thatcube.Strozz` and its own rewards
Keychain service. This replacement is not an automatic update to legacy installs.

These lanes still build **tvOS only**. An iPhone/iPad archive must use the
`StrozzMobile` scheme and the same new bundle ID. Any separately maintained
release runner must verify the new app and Top Shelf identifiers before upload;
historical runners/receipts for the legacy app must not be reused unmodified.

### Explicit tvOS development profiles

If automatic signing falls back to a wildcard profile that lacks App Groups,
install an explicit **tvOS App Development** profile for each target. Both
profiles must include `group.com.thatcube.Strozz`, the development certificate
available on your Mac, and your registered test device:

- App: `com.thatcube.Strozz`
- Top Shelf: `com.thatcube.Strozz.TopShelfExtension`

Copy `Config/Signing.xcconfig.example` to the gitignored
`Config/Signing.xcconfig.local`, then set the two installed profile names.
`Config/Development.xcconfig` loads this override, and `project.yml` applies it
only to **Debug builds for a physical tvOS device**. Regenerate with
`./tools/generate-project.sh`; the profile choices survive regeneration.

Without the local file, signing remains automatic. Simulator, iPhone/iPad and
Release configurations do not receive the tvOS development-profile overrides.
The example also lists **separate**, optional iOS development and per-platform
Release distribution overrides. `Config/Release.xcconfig` only consumes the
Release keys, so a development profile cannot leak into a TestFlight archive.
In particular, these profiles do not replace the distribution profiles required
by TestFlight archives. Never disable signing or remove App Groups to work
around an incompatible profile.

### CloudKit distribution prerequisites

The main iOS/tvOS app profiles must include CloudKit container
`iCloud.com.thatcube.Strozz` and App Group `group.com.thatcube.Strozz`.
Apple also requires `aps-environment` for tvOS CloudKit apps; enable Push
Notifications on the app ID and regenerate profiles after changing capabilities.
Release entitlements use `production`, and development uses `development`.
This capability alone does not request user-facing notification permission.
Top Shelf needs the App Group only. Release builds select the Production
CloudKit environment; Debug defaults to Development. A deliberately authorized
device verification can pass `STROZZ_ICLOUD_ENVIRONMENT=Production` to exercise
the same private schema that TestFlight will use.

Validate/import `Config/StrozzAccounts.ckdb` into Development with `cktool`,
then use CloudKit Console's **Deploy Schema Changes** to promote it. Export and
verify Production before uploading. Store management tokens with
`xcrun cktool save-token --type management --method keychain`, never in the
repository or shell command arguments.

```bash
fastlane beta --env fastlane
```

Archives a Release build and uploads it to TestFlight (internal distribution,
`skip_waiting_for_build_processing`). Other lanes: `fastlane build` (archive
only, no upload), `fastlane release` (App Store + metadata), `fastlane metadata`
(text metadata only).

## For agents: missing `.env.fastlane` in a fresh worktree

Because `.env.fastlane` is gitignored, it does **not** exist in a clean clone or a
freshly created worktree. If it's missing, do **not** invent credentials —
recreate it from `.env.fastlane.example`, or copy it from another existing local
worktree that already has it. The concrete machine-specific values and key path
are recorded in the maintainer's gitignored `AGENTS.local.md` (not in the repo).

<!-- END manually-maintained section -->

fastlane documentation
----

# Installation

Make sure you have the latest version of the Xcode command line tools installed:

```sh
xcode-select --install
```

For _fastlane_ installation instructions, see [Installing _fastlane_](https://docs.fastlane.tools/#installing-fastlane)

# Available Actions

### generate_project

```sh
[bundle exec] fastlane generate_project
```

Regenerate the Xcode project from project.yml via XcodeGen

### build

```sh
[bundle exec] fastlane build
```

Archive and export a signed App Store .ipa (no upload)

### beta

```sh
[bundle exec] fastlane beta
```

Build and upload a new build to TestFlight

### metadata

```sh
[bundle exec] fastlane metadata
```

Push App Store text metadata only (name, subtitle, description, keywords)

### release

```sh
[bundle exec] fastlane release
```

Build, upload to App Store, and push metadata

----

This README.md is auto-generated and will be re-generated every time [_fastlane_](https://fastlane.tools) is run.

More information about _fastlane_ can be found on [fastlane.tools](https://fastlane.tools).

The documentation of _fastlane_ can be found on [docs.fastlane.tools](https://docs.fastlane.tools).
