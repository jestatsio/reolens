# iOS Release Pipeline

How Reolens for iPad/iPhone ships to TestFlight (and, later, the App Store).

## One-time setup in App Store Connect

> As of 0.8.0, iOS shares **one multiplatform App Store Connect record with
> macOS** at bundle id `com.reolens.Reolens` (the `.iOS` suffix is gone). The
> shared record is created once — see [MAC_RELEASE.md](MAC_RELEASE.md). The
> steps below register the iOS bundle IDs + capabilities and confirm the key.

The CI workflow can do everything from this point on, but App Store Connect
itself needs these one-time setups that only you can do (Apple requires a
human at the keyboard for these):

### 1. Register the bundle ID

[developer.apple.com → Certificates, IDs & Profiles → Identifiers](https://developer.apple.com/account/resources/identifiers/list)

- Click **+** → **App IDs** → **App**.
- Bundle ID: **Explicit** → `com.reolens.Reolens`
- Description: `Reolens for iPad/iPhone`
- Capabilities: enable **iCloud** (then click Edit and add the container
  `iCloud.com.reolens.Reolens`). That container should already exist from
  the Mac app's entitlement; if not, register it under the iCloud tab.
  Also enable **App Groups** and add `group.com.reolens.Reolens` (0.5.0
  widget / Live Activity extensions require this to share the
  on-device snapshot + recent-events store with the main app).
- Enable **Push Notifications** — the iOS app declares `aps-environment`
  for the CloudKit silent-push motion relay. Easy to miss now that this
  App ID is shared with the Mac (which doesn't use push); without it the
  iOS archive fails with *"doesn't include the aps-environment
  entitlement"*. After enabling it, delete any stale `Reolens iOS App
  Store…` profiles so CI regenerates them with the capability.
- **Widget extension bundle ID:** also register
  `com.reolens.Reolens.Widgets` as a separate App ID
  with the **App Groups** capability set to the same
  `group.com.reolens.Reolens`. CI's `xcodegen generate` step writes
  the widget target into the Xcode project; the registration here
  lets Apple provision it.

You do **not** need to manually create an Apple Distribution certificate
or provisioning profiles — CI creates / downloads separate App Store
profiles for the app and widget extension against the ASC API key
already in your secrets. Their base names are `Reolens iOS App Store`
and `Reolens iOS Widgets App Store`; after a certificate rotation, CI may
append the signing certificate serial suffix to avoid stale same-name
profiles.

### 2. Create the App Store Connect app record

[appstoreconnect.apple.com → My Apps → + → New App](https://appstoreconnect.apple.com/apps)

- Platforms: **iOS + macOS** — this is the shared multiplatform record
  (see [MAC_RELEASE.md](MAC_RELEASE.md)); you only create it once.
- Name: `Reolens` (must match `CFBundleDisplayName` in
  [`AppiOS/project.yml`](../AppiOS/project.yml))
- Primary Language: English (U.S.)
- Bundle ID: `com.reolens.Reolens` (the one you just registered)
- SKU: `com.reolens.Reolens` (just match the bundle ID)
- User Access: Full Access

Save. You don't need to fill in App Store metadata yet — TestFlight uploads
only need the record to exist.

### 3. Confirm the ASC API key has Admin role

[App Store Connect → Users and Access → Keys (Team Keys)](https://appstoreconnect.apple.com/access/api)

The key whose ID is in `AC_API_KEY_ID` needs **Admin** access. That's
what lets the release script create or refresh App Store provisioning
profiles for both iOS bundle IDs before CI archives.

## First TestFlight upload (local, from your Mac)

Use this path to validate signing on your own machine before relying on CI.

```sh
# 1. Sign in to your Apple ID in Xcode if you haven't:
#    Xcode → Settings → Accounts → "+" → Apple ID.
#    Make sure your team "5M9UT7VQ8Q" appears.

# 2. Provide the ASC API key locally:
export AC_API_KEY_ID="<the key ID from App Store Connect → Users → Keys>"
export AC_API_ISSUER_ID="<the Issuer ID from the same page>"
export AC_API_KEY_P8_BASE64="$(base64 < /path/to/AuthKey_<ID>.p8)"

# 3. Build + archive + upload (Scripts/build-ios.sh does everything):
./Scripts/build-ios.sh upload
```

Expected runtime: ~3–4 minutes archive, ~1–2 minutes upload, then
TestFlight processing takes 10–30 minutes before you can invite testers.

If you want to do the upload step manually through Xcode (e.g. for an
ad-hoc build), drop `upload` for `archive` — that produces
`build-ios/ReolensiOS.xcarchive` which you can open in Xcode's
Organizer (`Window → Organizer`) and distribute from there.

## Subsequent TestFlight uploads (CI, tag-driven)

```sh
git tag v0.2.0
git push --tags
```

This fires `.github/workflows/release.yml`, which runs three jobs:

- **`mac-testflight`** — archives the macOS app and uploads it to the Mac
  App Store / TestFlight (see [MAC_RELEASE.md](MAC_RELEASE.md)).
- **`ios-testflight`** — regenerates the iOS Xcode project, archives,
  exports an IPA, and uploads to TestFlight.
- **`github-release`** — publishes the GitHub Release once both succeed.

Both use the same `AC_API_KEY_*` secrets — they're already configured.
The iOS job bumps `CURRENT_PROJECT_VERSION` to `${{ github.run_number }}`
so every upload is strictly increasing (App Store Connect rejects
duplicates).

## Bumping the iOS version

`MARKETING_VERSION` (the user-facing version, e.g. `0.5.1`) lives in
`AppiOS/project.yml`. Bump it there for major changes; CI handles the
build number automatically.

```yaml
# AppiOS/project.yml
settings:
  base:
    MARKETING_VERSION: "0.5.2"   # ← edit here
```

`MARKETING_VERSION` here MUST match `App/Info.plist`
`CFBundleShortVersionString`. CI's `Scripts/check-versions.sh` blocks
the release if they diverge (AGENTS.md §13).

## Troubleshooting

| Symptom | Likely cause |
|---|---|
| `No profiles for 'com.reolens.Reolens' were found` | Bundle ID not registered in developer.apple.com (step 1). |
| `Apple Distribution: Eric Hare (5M9UT7VQ8Q) is missing` | First archive — let Xcode/altool create it via `-allowProvisioningUpdates`. |
| `The bundle version must be higher than the previously uploaded version` | Bump `CURRENT_PROJECT_VERSION` (local script) — CI does this automatically. |
| `An App Store Connect API key with provided key ID does not exist` | Check `AC_API_KEY_ID` / `AC_API_ISSUER_ID` and that the .p8 file matches. |
| `App record not found` | Step 2 — App Store Connect app record. Has to exist before first upload. |
| TestFlight build stuck "Processing" >1 hour | Apple's pipeline — usually clears overnight. Rare but harmless. |

## Where things live

- iOS Xcode project spec: [`AppiOS/project.yml`](../AppiOS/project.yml)
- Build & upload script: [`Scripts/build-ios.sh`](../Scripts/build-ios.sh)
- CI release pipeline: [`.github/workflows/release.yml`](../.github/workflows/release.yml)
- App entitlements (incl. iCloud): generated under `AppiOS/Resources/ReolensiOS.entitlements`
