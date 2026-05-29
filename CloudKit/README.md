# CloudKit schema (`iCloud.com.reolens.Reolens`)

Reolens stores its cross-device data in the user's **private** CloudKit
database — there is no Reolens server (AGENTS.md §5). CloudKit keeps two
schemas per container: **Development** (auto-creates record types/fields
on first write) and **Production** (locked; must be promoted explicitly).
TestFlight, App Store, and Developer-ID DMG builds all hit Production, so
a release that uses a new record type silently no-ops on every prod
device until the schema is promoted.

`Scripts/deploy-cloudkit-schema.sh` wraps `xcrun cktool` for a
reproducible `export → push → promote` flow. The source-of-truth snapshot
is **`CloudKit/schema.ckdb`** (this directory).

## Why `schema.ckdb` is generated, not hand-written

The `.ckdb` is produced by `cktool export-schema` from a Development
container that already has the types. It is **not** hand-authored,
because:

- CloudKit generates the per-type **system fields** (`___createTime`,
  `___recordID`, etc.) and their exact representation.
- **Encrypted** fields (see `CameraCredential.password`) have a
  CloudKit-managed on-the-wire representation; getting it wrong by hand
  risks creating a **plaintext** column — a security regression. Let
  CloudKit define it, then snapshot it.

So the committed snapshot lands the first time a maintainer runs
`export` against a Dev container seeded with all the types below.

## Record types (authoritative spec)

### `MotionEvent` — motion-relay notifications
| Field | Type | Notes |
|---|---|---|
| `cameraID` | String | hub UUID |
| `channel` | Int64 | |
| `detection` | String | e.g. `people`, `motion`, `vehicle`, `<tag>.burst`, `test` |
| `timestamp` | Date/Time | |
| `snapshot` | Asset | trigger frame (optional) |
| `cameraName` | String | optional (0.6.9) |

### `HubStatus` — Hub-offline heartbeat (0.7.0)
Record name = the Hub's stable `hubDeviceID`. Code:
[`Sources/AppShared/HubStatusRelay.swift`](../Sources/AppShared/HubStatusRelay.swift).
| Field | Type | Notes |
|---|---|---|
| `hubDeviceID` | String | |
| `hubDeviceName` | String | e.g. "Mac mini" |
| `lastSeen` | Date/Time | display only; staleness uses the server mod-time |
| `appVersion` | String | optional |
| `relayPublisherEnabled` | Int64 | 0/1 |

- **Index:** `recordName` → **Queryable** (the receiver fetches all
  records via a true-predicate query).

### `CameraCredential` — Apple TV credential sync (0.7.0)
Record name = `cred-<cameraUUID>`. Code:
[`Sources/AppShared/CameraCredential.swift`](../Sources/AppShared/CameraCredential.swift).
| Field | Type | Notes |
|---|---|---|
| `cameraID` | String | plaintext UUID |
| `password` | String — **ENCRYPTED** ⚠️ | written via `record.encryptedValues`; must be an encrypted field |

- **Index:** `recordName` → **Queryable** (the tvOS reader fetches all
  records via a true-predicate query).
- ⚠️ A field's **encrypted attribute is fixed at creation** — it can't be
  flipped later. `password` must be encrypted the first time the field
  exists.

## Materialize + promote the snapshot

```bash
# 0. One-time auth (paste a token from https://icloud.developer.apple.com/dashboard)
xcrun cktool save-token --type management
export CKTOOL_TEAM_ID=5M9UT7VQ8Q
export CKTOOL_CONTAINER=iCloud.com.reolens.Reolens

# 1. Seed Development with the new types, the safe way:
#    EITHER define them in the CloudKit Console (Development env) — create
#    HubStatus + CameraCredential per the spec above, tick "Encrypt" on
#    CameraCredential.password, add the recordName Queryable indexes —
#    OR run a Debug build signed into iCloud and toggle "Run as Hub" and
#    "Stream on Apple TV" so the app writes one of each (the encryptedValues
#    write auto-creates `password` as encrypted). Either way, add the
#    recordName Queryable index in the Console (auto-create won't).

# 2. Snapshot Dev → commit the source of truth:
Scripts/deploy-cloudkit-schema.sh export
git add CloudKit/schema.ckdb && git commit -m 'chore: snapshot CloudKit schema (HubStatus + CameraCredential)'

# 3. Promote Development → Production:
Scripts/deploy-cloudkit-schema.sh promote
```

Thereafter, additive changes are: edit `CloudKit/schema.ckdb`,
`Scripts/deploy-cloudkit-schema.sh push` (→ Dev), then `promote` (→ Prod).
`Scripts/deploy-cloudkit-schema.sh diff` shows drift between the live Dev
schema and the committed file.

## Verify

- CloudKit Console → **Production**: all three types present;
  `CameraCredential.password` shows the encrypted indicator; `HubStatus`
  and `CameraCredential` each have a Queryable `recordName` index.
- On a release-signed build: the "Hub offline" banner resolves (not
  stuck), and the Apple TV streams. A missing Production type shows up as
  a red row in the in-app relay diagnostics (same signal as the
  documented `MotionEvent` "Did not find record type" case).
