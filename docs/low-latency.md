# Playback architecture and troubleshooting

Current guidance for local live playback on Apple TV and iPhone/iPad.
Earlier experiments remain in Git history; they are not alternate shipping modes.
For setup, UI conventions and releases, start with [AGENTS.md](../AGENTS.md).

## How playback is wired

`PlaybackService` resolves Twitch access tokens, the signed master and selectable
qualities. Local Twitch video uses `NativeLowLatencyHLS`, an AVAssetResourceLoader
bridge backed by an app-owned, loopback-only media server and Apple's decoder.
It does not require a desktop service, certificate or re-encoding.

For multi-rendition Auto, `NativeHLSOrigin` delegates to
`NativeControlledHLSOrigin`. The controller ingests H.264/AAC TS or source-CMAF,
builds one movie initialization containing every video sample description and
stable audio, and switches descriptions at independent segment/keyframe
boundaries. AVPlayer sees one virtual rendition; the controller retains and
selects among the original video qualities. One playlist entry is therefore not
evidence that Auto has been pinned to one source quality.

Controlled Auto is the default in normal and Release builds. Debug can set
`STROZZ_NATIVE_CONTROLLED_AUTO=0` for comparison; Release ignores that opt-out.
Manual/single-rendition native video, previews, Audio Only, VOD, receivers and
YouTube have distinct paths. Preview explicitly opts out of controlled Auto.
The older `LowLatencyHLSProxy` is not the local Twitch Auto architecture; do not
revive its removed Auto profiles or use it as an automatic failure fallback.

| Responsibility | Start here |
| --- | --- |
| Signed sources and selectable qualities | [`PlaybackService.swift`](../Strozz/Services/PlaybackService.swift) |
| Native bridge, preparation and non-controlled indexing | [`NativeLowLatencyHLS.swift`](../Strozz/Services/NativeLowLatencyHLS.swift) |
| Controlled production, probing, periods and rewind resources | [`NativeControlledHLSOrigin.swift`](../Strozz/Services/NativeControlledHLSOrigin.swift) |
| Capacity and rendition/budget decisions | [`NativeAdaptiveRenditionPolicy.swift`](../Strozz/Services/NativeAdaptiveRenditionPolicy.swift) |
| TS framing and remuxing | `NativeTransportDemuxer.swift`, `NativeTransportRemuxer.swift`, `NativeTransportStream.swift` in `Strozz/Services/` |
| CMAF parsing, fragment rewriting and clocks | `NativeCMAF.swift`, `NativeCMAFRemuxer.swift`, `NativeFragmentedMP4.swift`, `NativeMediaClock.swift` in `Strozz/Services/` |
| Bounded ingress and loopback delivery | `NativeHLSChunkReader.swift`, `NativeHLSMediaServer.swift` in `Strozz/Services/` |
| TV player lifecycle and diagnostics | [`PlayerModel.swift`](../Strozz/Views/Player/PlayerModel.swift), `Strozz/Views/PlayerView+Loading.swift`, `+NativeCatchUp.swift`, `+Diagnostics.swift`, `+Telemetry.swift` |
| Mobile lifecycle, PiP and video ownership | [`MobilePlaybackModel.swift`](../StrozzMobile/MobilePlaybackModel.swift), [`MobilePlaybackSession.swift`](../StrozzMobile/MobilePlaybackSession.swift), [`MobilePlayerView.swift`](../StrozzMobile/MobilePlayerView.swift) |
| Grid/expanded/spotlight budgets and pane ownership | [`MultiviewController.swift`](../Strozz/Views/Multiview/MultiviewController.swift) |
| Recovery, drift and chat timing policies | `NativePlaybackRecovery.swift`, `NativeLiveCatchUp.swift`, `LiveChatSyncBaseline.swift` in `Strozz/Services/` |
| Retained evidence and analysis | `PlaybackTelemetry.swift`, `PlaybackTelemetryWriter.swift` in `Strozz/Services/`; [`playback-diagnostics.py`](../tools/playback-diagnostics.py) |

### Kick and cross-platform viewing

`KickPlaybackService` resolves a public Kick channel document and its signed IVS
HLS master using ordinary HTTPS requests. It distinguishes actual offline state
(`livestream: null`) from missing channels, malformed responses, and access
restrictions. Signed playback URLs are not saved in the recent-channel model.
Playback has no hidden browser, challenge bypass, or additional player SDK.
Public discovery uses `/api/v1/channels/{slug}` for live artwork because the v2
document may return `thumbnail: null`. Playback and previews still resolve their
signed media through v2; artwork lookup does not sit on the playback path.

Discovery shares the existing Following, recommendation, search and multiview
surfaces. `KickFollowingStore` owns a complete real-account follow snapshot;
`KickDiscoveryService` independently refreshes public channel status and merges
only creator identities confirmed by saved links, curated aliases or
`CreatorSourceResolver`. Curated aliases are bundled on both platforms, including
confirmed same-name pairs, and are not lost when a downloaded table omits them.
Known links merge immediately without waiting for background profile discovery.
Equal names alone remain separate provider-qualified identities. Recommendation
candidates are linked creators from existing pools, not a global Kick directory.
The multiview pane's playback target includes the provider and actual Kick slug;
metadata synchronization must retain its pane ID and existing `PlayerModel`.
Both TV focus previews and mobile feed previews resolve Kick media as Kick, never
as a same-named Twitch stream.

