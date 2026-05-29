# macOS Release Pipeline

How Reolens for Mac ships to the **Mac App Store / TestFlight**. As of 0.8.0
the Mac app rides the **same App Store Connect record as iPhone/iPad** — one
multiplatform app, shared bundle id `com.reolens.Reolens`. (The old
Developer-ID DMG + Sparkle pipeline is retired; see git history if you need
it.)

The CI job is `mac-testflight` in [`.github/workflows/release.yml`](../.github/workflows/release.yml),
which runs [`Scripts/build-mac.sh upload`](../Scripts/build-mac.sh) — the
macOS mirror of `build-ios.sh`. It archives the `ReolensMac` scheme, exports a
signed `.pkg`, and uploads it with `xcrun altool --type macos`.

## One-time setup

Apple requires a human for these; CI can do everything after.

### 1. App ID — `com.reolens.Reolens`

[developer.apple.com → Identifiers](https://developer.apple.com/account/resources/identifiers/list)

This App ID is **shared by the iOS and macOS apps** (that's what makes them one
multiplatform record). It likely already exists from the Mac app's iCloud
container. It must be an **"App"-type** App ID (not a legacy macOS-only one) and
have **all** the capabilities either platform uses:

- **iCloud** → click Edit and attach the container `iCloud.com.reolens.Reolens`
  (CloudKit + iCloud Documents).
- **App Groups** → `group.com.reolens.Reolens`.
- **Push Notifications** ← *easy to miss.* The Mac app doesn't use push, but
  the **iOS** app declares `aps-environment` for the CloudKit silent-push
  motion relay. If Push isn't enabled here, the **iOS** archive fails with
  *"Provisioning profile … doesn't include the aps-environment entitlement"*
  (this bit us migrating off `com.reolens.Reolens.iOS`). After enabling a new
  capability, **delete the stale `Reolens iOS App Store…` profiles** in
  developer.apple.com → Profiles so the build script regenerates them with the
  capability baked in.

You do **not** create profiles by hand — `Scripts/asc_ensure_profile.py`
(`PLATFORM=MAC_APP_STORE`) creates/refreshes the `Reolens Mac App Store`
profile against the ASC API key.

### 2. App Store Connect record (multiplatform)

[appstoreconnect.apple.com → Apps → ➕ → New App](https://appstoreconnect.apple.com/apps)

- Platforms: **iOS *and* macOS** (tick both — one record, both platforms).
- Bundle ID: `com.reolens.Reolens`
- Name: `Reolens`, Primary Language English (U.S.), SKU `com.reolens.Reolens`.

If your account only lets you pick one platform at creation, create iOS, then
the macOS platform attaches automatically on the first `mac-testflight` upload
with the matching bundle id.

### 3. Signing certs / secrets

macOS App Store needs **two** identities:

| Cert | GitHub secret | Signs |
|---|---|---|
| **Apple Distribution** (the unified cert iOS uses) | `IOS_DIST_CERT_P12_BASE64` / `IOS_DIST_CERT_PASSWORD` | the `.app` |
| **3rd Party Mac Developer Installer** | `MAC_INSTALLER_CERT_P12_BASE64` / `MAC_INSTALLER_CERT_PASSWORD` | the `.pkg` installer |

Export each from Keychain Access as a `.p12`, then `base64 < cert.p12` into the
secret. The Apple Distribution cert is reused from the iOS lane; only the
installer cert is macOS-specific.

Plus the shared secrets the iOS lane already uses: `AC_API_KEY_ID`,
`AC_API_ISSUER_ID`, `AC_API_KEY_P8_BASE64` (Admin role), `KEYCHAIN_PASSWORD`,
and the `TEAM_ID` repo variable.

## First upload (local, from your Mac)

Validate signing on your own machine before relying on CI:

```sh
export AC_API_KEY_ID="<key ID>"
export AC_API_ISSUER_ID="<issuer ID>"
export AC_API_KEY_P8_BASE64="$(base64 < /path/to/AuthKey_<ID>.p8)"
# Needs both "Apple Distribution" and "3rd Party Mac Developer Installer"
# identities in your login keychain.
./Scripts/build-mac.sh upload      # or `archive` to stop before upload
```

`archive` leaves `build-mac/ReolensMac.xcarchive` for Xcode Organizer.

## Subsequent uploads (CI, tag-driven)

```sh
git tag v0.8.1 && git push origin v0.8.1
```

fires `release.yml` → `mac-testflight` + `ios-testflight` run in parallel and
upload to the one record; `github-release` then publishes the GitHub Release.
The job stamps `CURRENT_PROJECT_VERSION` with `${{ github.run_number }}`, and
`ReolensMac`'s `CFBundleVersion` is `$(CURRENT_PROJECT_VERSION)`, so each upload
gets a unique, increasing build number automatically.

Bump `MARKETING_VERSION` for a user-facing version change — see
[`RELEASE.md`](RELEASE.md) for the version-bump checklist `check-versions.sh`
enforces.

## Hub carve-out

The macOS App Store build ships the Reolens Hub **engine** (publishes motion
events while the app runs) but **not** the headless `SMAppService.agent`
LaunchAgent — a login agent that relaunches the binary isn't App Store
compatible. Users pair "Run as Hub" with "Launch at login" for near-always-on.
See AGENTS.md §1 and `App/Hub/HubController.swift`.

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| iOS: *"doesn't include the aps-environment entitlement"* | Push not enabled on the `com.reolens.Reolens` App ID. Enable it, delete the stale `Reolens iOS App Store…` profiles, re-run. (Setup §1.) |
| `.pkg` signing fails / *"no identity for 3rd Party Mac Developer Installer"* | `MAC_INSTALLER_CERT_*` secret missing or wrong. (Setup §3.) |
| `The bundle version must be higher than the previously uploaded build` | Build number didn't increment — CI uses `${{ github.run_number }}`; for local uploads bump manually or push a tag. |
| `No profiles for 'com.reolens.Reolens' were found` | Bundle id not registered, or the ASC API key lacks Admin. (Setup §1.) |
| macOS build invalid: includes Sparkle / `disable-library-validation` | The App Store target must not embed Sparkle — that's `build-app.sh` (local DMG-less dev only), not `build-mac.sh`. |

## Where things live

- macOS app target spec: [`AppiOS/project.yml`](../AppiOS/project.yml) (`ReolensMac`)
- App Store entitlements: [`App/Reolens.appstore.entitlements`](../App/Reolens.appstore.entitlements)
- Build & upload: [`Scripts/build-mac.sh`](../Scripts/build-mac.sh)
- Profile helper: [`Scripts/asc_ensure_profile.py`](../Scripts/asc_ensure_profile.py) (`MAC_APP_STORE`)
- CI: [`.github/workflows/release.yml`](../.github/workflows/release.yml) (`mac-testflight`)
- iOS counterpart: [`IOS_RELEASE.md`](IOS_RELEASE.md)
