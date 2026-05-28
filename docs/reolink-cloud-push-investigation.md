# Investigation — Reolink-native push as an opt-in notification fallback

**Status:** Research spike (0.7.0). No code shipped. Recommendation below.

## Question

The 0.7.0 "Reolens Hub" makes one always-on Mac the listener that turns
Reolink camera events into notifications (camera → Baichuan → Mac →
CloudKit → APNs). That works without any Reolens server and without
Reolink's cloud, but it requires a Mac that's always on.

Could we offer an **opt-in fallback** for users who have *no* always-on
Mac — ideally one that still honors the two hard constraints in
`AGENTS.md` §5: **no Reolens server**, and **no dependence on Reolink's
cloud**?

## What Reolink cameras can emit natively

Surveyed against current Reolink firmware (NVR / Home Hub / standalone
cameras). All require **verification on real hardware** — capabilities
vary by model and firmware, and Reolink does not publish a stable
third-party push API.

| Mechanism | What it is | Reaches an iPhone how | Avoids a server? | Avoids Reolink cloud? |
|---|---|---|---|---|
| **Reolink push** | Camera → Reolink's cloud → the **Reolink app** | Only the Reolink app | n/a (it *is* their cloud) | ❌ no |
| **Email (SMTP) on event** | Camera emails a snapshot/clip | Mail app push, not Reolens | needs an SMTP inbox + a poller to bridge into Reolens | ✅ |
| **FTP/SFTP upload on event** | Camera uploads media to a server | nothing, until something watches the FTP dir | ❌ needs an FTP server + watcher | ✅ |
| **ONVIF event subscription** | Pull-point / base notification over ONVIF | nothing, until a subscriber listens | ❌ needs an always-on subscriber (same shape as the Hub) | ✅ |
| **Webhook / HTTP push** | Camera POSTs to a URL on event (model-dependent, often absent) | nothing, until an endpoint receives it | ❌ needs an HTTP endpoint | ✅ |

## Findings

1. **There is no public Reolink push API for third-party apps.** Reolink
   push is bound to the Reolink app via Reolink's own cloud. Using it
   would mean depending on Reolink's cloud (rejected) and, realistically,
   asking users to run the Reolink app alongside Reolens — which defeats
   the point.

2. **Every camera-native path that avoids Reolink's cloud (email, FTP,
   ONVIF, webhook) still needs an always-on *receiver*** to turn the
   camera's emission into an APNs push. That receiver is exactly the role
   the Hub Mac plays today. Moving it off the Mac means either:
   - a **Reolens-operated server** (violates §5), or
   - a **user-operated box** (NAS / Raspberry Pi / router add-on) running
     a small bridge — which is just "the Hub, on non-Apple hardware," and
     can't reach CloudKit without server-to-server keys (another server).

3. **The honest conclusion is unchanged:** *something on the LAN must be
   always on to observe the camera.* The constraints don't permit a
   fallback that needs neither an always-on device nor a server/cloud.

## Recommendation

- **Keep the Hub Mac as the answer.** It is the only path that satisfies
  both constraints, and 0.7.0 already makes it invisible/automatic.
- **Do not integrate Reolink's cloud push.** It breaks the independence
  principle and the UX (two apps).
- **If a no-Mac fallback is ever demanded**, the least-bad option that
  preserves "no Reolens server" is a **documented, user-operated bridge**
  (e.g. a tiny container on a NAS the user already runs) that subscribes
  to the camera's ONVIF events and posts to the user's own CloudKit via
  CloudKit Web Services. This is a *power-user, bring-your-own-box*
  story, not a default — and it still requires the user to operate
  always-on hardware, so it offers little over running Reolens on a Mac
  mini. **Recommend deferring** unless real user demand appears.

## Verification still needed

- Confirm on current firmware which models expose ONVIF pull-point
  events and/or generic webhooks (vs. email/FTP only).
- Confirm whether CloudKit Web Services server-to-server keys can be
  scoped to a single user's private DB safely (they cannot be shipped in
  the app; they'd live on the user's own box).