Mobile setup is a visible Kick login website in an isolated persistent WebKit
profile. Same-origin reads import `/api/v1/user` and every page of
`/api/v2/channels/followed`, then verify the account again. Failed, malformed,
incomplete or account-switched reads cannot replace the last saved roster.
Terminal pages may omit `nextCursor` or set it to `null`; the `channels` array
remains required, and malformed cursors, repeated cursors, and failed later pages
must still reject the import rather than save a partial roster.
This undocumented endpoint has no stability guarantee. There is no client
secret, cookie-paste workflow, session relay or bot-challenge bypass.
Sign-in preparation is time-bounded; reloading an already-prepared website
retries navigation without restarting account synchronization or clearing cookies.

Only account identity and public follow metadata enter the encrypted
`KickFollowing.payload` record in the private `StrozzAccounts` CloudKit zone.
Website sessions stay on the importing mobile device. Conditional writes and
connection-scoped importer bindings fence stale writes and disconnect tombstones.
Apple-account changes invalidate local state; a website profile from another
owner is cleared before reuse. Deploy the versioned schema before distributing
this feature.

Imports refresh at most every five minutes while the importing mobile app is
foreground and not playing, or through an explicit sync. Failure attempts also
observe this interval. Website content is unloaded after import/dismissal;
opening Strozz without a Kick connection must not create a browser/player for
Kick. Public live status refresh is separate, bounded to four requests in flight, with followed
channels published before slower identity discovery. Identity lookups also have
four-request concurrency and bounded retry intervals. Same-name followed accounts
are prioritized for identity verification, never accepted on name alone. New
imports restart discovery promptly on both platforms. TV discovery runs outside
the Home startup chain so it cannot delay Twitch recommendations or initial focus.
After the initial/account refresh, TV status polling respects Home's idle gate
rather than reordering rails under active navigation. Discovery loops pause during
playback; imports are not continuous TV-side OAuth follow synchronization.

Kick has no separate player UI or playback model. TV uses `PlayerView` and
`PlayerModel`; mobile uses `MobilePlayerView`, `MobilePlaybackModel`, and the
existing `MobilePlaybackSession` video/PiP owner. `LiveStreamSource` supplies typed
provider identity and validation. Source changes use these existing models,
retain their mounted AVPlayer, resolve fresh playback, and fence late results
by the normal load/session generations. Native recovery, buffering, catch-up,
rewind, chat rendering/settings, diagnostics, gestures, and layout remain owned
by the same player code as Twitch. Mobile mini-player/PiP ownership is not
replaced during a source change.

Keep provider identity separate from a channel handle. A Kick-only channel must
not open Twitch IRC, request Twitch metadata/profiles/VODs, earn Twitch rewards,
send Twitch chat, or enter Twitch recommendation history under the same text
handle. Kick's read-only status uses the existing chat UI; unavailable
provider-specific capabilities must not justify a different player interface.

`CreatorLiveSession` owns one `ChatService`, Hermes listener, linked-account
graph, and live viewer snapshots for the creator on both platforms. The selected
video is a separate `PlatformLiveTarget`. A known-peer video switch must not
change the creator generation, restart chat workers, clear message history,
discard a draft/reading position, or reset counts. Changing creator or explicitly
editing the identity graph rotates the generation and fences old async work.
Suspension prevents late discovery from reconnecting transports.

Automatic identity discovery uses curated aliases and explicit public social
links. A same-name Twitch account for a Kick creator is only a candidate and
needs a reciprocal Kick link or matching explicit YouTube identity; ambiguous
reverse mappings are rejected. Native **Linked creator channels** settings
provide explicit, validated, device-local persisted links when discovery cannot
prove the association. Never fall back to guessed handles for merged chat.
Twitch sending uses the linked Twitch account even when video is Kick/YouTube;
earning watch rewards and Twitch VOD lookup still require actual Twitch video.

Viewer snapshots refresh separately from chat preferences and video metadata:
Twitch/Kick every 30 seconds, YouTube no more than every 90 seconds. Authoritative
offline hides a count; unknown results preserve only a bounded last-known value
(90 seconds for Twitch/Kick, 120 seconds for YouTube). YouTube's count must come
from a current-live watch page, never total views. Existing extra-delay chat sync
still applies when enabled, but received YouTube batches enter the common ingest
pipeline immediately rather than trickling across another poll interval.
`CreatorLiveSessionTests` covers video-switch continuity, explicit identity,
persistence/reverse entry, independent counts, expiry, and stop/suspend fences.

Twitch broadcast endings use the existing anonymous Hermes
`video-playback-by-id` subscription: `stream-down` confirms an ending and
`stream-up` confirms a new broadcast. Viewer-count updates and disconnected
sockets are not offline evidence. Periodic creator status checks continue after
terminal playback errors, and resubscribing requests a fresh check. Push events
take precedence for ten seconds so briefly stale metadata cannot immediately
undo them; subsequent checks still cover missed events. Old connection frames,
out-of-order event timestamps, and queries begun before a newer event are fenced.

TV and mobile apply this evidence only to the matching Twitch video source,
never a linked Kick/YouTube video or its merged chat. Healthy buffered video and
paused/rewound playback remain available. The offline state replaces an
unplayable item, the drained live edge (at most 150 ms buffered), or a confirmed
play-to-end notification, subject to playback intent; TV raid handling retains
precedence. Pending source recovery is invalidated before presenting offline.
`broadcast_status_updated` records the evidence separately from transport and
decoder failures. This does not change retry limits or provide automatic fallback
to the standard player.

