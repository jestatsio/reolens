# Release runbook

How to ship a new version of Reolens. As of 0.8.0 Reolens ships **only
through the App Store / TestFlight**, for iPhone, iPad, and Mac, under one
multiplatform App Store Connect record (bundle id `com.reolens.Reolens`). The
old macOS Developer-ID DMG + Sparkle + Homebrew path is retired — see git
history before 0.8.0 if you need it.

Total time once set up: ~5 minutes of human attention + ~10 minutes of CI.

## One-time setup

The per-platform App Store Connect / Developer-portal setup (App IDs,
capabilities, certs, the app record) lives in the platform runbooks — do these
once:

- **iOS / iPadOS:** [`IOS_RELEASE.md`](IOS_RELEASE.md)
- **macOS:** [`MAC_RELEASE.md`](MAC_RELEASE.md)

GitHub secrets the release workflow needs (all already configured):

| Secret / var | Used for |
|---|---|
| `AC_API_KEY_ID`, `AC_API_ISSUER_ID`, `AC_API_KEY_P8_BASE64` | App Store Connect API key (**Admin** role — creates/refreshes profiles + uploads) |
| `IOS_DIST_CERT_P12_BASE64`, `IOS_DIST_CERT_PASSWORD` | Apple Distribution cert — signs the iOS `.ipa` **and** the macOS `.app` |
| `MAC_INSTALLER_CERT_P12_BASE64`, `MAC_INSTALLER_CERT_PASSWORD` | 3rd Party Mac Developer Installer cert — signs the macOS `.pkg` |
| `KEYCHAIN_PASSWORD` | temporary CI keychain |
| `vars.TEAM_ID` | Apple Developer team id (`5M9UT7VQ8Q`) |

The landing page at `reolens.io` is GitHub Pages from `/docs` (DNS: apex `A`
records to GitHub's `185.199.108–111.153`, `CNAME www → erichare.github.io`;
repo Settings → Pages → `main` `/docs`, custom domain `reolens.io`).

## Per-release checklist

### 1. Pre-flight

- [ ] **Tests green on `main`** — [CI badge](https://github.com/jestatsio/reolens/actions/workflows/ci.yml). Local sanity:
  ```sh
  swift test
  bash Scripts/check-versions.sh   # macOS + iOS marketing versions match (AGENTS.md §13)
  bash Scripts/coverage-gate.sh    # baselines in Scripts/coverage-baselines.txt (AGENTS.md §12)
  ```
- [ ] **Smoke-launch the local Mac build** (ad-hoc, no signing):
  ```sh
  ./Scripts/build-app.sh && ./Reolens.app/Contents/MacOS/Reolens --smoke-test
  ```

### 2. Bump the version

`MARKETING_VERSION` must match across every target — `check-versions.sh` blocks
the release if they diverge (AGENTS.md §13). Edit, regenerate, verify:

- [ ] `App/Info.plist` → `CFBundleShortVersionString` (the reference) and
  `App/Widgets/Info.plist`.
- [ ] `AppiOS/project.yml` → every `MARKETING_VERSION` (iOS, Widgets,
  Notification Service, tvOS, `ReolensMac`) **and** the iOS targets'
  `info.properties.CFBundleShortVersionString`.
- [ ] `AppiOS/ci_scripts/add_watch_target.rb` → `MARKETING_VERSION`; and
  `AppiOS/Watch/Info.plist` → `CFBundleShortVersionString`.
- [ ] Regenerate the committed iOS plists: `cd AppiOS && xcodegen generate`.
- [ ] `bash Scripts/check-versions.sh` → green.
- [ ] **CHANGELOG.md** — add the new version section + the compare-link at the
  bottom.
- [ ] Commit as `chore(release): bump to X.Y.Z` (via PR — `main` is protected).

> Build numbers (`CFBundleVersion`) are **not** hand-bumped — every target's
> `CFBundleVersion` is `$(CURRENT_PROJECT_VERSION)`, and CI stamps that with
> `${{ github.run_number }}` so each upload is unique and increasing.

### 3. Cut the release

```sh
git checkout main && git pull
git tag vX.Y.Z && git push origin vX.Y.Z
```

The tag fires [`.github/workflows/release.yml`](../.github/workflows/release.yml),
three jobs:

1. **`mac-testflight`** — archives `ReolensMac`, exports a signed `.pkg`,
   uploads via `xcrun altool --type macos`.
2. **`ios-testflight`** — archives `ReolensiOS`, exports a signed `.ipa`,
   uploads to TestFlight.
3. **`github-release`** — after both succeed, publishes the GitHub Release for
   the tag (notes only; no binaries — the apps live on the App Store).

### 4. Post-release

- [ ] Both builds process on App Store Connect (~10–30 min), then appear in
  **TestFlight** under the one app (iOS + macOS sections).
- [ ] Invite testers if needed (internal = instant; external = one-time Beta
  App Review on the first build).
- [ ] When ready for the public App Store, submit the build for review from the
  App Store tab (separate from TestFlight).
- [ ] Confirm the GitHub Release for `vX.Y.Z` published.

## Rolling back

There's no DMG/appcast to yank anymore — rollback is App-Store-shaped:

- **On TestFlight:** expire the bad build (TestFlight → the build → Expire) so
  testers stop getting it; the previous build stays installable.
- **On the App Store:** you can't un-publish an approved version, and Apple
  won't let users downgrade. Ship a higher version with the fix — cut a
  `vX.Y.Z+1` patch through the normal flow. That's almost always the right
  call.
- The bad **GitHub Release** can be deleted in the GitHub UI if you want it off
  the releases page.

## Where things live

- Version bump targets: [`AppiOS/project.yml`](../AppiOS/project.yml), `App/Info.plist`
- Version gate: [`Scripts/check-versions.sh`](../Scripts/check-versions.sh)
- CI: [`.github/workflows/release.yml`](../.github/workflows/release.yml)
- Platform setup: [`IOS_RELEASE.md`](IOS_RELEASE.md), [`MAC_RELEASE.md`](MAC_RELEASE.md)

---

*Historical per-version manual-QA checklists (0.5.0–0.6.3) were retired from
this runbook in 0.8.0; find them in git history if needed.*