Kick chat negotiates its current anonymous Pusher application through Kick's
public realtime connection endpoint. Do not bake in an application key:
retired keys return Pusher error 4001 even when video and channel lookup work.
Socket errors reconnect with backoff and negotiate again; they do not retry an
obsolete hardcoded key forever or interrupt video.

IVS `#EXT-X-PREFETCH` and `#EXT-X-PREFETCH-DISCONTINUITY` preserve real source
sequences, timestamps, and periods. Auto retains all advertised video qualities.
Explicit Kick qualities use controlled TS-to-CMAF remuxing pinned by stable
variant identity, not passthrough TS or a bitrate ceiling. IVS can rotate **all**
variant URLs on consecutive requests for the same master: match stable ID or
resolution/frame-rate attributes against the fresh master, never URL equality.
Filter to the explicit rendition before metadata/bootstrap work; do not make a
fixed quality wait for unselected renditions.

The opt-in `KickSharedPlayerLiveTests` exercise these actual existing player
models, including standalone Kick, explicit qualities, and Twitch/Kick switches.
They compare actual decoded video/PDT delay with a
plain AVPlayer HLS baseline over 90 seconds. Set
`TEST_RUNNER_STROZZ_KICK_LIVE_TESTS=1` when invoking `tools/xcbuild.sh test`;
`TEST_RUNNER_STROZZ_KICK_CHANNEL` defaults to `xqc`. A separate handoff test needs
`TEST_RUNNER_STROZZ_KICK_SWITCH_TWITCH_CHANNEL` naming a currently live Twitch
channel. They check fixed quality, restored Auto, decoded Twitch/Kick transitions,
and renderer identity. Existing audio/background/PiP regression suites continue
to cover the same owners used by Kick. XCTest retains
numeric latency evidence. Simulator PDT delay is not hardware glass-to-glass
latency, a universal latency guarantee, or a comparison with the official IVS
iOS SDK. Provider availability and stream formats can change.

## Invariants that fixes must preserve

- **Auto is genuinely adaptive.** Do not pin Source, remove supported qualities,
  increase normal buffering or switch to standard/high-latency playback and call
  the result an Auto fix. A selected manual quality or explicit decode-recovery
  override is not evidence that Auto works.
- **Measure upstream capacity, not the renderer or localhost.** Decisions use
  completed upstream payload-transfer metrics, excluding request latency,
  cache hits, actor scheduling and encoder-paced prefetch wait. Capacity probes
  are bounded; sharp losses receive a fresh confirmation before downshifting.
  Upgrades require fresh evidence and hysteresis. AVPlayer waiting alone is not
  proof of bandwidth loss. See the policy and producer rather than duplicating
  their thresholds in UI code.
- **Preserve encoded media and real clocks.** PES boundaries are not picture
  boundaries: continuation NALs/slices can cross them. CMAF track IDs and
  timescales are discovered, not assumed to match TS. Unwrap TS's 33-bit clock
  and recover common A/V phase across CMAF's per-timescale version-zero wraps;
  keep rewind timestamps positive and periods separate. GOP decode-origin
  changes require inverse signed composition-offset changes so presentation
  times and compressed picture payloads remain unchanged.
  When converting TS or remapping source-CMAF clocks, remove only HRD buffering-period/picture-timing SEI
  messages (types 0/1), not entire SEI NALs. Their transport clock model can
  freeze Apple's decoder after a rendition change even when FFmpeg decodes the
  same picture bytes. Preserve caption/user/other SEI and VCL bytes; see
  `NativeTransportDemuxer.removingTransportTimingSEI` and its regressions.
  Adaptive decode checks must feed `updateControlledPlayback` and inspect actual
  CVPixelBuffer dimensions; AVPlayer preferences alone do not drive this engine.
- **Keep PES assembly linear.** Remove a pending PES from its dictionary before
  appending the next transport packet, then restore it if incomplete. Retaining
  the dictionary's copy makes each small append copy the accumulated payload,
  including expensive virtual-memory copies for large keyframes. Preserve
  independent state when a demuxer is copied, and keep A/V payloads and clocks
  unchanged.
- **Respect format and part contracts.** Source-CMAF requires muxed AVC/AAC-LC,
  compatible track IDs/timebases and audio configuration within a period, and no
  edit lists. Unsupported media fails explicitly, not by silently hiding a
  quality. Compatible initialization-URL rotations are not new periods.
  CMAF `skip` boxes designate unused space, just like `free` boxes; accept them
  before, between and after complete `moof`/`mdat` pairs without changing media
  or clocks. Keep size/truncation checks; `skip` between `moof` and `mdat` remains
  unsupported because discarding it would invalidate the source sample offsets.
  Nonterminal parts must meet the 85% minimum of the 450-ms target (382.5 ms);
  cutting at 380 ms has produced invalid 50-fps playlists.
  Upstream CMAF fragment boundaries are not necessarily valid part boundaries:
  variable 100/133-ms fragments can strand a 366-ms group. Split normalized
  video/audio runs at encoded-sample boundaries when needed, preserving sample
  bytes, flags, descriptions and presentation clocks rather than widening the
  target or rejecting a supported rendition. Bound each media entry to ten seconds.
  Accumulate and split part durations in integer video-clock ticks, rounding the
  maximum down and the minimum up. Floating-point sums can put a legal
  133 + 150 + 167-ms group above 450 ms and incorrectly attempt an impossible
  sample split. Genuine unsplittable cuts report `partial_sample_boundary`
  with numeric tick, timescale and sample-count evidence, never media or URLs.
- **Keep normal latency policy.** Incremental-prefetch sources target 1.5-second
  hold-back and a three-second preferred forward buffer. Completed-only sources
  use cadence-aware timing; do not force the incremental constants onto them.
  Initial live alignment is separate from steady playback. Healthy drift uses
  bounded, held rate correction, not repeated seeks or item replacements.
  Missing/inconsistent date samples must not invent latency or trigger catch-up.
- **Keep publication caching coherent.** Controlled playback retains one encoded
  playlist per unchanged publication and constant-time byte/completed-duration
  totals. Parts, completion, eviction, end-of-stream and hold-back changes
  invalidate it; blocked reloads still wait for the requested part. Cache PDT
  text per segment and reuse actor-confined/per-parse date formatters without
  changing timestamp precision, rewind retention or withheld-part semantics.
- **Keep recovery bounded and Native-only.** `NativePlaybackRecovery` shares two
  fresh-source/engine attempts per rolling minute across origin, startup and
  stall failures. Unsupported formats and exhausted attempts show an error and
  Retry. A refilled-buffer same-item resume is one bounded attempt, not proof of
  recovery. An unrequested `paused` state also needs bounded recovery: player
  rate zero is not viewer intent. Preserve real pause, interruption, background,
  seek and system PiP/AirPlay control ownership. Output disconnection is an
  intentional privacy pause, including during pending loads; expanded-pane sleep
  also owns the hidden panes' pauses. Recheck item/player/generation ownership
  after asynchronous work.
  TV foreground source resolution must also use this shared retry budget for
  transient transport loss/timeouts, with a short cancellable delay and at most
  two retries per refresh. Do not retry authentication, offline, certificate or
  cancellation errors. Fence every attempt/result against channel, session,
  generation, background and source changes. `native_hls_resume_retry`,
  `native_hls_resume_resolved` and `native_hls_resume_failed` distinguish attempts
  and elapsed resolution time without retaining requests or credentials.
  Remote incidents retain a bounded follow-up checkpoint when progress resumes
  or the session closes within two minutes, grouped with the originating issue.
  `diagnostic_kind=recovery` is informational evidence, not a new failure;
  `outcome=session_ended` must not be interpreted as recovered playback.
- **Do not turn background work into a live failure.** Unused-rendition reports
  are optional and must not block active media. Unavailable historical resources
  fail locally rather than killing healthy live production. Keep reader queues,
  segment sizes and encoded caches bounded; the encoded-cache limit is not a
  promise about total transient process memory.
- **Presentation changes are not stream changes.** Grid count changes and
  expand/return retain surviving AVPlayers, items and video surfaces. Mobile
  expanded/mini-player layouts share one mounted video owner; an outgoing
  `MobilePlayerView` captures its own model/controller so teardown cannot detach
  its replacement. Native PiP is a separate background lifecycle. Deliberate
  foreground/error recovery can rebuild the engine/player; TV must also replace
  its AVKit surface then, preserving mute/volume and pause/DVR intent.
  Fully hidden expanded peers do not owe visible decoded frames: the same
  visibility state drives opacity and decoder-watchdog eligibility. Their clock,
  network and engine-error monitoring remains active; missing hidden frames must
  not force a fixed-quality decode recovery.
- **Audio ownership is separate from video health.** One multiview pane is
  audible. See `PlayerView+AudioSession.swift` and `PlaybackAudioSessionTests`
  before changing interruption/reclaim behavior; do not repeatedly fight another
  app for audio. A video continuity pass does not establish audible playback.
- **Chat sync means extra delay.** `LiveChatSyncBaseline` learns the normal live
  cushion; synchronization adds only excess delay, not total encoder/live-edge
  latency. Rewind uses retained chat/replay behavior, not a second live delay.

### Chat text wrapping

Chat text uses width-constrained token measurement on both TV and mobile.
Long URLs and usernames wrap within the available pane instead of extending
beyond its edge. Wrapping changes layout only, not the original message or URL;
ordinary tokens, emotes and the atomic flow layout used by settings retain
their existing behavior.

### Multiview selection and chrome

TV multiview uses one `MultiviewLineup` owned by Home and passed through an optional
environment value. Hold a live channel card in Following, Browse, Search or channel
recommendations to add/remove it; the normal player also has a multiview control.
Search lists channels before categories. The contextual avatar button opens only
lineup management, not another discovery page. It lives inside each page's
scrolling header alongside existing actions, never in a reserved fixed strip.
Its width animates with the selected avatars while its height stays constant;
there is no empty six-slot reservation. Channel hold menus also expose Start or
Return to multiview, using the same launch requirements as the manager. Adding
never starts playback or navigates away. Avatar insertion/removal and button
resizing respect Reduce Motion.

Selection uses provider-qualified channel keys, not pool-specific stream/user
IDs. Status refreshes query the selected channels themselves: absence from a
partial discovery response is not offline evidence. While browsing, an explicitly
offline selection remains visible as Offline for ten seconds, then fades away.
It stops counting toward the limit and launch roster immediately; returning live
during the grace period preserves its selection if capacity has not been reused.
An active player pane does not auto-remove: its offline notice remains, with
native View channel and Remove actions. These controls use the dark video
surface's appearance even in Light theme. Removing the last pane exits multiview.
Channel pages temporarily suspend wall audio without replacing players, then
restore the prior audio owner and mute choice when dismissed.
Back from the wall (or Browse streams in its controls) returns to the same browsing
state. The wall and each surviving player view/model remain mounted, but playback,
native producers and chat are suspended rather than decoding behind browsing.
Return uses native suspension recovery to re-resolve live sources and rebuild
their audio/video renderers while retaining the pane models, layout and audio
owner. New selections join that same controller; no second active queue is
created. Hidden browsing cards cannot run previews behind the wall.

After 2.5 idle seconds and a 0.2-second fade, the focused/audible pane's outside outline dims to 35%
of its active opacity instead of disappearing. The icon-only audio badge and
focused metadata still hide; remote interaction restores full chrome without
changing audio ownership. Both overlays use the shared native Liquid Glass
HUD treatment, with theme-aware opaque surfaces when transparency is disabled.
The outline switches instantly between panes; other chrome animations are unchanged.
Pane frames match the video's presentation aspect ratio rather than a letterboxed
layout cell. Compact videos have 16-point continuous rounded corners; metadata is
clipped to the same shape and the outside outline follows its rounded edge.
Pictures pack together with 10-point gaps, just enough for the
outside outlines, and a 5-point screen-edge allowance. Unused aspect-ratio space
stays around the wall instead of between rows. These bounds stay stable while
chrome hides. Compact players do not ignore safe areas: doing so expands their
native video surfaces toward screen edges independently of the pane outlines.
Expanded playback remains edge-to-edge with the same retained player.
Metadata adapts to the actual pane bounds rather than its quality tier: smaller
panes omit title/game details, and the smallest show only the channel and audio
cue. Chrome cannot enlarge the picture's outside outline or spill into peers.

Featured, Spotlight and Equal are explicit TV layout choices. Featured places
the pinned primary beside a compact secondary grid; Spotlight uses a thumbnail
strip; Equal uses common-height, aspect-correct pictures without a three-stream
primary exception. Choosing Featured or Spotlight promotes the pane focused before
opening the toolbar, or the pane whose hold menu was opened. Later focus/audio
changes do not move the primary; Equal and programmatic restoration preserve it.
Promotion changes geometry, not pane order,
player items or reload identifiers. Existing quality budgets remain unchanged:
Featured and Equal use the grid tiers; Spotlight retains its source/thumbnail tiers.

Play/Pause reveals a compact bottom Liquid Glass toolbar with Layout, Browse streams
(Add stream in the standalone picker flow), and Done. Layout uses a native menu
with an inline single-selection picker, also shared by the pane's hold-menu
submenu. Native menu dismissal handles Back before the toolbar closes.
Only the toolbar reserves wall space; the system menu temporarily overlays content.
Focus is contained in controls while open, preserving audio and the
return pane. Controls never auto-dismiss under focus. Their measured height
drives bottom clearance: leave fitting pictures unchanged, translate into unused
space next, and only then recompute smaller frames with unchanged rows/columns
and outside-outline gaps. Layout and clearance motion respects Reduce Motion;
ordinary pane focus does not resize the wall.
Controls use normal-sized labels and the shared
theme-aware player button styles, including the native Reduce Transparency path.

A short Play/Pause press on a focused browsing stream card toggles its lineup
membership through the existing selection path, including the six-stream limit.
Only live Twitch/Kick cards or an already-selected card enable this command.
The existing selection badge updates without opening a player or menu.

The inline lineup button retains its native height when empty, but has zero
width and no focus or accessibility target, so adding or removing the first/last
stream cannot shift page content. Avatar additions still animate only its width.

`MultiviewCardShortcut` belongs on the browsing card's focusable wrapper;
placing the command inside `StreamChannelCard` leaves it below the focused
responder and drops the remote press.
Holding Play/Pause for 0.7 seconds opens the shared lineup from browsing or a
presented screen; holding it in an expanded pane returns to the wall. The
window-scoped recognizer arbitrates with the normal Play/Pause command, so a
hold must not also pause playback, toggle a browsing card, or toggle the wall HUD.
Short presses inside playback keep their existing behavior. An insufficient lineup shows the existing toast pill
above the current screen for three seconds without dismissing it. Recognizer
and toast ownership follow the Home window and are removed when it detaches.
The lineup marks the entire presentation handoff as busy, including UIKit
dismissal, so Home cannot insert a first-run setup prompt between the old
screen and multiview.

### Multiview ceilings

Normal controlled grids permit up to 1920x1080 with one through four panes and
1280x720 with five or six. Neither tier adds a bitrate ceiling. Fullscreen and
the spotlight primary are unrestricted; secondary/hidden thumbnails retain
854x480 / 800 kbps preferences. These are adaptive ceilings, not guaranteed
minima. Debug's controlled opt-out retains the older 720p / 3 Mbps grid policy.

The defaults came from mounted physical-TV workloads, not simulator decoder
claims: four 1080p60 and six 720p60 streams sustained the tested observation
window; six unrestricted 1080p60 encountered buffering. That is workload
evidence, not an absolute Apple TV decoder specification or a CDN guarantee.

## Diagnose before changing behavior

First identify UTC time, installed build, channel, selected quality/profile,
incoming format, pane count, expanded/spotlight state, budget and audio owner.
The newest log can belong to another pane or an earlier launch. Pulling evidence
is read-only; restarting playback or taking over hardware is not.

### Collect scoped evidence

TV retains JSONL under `Library/Caches/PlaybackDiagnostics`, excluded
from backup. tvOS does not guarantee persistent local file storage; moving these
files to Application Support would not make them durable. The verbose log budget
is **128 MiB** shared across panes (32 parts
of 4 MiB). Active pane files are protected from retention eviction; tracked and
enumerated file URLs must use the same canonical form, including `/var` aliases.
Local storage can still fail or be removed; it is not
a substitute for capturing an incident promptly.

Each failed session also keeps a separate atomic `Incidents/incident-<UUID>.json`
checkpoint: session/build metadata, the first incident and first error, six
preceding non-debug events, latest error/recovery, and latest sampled state.
Routine segment/frame traces cannot rotate this evidence away. Checkpoints
refresh at most every 15 seconds during routine playback and immediately for
failure/recovery/end events, with a separate cap of 32 files × 256 KiB (8 MiB).
Failed writes back off for five seconds while retaining pending evidence in memory.
Active failed sessions are protected; old closed sessions are evicted first.
Oversized records and persistence failures are reported, not silently discarded.
Failures have 16 reserved queue slots beyond normal bounded trace admission.

Use the existing tool rather than copying the full app container. For a stalled
wall, collect the small checkpoints first:

```bash
python3 tools/playback-diagnostics.py pull --device <device-id> --incidents-only --all
python3 tools/playback-diagnostics.py pull --device <device-id> --all
python3 tools/playback-diagnostics.py analyze <capture-directory> --all --json
```

`pull` accepts `--bundle`, `--output` (a new directory), `--session` and `--all`.
Default full-log analysis follows `latest-session.json`; `--all` reports each
session separately, never combines concurrent panes. `failure_evidence` exposes
the pinned checkpoint without mixing sparse historical samples into full-log
statistics. Checkpoint-only analysis explicitly reports sparse evidence.
Mobile uses the same budgets and format under
`Library/Application Support/MobilePlaybackDiagnostics`; pass `--mobile` to pull.
For older mobile builds, use `--mobile --legacy-cache` to read the previous
`Library/Caches` location. TV uses Caches in both versions, so its default pull
also reads older builds. Existing cached evidence is not deleted or
silently treated as current evidence.

Check build/session/time and file completeness before interpreting a capture.
The pull tool lists only diagnostic files and copies checkpoints before individual
log parts, avoiding fragile whole-directory transfers. `capture-manifest.json`
records copied/failed files; a partial transfer exits with an error but leaves
captured evidence available for analysis. A successful command or empty destination
is not proof of a complete transfer. The parser reports corrupt/partial data, sequence
gaps, dropped records and reclaimed rotations; do not discard those warnings.
Logs contain public channel names and viewing times. Keep captures private and
out of commits; never add signed URLs, tokens, headers or chat bodies.

### Read the evidence correctly

- **Confirm the actual path.** Eligible Auto should report
  `native_controlled_auto=true`. Trace `input_format` distinguishes incoming TS
  from CMAF; output `format=cmaf` does not, because TS is remuxed to CMAF too.
  Check selected quality, recovery override and effective budget together.
- **Use actual pixels for quality.** `AVPlayerItem.presentationSize` can remain
  at the movie's first description while decoded resolution changes. Use
  `CVPixelBuffer` dimensions / `decoded_video_*`, with fresh-frame timing.
  Static `presentation_*`, declared bitrate and loopback access-log throughput
  are not decoded-quality or available-network-capacity proof.
- **Separate clock from video.** Clock progress and a healthy buffer can coexist
  with a frozen decoder/render surface. Compare clock, frame timestamp/age,
  decoded dimensions, waiting state and visible output. Reuse the existing frame
  consumer; adding another output/consumer can change the behavior under test.
  A decoded buffer is not by itself proof the screen displayed that frame.
- **Classify before fixing.** Low buffer plus stalled clock points toward
  ingestion/network/timeline starvation; fresh clock without fresh frames
  points toward decode/rendering. Rapid decoded-quality changes require
  correlated rendition decisions and upstream capacity samples, not a guessed
  grid cap or streamer's picture softness. Date/PDT discontinuities can corrupt
  apparent latency without real clock drift.
- **Recovery events are actions, not outcomes.** `recovery_completed` can mean
  only that loading returned. Require subsequent fresh frames and clock
  progress. Zero classified stall episodes does not exclude short hiccups below
  the parser's clock threshold.
- **Distinguish terminal errors from buffering.** Samples with `error_present`
  use phase `failed`, not `waiting`, and emit a bounded error-state transition.
  TV samples record `recovery_blocked_by`, playback intent, watchdog/refresh task
  presence, Native refresh state, current retry-window count/limit and retry delay.
  Task presence does not prove execution. The pinned first failure preserves
  numeric error domains/codes and up to three underlying error domains/codes;
  SDK descriptions, signed URLs, headers, tokens and chat bodies are excluded.
  A retry delay of zero does not itself restart a terminal error.
- **Explain unexpected stops.** `avplayer_rate_changed` records the framework's
  rate-change reason and automatic-wait setting; `avplayer_reached_end` separates
  an end notification from ordinary buffering. Correlate those with viewer intent
  and subsequent `native_unrequested_pause_resume`, not just the final rate zero.
- **Correlate system failures.** Match `mediaplaybackd` reports to build, device,
  session and UTC time. A previously observed track-teardown fingerprint
  (`CFEqual`, `fpfsi_IsTrackAlive`, `fpfs_AbandonSyncAttempt`) did not establish
  the initiating cause. Observer-off and direct-layer controls did not repair
  it; neither is a proven fix. IPS files can contain separate JSON header/body
  documents, so parsing one as a single JSON object can fail.

## Short hiccups: separate delivery from delayed logging

Native events retain `native_event_uptime_seconds` at their producer;
`native_trace_retention_delay_seconds` separates buffered/replayed diagnostics
from `main_actor_delivery_delay_seconds`, the dispatch-to-main wait.
Do not infer a CDN/producer gap from JSONL record timestamps alone.

`playback_scheduler_delay` compares an independent one-second background probe
with its main-queue acknowledgement, with only one callback pending per player.
Large `main_queue_delay_seconds` with a normal
`background_probe_interval_seconds` supports main-thread blockage. If the
background probe is late too, broader scheduling pressure is possible. Probes
are inactive for background/idle playback; absence of a delay event is not proof
of healthy playback. `playback_main_operation_slow` names slow synchronous
snapshot, audio-track, access-log or error-log reads.

In Debug builds, scheduler reports also carry background-only process resource
samples; these additional measurements are not collected in Release. CPU
`process_cpu_core_equivalents` is CPU seconds divided by the recorded sampling
interval: 1.0 means one fully occupied core, not the whole device. Pending main
callbacks retain peak sampled CPU, resident memory and physical footprint
without queuing more callbacks. These are whole-process measurements shared by
all panes, not per-stream costs; never sum the panes' resource values.
Compare `resource_sample_uptime_seconds` with the event time, since the latest
background sample can precede main-queue delivery. The first sample after
monitoring resumes has no CPU delta. `volume_free_bytes`/`volume_total_bytes`
describe the filesystem, not an app cache quota, and refresh at most every 15
seconds (`disk_sample_uptime_seconds`). Resource errors have explicit numeric
codes rather than fabricated zero usage/free space. Sample duration and its
pending-callback peak expose the probe's own overhead. These measurements help
attribute pressure; they do not prove which function stalled or why a cache
file disappeared.

For lost sound after a stall, treat reconnecting the output as a workaround,
not evidence against an app bug. `audio_playback_state` records route port types,
mute/volume, playback intent, enabled audio tracks and restart serial around
activation and Native/player recovery. Route events include previous/current
port types, never device names or identifiers. Video progress alone is not
proof that audio rendering survived.

An active telemetry file can disappear or a write can fail. The writer checks
the active path every 15 seconds and retries persistence failures after five
seconds without waiting for a new playback session. A recovered record marks
`telemetry_persistence_recovery` and any
`telemetry_persistence_records_unconfirmed`; those missing/uncertain records are
not healthy playback evidence. Retention still protects other open pane files
within the same file budget. Keep the foreground log before interpreting peer
audio events as the foreground failure.

Check auxiliary chat work too: merged YouTube chat can repeatedly resolve and
bootstrap large watch pages when unavailable. Keep HTML decoding and literal
marker searches off the main actor, with cancellation; only publish the parsed
result/status on the main actor. See `ChatService+YouTube.swift`.

Debug controlled playback emits `native_hls_delivery_timing` per segment:
`max_ingress_wait_seconds` excludes the preceding chunk's processing;
`max_consumer_queue_seconds` measures receipt-to-consumption delay;
`max_remux_publish_seconds` is remux/publish wall time, not CPU time.
Ingress wait includes URLSession/delegate scheduling, so it is not by itself
proof of network loss. The separate `network_transaction` stage records
connection reuse, connect/TLS and first-byte timing without URLs or addresses.
Slow producer/probe manifests, movie preparation and segment-finalization work
have separate stages; incomplete bodies are not grouped with completed transfers.
Slow/failed local requests are rate-limited and identify only a resource kind;
blocking playlist/part waits can be intentional.

The analysis tool groups these event metrics under `diagnostic_timing_groups`,
separately from sampled player metrics. Detailed native traces and mobile logs
retain their existing Debug scope; TV scheduler evidence uses retained telemetry.
Missing groups, dropped records and inactive/background intervals must remain
explicit limitations, not success-shaped conclusions.

## Validate the claim, not a proxy

Use the build/generation wrappers and target selection in
[CONTRIBUTING.md](../CONTRIBUTING.md#building-and-running). Shared logic must
cover both schemes; mobile source/test membership is explicit in `project.yml`.
For a focused deterministic media/policy check, substitute an available simulator:

```bash
./tools/xcbuild.sh -project Strozz.xcodeproj -scheme Strozz \
  -destination 'platform=tvOS Simulator,id=<simulator-uuid>' \
  -only-testing:StrozzTests/NativeTransportRemuxTests \
  -only-testing:StrozzTests/NativeCMAFRemuxTests \
  -only-testing:StrozzTests/NativeAdaptiveRenditionPolicyTests test
```

The same classes are included in `StrozzMobileTests`: use `StrozzMobile`,
an iOS Simulator destination, and that test-target prefix. Add the smallest
adjacent coverage appropriate to the change:

| Change | Regression coverage |
| --- | --- |
| Parts, boxes, timestamps, wrap and rewind | `NativeCMAFTests`, `NativeTransportStreamTests`, the remux tests above |
| Transfer cancellation and failure isolation | `NativeHLSChunkReaderTests`, `NativeRenditionReportTests` |
| Drift, stalls and retry ownership | `NativeLiveCatchUpTests`, `NativeBufferedStallRecoveryTests`, `NativePlaybackRecoveryTests`, `MultiviewForegroundRecoveryTests` |
| Audio and TV presentation | `PlaybackAudioSessionTests`, `MultiviewFocusRenderingTests`, `MultiviewContinuityLiveTests` |
| Mobile ownership, transitions and live frames | `MobilePlaybackTests`, `MobilePictureInPictureTests`, `MobileLivePlaybackTests` |
| Chat timing and evidence | `LiveChatSyncBaselineTests`, `PlaybackTelemetryTests`, `tools/tests/test_playback_diagnostics.py` |

Live/hardware tests are deliberately opt-in. Read their guards before running.

A long simulator run is available in
`NativePlaybackSoakLiveTests/testOptInLongVariedLivePlaybackSoak` with
`STROZZ_LONG_SOAK=1` and 6...16 public `STROZZ_SOAK_CANDIDATES`. It selects six
currently live inputs using observed TS/CMAF and frame-rate metadata, defaults to
30 minutes each, then runs 15-minute grid/expanded/returned-grid stages.
Candidate selection should span broadcasters/delivery regions, not only genres;
reports include declared codecs/bitrate, playlist cadence, fetch time and PDT age.
Those measurements do not independently verify broadcaster location or true
end-to-end latency. Offline candidates and missing comparisons remain explicit.
All simulator players are muted; it cannot take over hardware. Reports persist every
30 seconds, with bounded incident and stage-end diagnostic copies. Short stall
notifications, recovered failures, item replacements and missing sampling
evidence fail the stage; the existing app frame consumer supplies decoded size
and age, rather than adding a competing video output. Missing input-format
coverage is explicit, not a pass. This is not physical-TV certification.
`STROZZ_SOAK_MODE=followup` rechecks the current live pool, selects one broadcaster
not listed in `STROZZ_SOAK_COMPLETED_CHANNELS`, and runs that single-stream stage
plus the multiview stages. It supplements, never replaces, the original reports.
`STROZZ_SOAK_MULTIVIEW_PANES` explicitly selects 2...4 panes (default four);
record the actual workload rather than claiming unavailable four-pane coverage.
`STROZZ_SOAK_MODE=multiview` runs only those stages against freshly qualified
inputs. Video freshness/quality is assessed only while the pane is visible;
hidden time is reported separately, without exempting clock/engine failures.
The existing four-second frame-freshness deadline starts when a hidden pane is
revealed; its preceding hidden frame age is not a visible freeze. Already-visible
panes do not receive another deadline just because the observation phase changes.
The separate `testOptInShortMultiviewVisibilityRegression` uses
`STROZZ_VISIBILITY_CHECK=1` for a fixed, 30-second-per-stage reproduction against
Valkyrae/Gaules/Burn when all three are live; it is not sustained-soak coverage.
`testOptInSixPaneOptimizationContinuity` uses six distinct, currently live
`STROZZ_SIX_PANE_CHANNELS` logins for two-minute grid/expanded/returned-grid stages.
It uses the same strict playback/evidence checks, but is not a long soak or a
physical decoder-capacity measurement.
Sampling-only gaps are marked incomplete separately from playback faults; neither
is a clean pass. Unsupported CMAF boxes report numeric type/size, and TS
finalization failures report pending sample/PES byte counts, not media payloads.

For emote-cache changes, `ChatBadgeRenderingTests` checks source pixels,
animation and lifecycle. `STROZZ_EMOTE_CACHE_PERFORMANCE=1` additionally compares
native WebP frame-decode counts while an inactive copy receives repeated updates.
Do not repeatedly stop an already-inactive view: SDWebImage's frame pool is
shared by image providers, so repeated buffer purges make visible copies decode
the same frames again. Stop/purge on the visibility transition, not every update
or teardown of an already-stopped consumer; keep the native memory budget.

A skipped test is not a pass for the behavior being investigated. The simulator-only
`NativeStreamMatrixLiveTests/testOptInUnrequestedPauseRecoversWithoutChangingAutoOrItem`
uses `STROZZ_NATIVE_PAUSE_TESTS=1` and one live `STROZZ_MATRIX_CHANNELS` login.
It injects a player stop to verify recovery and intentional-pause protection;
it does not reproduce or prove the original reason AVPlayer stopped. In
`MultiviewContinuityLiveTests`, `testOptInPhysicalCMAFZoomKeepsPlayback` requires
hardware-takeover permission, `STROZZ_CMAF_PHYSICAL_TESTS=1`, and two public live
channel logins in `STROZZ_MATRIX_CHANNELS`, with CMAF verified on the primary.
It needs the existing account restored. `STROZZ_MULTIVIEW_HOLD_SECONDS` selects
the bounded hold; `STROZZ_MULTIVIEW_TEST_AUDIO=audible` keeps only that primary
audible without changing system volume. With `xcodebuild`'s runner, prefix these
environment keys with `TEST_RUNNER_`.

Capacity is a separate test: `testOptInPhysicalGridResolutionCapacity` requires
`STROZZ_MULTIVIEW_CAPACITY_TESTS=1`. Set
`STROZZ_CAPACITY_APPLY_GRID_BUDGETS=1` to exercise actual policy rather than an
unrestricted stress workload. Simulator/desktop decoding cannot certify
physical-TV capacity, audio or mounted AVKit handoff behavior.

An Auto fix needs sustained fresh decoded frames at the claimed resolution,
real down/up adaptation under changed upstream capacity, retained player/item/
surface identities during presentation changes, and unchanged latency/recovery
policy. Exercise both TS and source-CMAF. Record sampling interval and observation
window; do not promote exit status, clock movement, a short screenshot or static
metadata into continuity proof. Release defaults must work without Debug-only
launch flags; see the [release checklist](../fastlane/README.md#two-platform-release-checklist).

Implementation comparisons are not license permission: the StreamNook engine
reviewed at [`5a60d04`](https://github.com/StreamNook/StreamNook/tree/5a60d045cc7aa78bcb86f8dff787c1864ff8d8b3)
is noncommercial/source-available, not MIT/BSD. This implementation is independent;
do not copy or translate that engine without checking its license.
