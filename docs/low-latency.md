# Low-Latency Playback — what we know

Notes on the live-playback latency work: the local playlist-rewriting **proxy**
(prefetch promotion) and the two **Auto profiles** that trade latency against
quality on top of it. This file deliberately separates **verified facts** from
**open questions**. Only add something to "Established facts" once it is actually
confirmed (by Apple docs, the HLS spec, the code itself, or a reproducible
on-device observation). Hypotheses go under "Open questions" until proven.

## TL;DR

- **Auto · Native Low Latency** is the new default Twitch profile. The original
  **Auto · Low Latency**, **Auto · High Quality**, and fixed-quality options
  remain available. Native source-CMAF indexing and original-CDN byte ranges
  now run in Swift in the app; no desktop helper or certificate is required.
  The adaptive master is preserved. Transient failures retry native playback
  before considering the existing player; fallback is explicit in the quality
  menu/diagnostics.
- Choose the old **Auto · Low Latency** row for an immediate comparison. Native
  mode uses AVPlayer's LL-HLS timing, not the legacy variable-rate controller.
  Choosing native mode explicitly selects Twitch rather than a YouTube simulcast.
  Fixed video qualities retain the selected native engine and its buffer policy.
  Explicit legacy profiles and Audio Only keep their existing standard paths.
- Native mode is independent of the legacy Diagnostics **Prefetch Proxy**
  kill-switch. Its fallback honors that legacy kill-switch, just like the legacy
  profiles themselves. The quality menu and diagnostics explicitly identify
  standard playback after fallback; selection is not proof of activation.
- The native engine now indexes both H.264/AAC MPEG-TS and CMAF. TS parts are
  packet-aligned, retain PAT/PMT initialization, and use measured PES timestamps.
  Non-terminal TS cut points wait at least 382.5ms: 85% of the advertised 450ms
  part target. Cutting at 380ms produced invalid parts on 50fps feeds and caused
  AVPlayer playlist rejection (`CoreMediaErrorDomain -12642`).
  Both formats serve short, bounded media chunks through an app-owned
  **127.0.0.1-only** listener. This avoids an observed AVPlayer/CDN range mismatch
  on large source segments (`-12939`, cached bytes starting at zero instead of the
  requested offset). No re-encoding, certificate, external process, or remote
  service is required. Retained media is capped at 96 MiB; older rewind media
  continues using original CDN segment URLs.
- Native startup waits until the indexer has actual live-prefetch content and
  aligns once to live after native playback begins. Returning to live preserves
  the engine; native stalls no longer invoke legacy stability recovery.
  A shared budget permits two fresh native attempts per rolling minute for
  temporary origin, timeline, startup, or watchdog failures. Each retry resolves
  a fresh signed master and replaces the failed engine instead of reusing it.
  Verified unsupported formats skip those futile attempts; repeated failure
  still permits a visible legacy fallback. Native drift is corrected by gentle
  rate adjustment rather than seeks; automatic seek-on-rebuffer is disabled
  once the initial native live start is established.
- A quality-switch blocking reload can return its already-indexed parts before
  that cold rendition catches up to the live edge. Initial tune-in still waits
  for live content; unpublished parts still block. A reproduced xQc stall
  exposed a 2.33-second unnecessary wait while the requested rendition's cached
  parts were available.
- When native playback stops advancing but its contiguous forward buffer has
  refilled to at least the configured buffer preference (minimum three seconds),
  TV and mobile request one same-item resume at normal speed. This does not seek
  or increase target latency. A stale `isPlaybackLikelyToKeepUp=false` does not
  suppress the attempt; no clock progress within five seconds escalates through
  the existing native retry budget. Pause, suspension, startup, seeking, and
  external playback remain excluded. A resume request is not proof of recovery:
  subsequent clock and video samples are required.
- If the clock advances but a video rendition never decodes, TV and mobile
  make one explicit recovery attempt using the highest-bitrate video rendition.
  Native playback stays native, audio-only tracks are excluded, and the quality
  menu reports the change. TV keeps this override local to the current stream;
  it does not overwrite the viewer's saved Auto/fixed-quality preference.
  Choosing a quality manually clears the override.
- Upstream media uses one reusable HTTP session per active rendition, rather
  than a new TCP/TLS connection for every segment. Cancellation and completion
  callbacks are fenced to their own task; stopping the reader is terminal.
  A GronkhTV comparison observed zero reused connections in 30 baseline samples
  versus 29/29 reused warm connections after the change, removing repeated
  roughly 90ms connection setup without changing the latency target. This
  eliminates avoidable setup work, not arbitrary upstream delivery delays.
- When native activation fails, its row disappears for that channel and the
  checkmark moves to the actual fallback mode. The old **Auto · Low Latency**
  label refers to the original prefetch engine, not native partial playback.
- Normal HLS discontinuities, initialization-map changes, and ad date ranges are
  now retained per segment rather than treated as fatal. The native decoder
  timeline resets at a period boundary; completed ad playlists without prefetch
  use a cadence-aware hold-back until live parts resume. Encryption, missing
  packets, and malformed media still fail explicitly.
- Native Auto excludes audio-only variants from its adaptive **video** master.
  The existing explicit Audio Only quality remains available on the normal path.
  Modern Twitch masters may identify audio-only entries solely by audio codecs
  and absence of a resolution, without the old `VIDEO="audio_only"` attribute.
- Cold startup seeds the rewind window from verified complete-segment metadata
  instead of downloading all historical media. Only the newest segment and
  live edge are indexed. Idle renditions resume their retained timeline, and
  active media requests keep their indexer alive during adaptive switches.

### Native-first recovery

The native profile remains the default. Previously, the TV watchdog had a
two-attempt recovery budget, but direct origin failures and failed-to-end events
could bypass it and downgrade immediately. These paths now use
`NativePlaybackRecovery`, also shared by the mobile player. Brief unavailability,
timeouts, discontinuity/timeline failures, incomplete keyframes and indexer
overruns get bounded fresh-native attempts. Unsupported codecs/program tables
and unsupported part durations can still fall back immediately.

Duplicate callbacks coalesce during a TV source refresh. Startup waits follow a
retry-owned replacement rather than launching a competing load. Pause/rewind
intent is retained, a newer pause remains paused, and discarded-source or
dismissed-player completions cannot resurrect playback. A failed fresh source
resolution reports an error rather than pretending standard playback was
necessary. The default does not force unsupported media to play or promise
unlimited retries; legacy playback is the last-resort stability path, not the
first response to a transient engine error.

### Silent audio after returning to the TV app

A physical build 1921 report followed a thirteen-minute background interval:
native xQc video resumed at 1080p60, normal rate and about 2.12 seconds of
source-date latency, but stream audio was silent while interface sounds worked.
Pause/resume did not help; closing and reopening the stream restored audio.
Inspection of a source segment and its generated native parts produced identical
AAC bytes with normal decoded levels. This points to retained playback/render
state rather than audio removed by the native indexer; the exact private
AVFoundation failure was not observable in that build.

The native foreground refresh now recreates the AVPlayer and its AVKit rendering
surface as well as the signed source, engine and item. It preserves mute, volume,
external-playback policy and paused/rewound intent. Ordinary live playback,
catch-up and source retries do not gain another reset. A fresh paused owner may
expose its date/seekable timeline before `readyToPlay`; restoration uses that
timeline with a bounded date seek instead of briefly playing to prepare it.

Snapshots now include player mute/volume, audio-session category/mode, output-port
types, system output volume, external playback, and loaded/enabled audio-track
counts. These describe configuration, not proof that sound reached the speakers.
Device/port names and identifiers are not recorded. The foreground regression
probe remains muted and verifies new player/controller ownership, enabled audio
tracks, decoded video, and preservation of a paused position.

A later xQc startup on the physical TV failed with
`AVFoundationErrorDomain/-11819` (`mediaServicesWereReset`). Video resumed after
player replacement, but the audio session still reported `SoloAmbient/default`
on a Bluetooth output. An enabled audio track and advancing video did not prove
audible recovery. The logs identify the system reset, not what caused it.

The TV player now configures and activates a `playback/moviePlayback` audio
session before starting or resuming, including after a fresh foreground owner.
Foreground recovery waits for the app to become active. Media-service loss
pauses playback until reset; reset recreates the player and item even if their
status has not yet failed, coalesces with a pending native source refresh, and
does not spend the native source-failure retry budget. Interruption handling
honors the system's resume permission and the viewer's pause/scrub/background
intent.
Activation failures stop playback and present an error rather than leaving
silent video presented as healthy. Route changes and audio-session lifecycle
events are recorded without device names or identifiers.

Paused date restoration corrects a nearby-keyframe landing against the new
item's date/time mapping with a bounded precise seek. Live simulator coverage
checks startup, foreground replacement, media-loss/reset notification delivery,
reconfigured audio, fresh AVKit ownership, and paused restoration. It remains
muted: it verifies recovery mechanics, not audible output through physical
Bluetooth hardware.

A later physical return exposed an unmatched audio interruption: tvOS sent
`interruption began` after backgrounding but never sent `ended`. The stale flag
blocked foreground restoration indefinitely despite the viewer never pausing.
On a real background-to-active transition, TV and mobile now recheck audio
activation instead of waiting forever for that missing notification. Explicit
pause intent remains intact, and failed activation surfaces an error. Ordinary
interruptions while already foregrounded still honor their resume permission.

The same live-playback recovery contract also applies on iPhone/iPad.
`PlaybackAudioSession` and `PlaybackPositionRestoration` are compiled into both
targets instead of maintaining separate setup and date-seek implementations.
Mobile replaces its AVPlayer/AVKit owner on foreground return and media-service
reset; ordinary rendition changes do not recreate the renderer.
Loading and transport presentation use the shared
`PlaybackPresentationState` and `StreamLoadingView`: mobile keeps Close available,
but does not stack a disabled pause icon over the loading indicator. Error and
retry content replace loading rather than coexisting with it.

### Whole-segment sources and native quality selection

The physical AustinShow capture on build 1920 started about 20 seconds behind
and later dropped from 720p60 to 360p in Auto without a recorded stall. Its
upstream playlists advertised `TARGETDURATION=6` but published two-second
segments without Twitch prefetch tags. The native origin requested an 18-second
hold-back, then treated that position as normal. Manually selecting 720p60 also
hit an Auto-only engine gate and switched to the legacy path.

The native origin now derives the non-prefetch cushion from the largest recent
completed-segment duration plus 1.5 seconds (3.5 seconds for this source), not
three times the advertised maximum. True prefetch retains its 1.5-second
hold-back. The forward-buffer request is at least three seconds and is not
reduced after catch-up; shrinking it to one second reproduced a stall and
adaptive-quality collapse after an otherwise successful correction.

Publication timing is separate from transfer speed. The origin retains one
already-cached part as its preload hint and makes the blocking playlist wait
for subsequent publication. A production pause therefore does not look to
AVPlayer's bandwidth estimator like a slow download of a tiny part. No video is
discarded: subsequent parts release the previous tail, and end-of-stream releases
the final tail. This applies to prefetch and whole-segment input without changing
the media bytes or forcing an Auto resolution.

Rendition reports use relative URIs and verified upstream sequences. A cold
rendition indexes the requested complete sequence rather than skipping directly
to a newer segment whose parts cannot satisfy that request. Optional metadata
refreshes are coalesced background work, and already-running rendition indexers
are not fetched a second time just to build reports. An active playlist never
waits for an unused rendition's network request. Previously, the active response
awaited the entire report refresh, allowing one slow unused quality to hold
already-available playback data. A regression reproduces that dependency and
requires cached responses to complete while the unused request remains blocked.
Unavailable reports are logged and removed rather than inventing their sequence.
Shutdown rejects new requests and drains in-flight manifest fetches before
invalidating their shared URLSession, including when a quality change cancels
concurrent report refreshes.
Diagnostics include the source's prefetch capability, live hold-back and edge age,
reasons for stopping rate correction, and the last/maximum rendition-report
refresh duration. The same report-blocking, failure, and cancellation regressions
run in both TV and mobile targets.

The subsequent physical check held AustinShow at 720p60 for about eight minutes
without stalls or resolution drops before the broadcast ended and produced a
timeline error; that is a partial run, not a completed twelve-minute test.
Normal Auto/native playback on Burn then retained 1080p for 904 of 906 rendered
samples over roughly thirty minutes. One brief stall coincided with four seconds
at 720p; there were no 160p/360p collapses. Auto remains adaptive rather than
pinning a quality or hiding real network/decode pressure. The tvOS simulator's
inability to render that AustinShow feed also reproduced with the original report
wait restored; simulator clock progress was not counted as successful video.

TV and mobile fixed-video selections now retain native playback, fresh-native
recovery and pause/rewind intent. Audio Only, explicitly selected legacy modes,
AirPlay receivers and genuine unsupported-format fallback remain separate.
Whole-segment input cannot provide bytes before Twitch publishes them, so it
does not promise the same end-to-end latency as a true prefetch stream.

The final four-minute ESLCS simulator check retained 1080p60 through native
Auto, fixed video, and Auto again, with approximately 5.77 seconds median
source-date age and no native retries. A four-minute prefetch Shroud check
recovered an injected five-second pause with one held 1.05x entry and one
return to 1x, the same item, and no native retries or AVPlayer stalls; its
final source-date age was about 4.06 seconds. Both enforce decoded-frame and
clock-progress thresholds, not just an advancing timer. The TV suite executed
409 tests with seven explicit opt-in skips and zero failures. The mobile
live/quality/paused-restoration probe and seven lifecycle tests also passed.
These are bounded observations, not a guarantee for every network or broadcaster;
the physical TV outcome of this correction still needs watching.

**Physical-device finding:** the first installed integration was blocked by a
persisted legacy proxy-off setting. Device telemetry on Caedrel showed
`native_ll_hls=false`, `promotes_prefetch=false`, and roughly 20.6s source-date
age despite the native row being selected. The gate has been corrected. Caedrel's
inspected H.264 feed was MPEG-TS rather than CMAF. The subsequent TS implementation
and physical-device verification supersede that original format limitation.

**Physical TV verification (2026-10-04):** `NativeTwitchDeviceTests`, explicitly
run on the paired Apple TV, passed with MPEG-TS at 50/50 fresh-frame samples and
3.75s median source-date age. The CMAF case produced 48/50 fresh-frame samples,
3.47s initially and 6.47s after forced quality changes, with no native error-log
entries. Both used a 1.5s native live offset. These are bounded measurements,
not a universal latency guarantee or proof that all network/ad transitions
work. Follow-up changes realign after a native quality transition as well.

**Sustained full-app verification:** after the transition fixes, the actual
`PlayerView` (including its recovery loops, not just a bare AVPlayer) completed
six minutes each on live TS and CMAF broadcasts on the paired TV. Recorded samples
from 20s through 350s stayed native with no fallback: roughly 2.78s source-date
age for TS and 2.60s for CMAF. Both playback test cases passed their assertions.
The overall Xcode command nevertheless returned 65 because its remote
test-runner connection was invalidated afterward; that infrastructure error is
not represented as a clean test-command pass. Earlier failed long runs are
retained in session evidence. This does not establish unlimited-session or
every-ad-transition reliability.

- Twitch's own low-latency relies on a proprietary HLS tag AVPlayer ignores.
- We close most of that gap with an in-process proxy that promotes those
  segments. It is always on for live and is the real, stable latency win.
- The quality picker exposes two Auto profiles — **Auto · Low Latency** and
  **Auto · High Quality** — that differ only in buffer depth and gentle
  catch-up (see `LivePlaybackPolicy`). An explicit rendition pick is a third,
  fixed-quality case.
- The current whole-segment proxy typically sits several seconds behind the
  available edge. This is not a proven AVPlayer limit: a standards-compliant
  partial-segment bridge is a separate approach (see the isolated prototype below).
- Sharpness, freezes, and "jumps" are governed by buffering and ABR behavior,
  not by playback speed. Those are still being tuned; use the Diagnostics
  overlay to gather real data.

## How playback is wired

1. `PlaybackService` resolves a channel to Twitch's HLS **master** playlist
   (via the GraphQL access token + Usher), and parses the per-rendition
   variants into `StreamQuality` values (each with a direct media-playlist URL).
2. `PlayerView` plays it with `AVPlayer`.
3. `LowLatencyHLSProxy` sits in front of the playlists via an
   `AVAssetResourceLoaderDelegate` on a custom URL scheme (`strozz-ll://`). It is
   attached whenever prefetch promotion **or** Stream Rewind is on.
4. Prefetch promotion is **on by default** and powers both Auto profiles. It is
   no longer a user-facing toggle; an advanced **Prefetch Proxy** kill-switch
   lives under the Diagnostics overlay for troubleshooting only.

## The two Auto profiles (`LivePlaybackPolicy`)

Both Auto rows stay on the adaptive master (ABR active) and keep prefetch
promotion on; they differ only in how they trade quality for latency. The
concrete tuning lives in `Strozz/Models/LivePlaybackProfile.swift`:

- **Auto · Low Latency** (default) — shallow forward buffer (~3s) to sit near
  the edge (and resume fast after a dip rather than waiting to refill a deep
  buffer), plus a **bidirectional adaptive playback-rate controller** (see
  `desiredLivePlaybackRate`) that runs on its own **sub-second loop**
  (`rateControlIntervalSeconds`, ~4 Hz) — far faster than the 1 Hz latency
  monitor — so it can react to a draining buffer before it empties. As the
  forward buffer drains under ~1.5s it eases the rate down toward **0.90×**
  (anti-stall: playing slightly slow lets the buffer refill so a transient dip is
  absorbed instead of a hard stall); once the buffer clears ~2.0s *and* the edge
  gap exceeds the **~2s target** — deliberately *tighter* than the 3.5s seek
  landing point so catch-up always has slack to chase — it nudges the rate up
  **proportionally** (the further behind the edge, the faster it chases, capped
  at **1.12×**) and eases back toward 1.0× as it closes on the target. The two
  arms settle at an equilibrium of ~2s from the edge with a safe buffer. ABR is
  also free to drop resolution to avoid a stall; degraded quality is acceptable,
  stutter is not.
- **Auto · High Quality** — deeper forward buffer (~8s) so ABR has the runway to
  settle on and hold the best stable resolution, accepting a little more
  latency. No rate games (always 1.0×); it never sacrifices quality on its own.
- **Pinned rendition** — a stable buffer (~8s) with no rate games; ABR is off, so
  it holds exactly that rendition (and rebuffers rather than downshifting).
- **Stability fallback** (automatic, legacy playback) — a runtime override, not a
  user-selectable row. A **stream-stability watchdog** counts destabilizing
  events — stalls plus involuntary backward playhead jumps (an AVPlayer rewind we
  never request) — in a rolling window (`unstableEventWindowSeconds`). Reaching
  the threshold flags repeated instability; those symptoms alone do not identify
  whether the source, network, or player caused it. To stabilize a bad stream as
  soon as you arrive, the trip is **aggressive and front-loaded**: during the
  first `unstableStartupGraceSeconds` of playback a **single** event trips it;
  after that any **two** events in the window do (so "2 stalls", "2 jumps", or "1
  stall + 1 jump" all qualify). Stalls feed the watchdog from both the
  `AVPlayerItemPlaybackStalled` notification and the frozen-playhead heuristic;
  backward jumps feed it from the playback-health sampler. All of this runs with
  the diagnostics overlay **off**.

  Once flagged, the normal low-latency strategy is actively harmful: the
  **low-latency prefetch proxy** keeps promoting `#EXT-X-TWITCH-PREFETCH` segments
  and shoving the playhead at a live edge the source can't sustain, so it stalls,
  rewinds, and loops. The fallback inverts the trade-off:
  - **Stops prefetch promotion in place.** The current proxy stops promoting
    segments but retains its DVR history and the current AVPlayer item. Stability
    entry does not reload or seek backward; it never replays watched content to
    manufacture a buffer. Later necessary recovery loads also suppress promotion.
  - **Deep forward buffer (~12s), no catch-up, edge-resync suppressed.** The
    anti-stall slow-down stays on as the last line of defence.
  AVPlayer can rebuffer at the current position rather than deliberately rewinding.
  This does not guarantee smooth playback on a broken feed. The flag **latches for the whole
  channel session** — a stream that has proven it can't hold the edge keeps the
  safe strategy until the viewer changes channel (there is no auto-recovery; we
  never flap the proxy back on and risk re-destabilizing it). Surfaced in the
  Diagnostics overlay as "LL proxy auto-off (unstable)" + "⚠︎ STABILITY MODE".
  Resets on every new channel session (`resetDiagnostics`).

An October 5 Ludwig capture on build 1908 showed a native stall/fallback followed
by an app-requested `stability_buffer` seek: the playhead was around 23.5 seconds,
the advertised seekable edge was only 22.061 seconds, and subtracting the old
20-second cushion sent playback to 2 seconds. Source-date age increased from
roughly 16.7 to 38.6 seconds. That automatic backward-seek path is removed.
The same capture exposed a second mismatch: the stored native profile could
enable legacy prefetch promotion after native failure even with the legacy
switch off. Item construction now uses the same effective fallback profile as
the quality menu, preserving the disabled switch while retaining DVR.

`StandardPlaybackStabilityTests` reproduces the lagging-edge numbers, verifies
zero seeks/item reloads on stability entry, checks paused/background/alternate
source exclusions, and verifies native fallback honors the legacy switch. The
capture does not identify the original upstream/native failure beyond
`unavailable`; preventing this app-induced rewind is not proof that native
fallbacks can no longer occur.

### Predictive instability (manifest analysis)

The behavioral watchdog above is reactive: it has to wait for actual stalls and
rewinds before it reacts, so the viewer still sits through the opening stutters
of a chronically-bad stream. The **predictive** path closes that gap by reading
the stream's own HLS media playlists — which the low-latency proxy already
parses on every refresh — and flagging a struggling encoder *before* playback
stutters. When it fires it trips the exact same `enterStreamStabilityMode()`
path (stop promotion in place and deepen buffering without a seek/reload), so all the behavior above is
reused unchanged; only the *trigger* is earlier.

It lives in `LowLatencyHLSProxy` (`recordInstabilitySignals`), accumulates a
small score per media-playlist refresh, and publishes a thread-safe
`predictedUnstable` verdict (guarded by `instabilityLock`, since the proxy writes
it on its `delegateQueue` and the watchdog reads it from the `@MainActor`). The
watchdog polls it in `samplePlaybackHealth` (`checkPredictedInstability`).

**Signals used (all manifest-*structure* only — deliberately independent of
wall-clock and `#EXT-X-PROGRAM-DATE-TIME`, so a device clock skewed from the
broadcaster can never produce a false trip):**

1. **Media-sequence stall** — the tail sequence (`#EXT-X-MEDIA-SEQUENCE` + number
   of listed segments) didn't advance between refreshes, i.e. the encoder
   appended no new segment this cycle. Strongest single signal
   (`stalledRefreshPoints = 1.5`).
2. **Irregular `#EXTINF`** — a listed segment deviates from
   `#EXT-X-TARGETDURATION` by more than `segmentDurationToleranceFraction` (0.5 ⇒
   a 2s-target segment shorter than 1.0s or longer than 3.0s). The final listed
   segment is excluded (a live tail can be a legitimate partial) and at least
   `minSegmentsForDurationCheck` (3) segments are required (`irregularRefreshPoints
   = 1.0`). **This is a weak, non-discriminating signal — it does NOT distinguish a
   bad encoder from a good one.** On-device, a known-good Rocket League stream read
   `Predict: … irregular EXTINF` on essentially every refresh while playing
   flawlessly, exactly like the struggling shxtou encoder. Because off-cadence
   `#EXTINF` fires on good and bad streams alike, its **total** contribution is
   hard-capped at `irregularIsolatedScoreCap` (1.0), so it can **never** trip the
   predictor on its own no matter how sustained the jitter — it only adds weight
   beside the discriminating signal (a stalled media sequence). A genuine
   bad encoder that merely jitters segment durations is left to the reactive
   watchdog (stalls + backward jumps).

   > **History:** an earlier revision escalated *consecutive* off-cadence refreshes
   > (1.0 → 2.0 → …) so sustained irregular `#EXTINF` could solo-trip, aiming to
   > catch shxtou predictively. On-device this false-tripped known-good channels
   > (Rocket League etc.) — dropping low latency on flawless streams — because
   > irregular `#EXTINF` turned out not to discriminate good from bad. The
   > escalation was removed; irregular `#EXTINF` is now a capped, corroborating
   > signal only.
3. **New discontinuities** — the cumulative discontinuity count
   (`#EXT-X-DISCONTINUITY-SEQUENCE` + in-window `#EXT-X-DISCONTINUITY`) grew since
   the last refresh, i.e. the encoder broke timeline continuity again
   (`discontinuityRefreshPoints = 0.75`). **Capped at `discontinuityScoreCap`
   (1.5), below the trip threshold**, so a normal ad break (which inserts
   discontinuities) can contribute but can never trip the predictor on its own.
   With the irregular cap above, the worst-case ad break — off-cadence
   segments *and* a discontinuity at both boundaries — tops out at 1.0 + 1.5 = 2.5,
   still below the 3.0 threshold.

**Tuning.** The score latches `predictedUnstable` once it reaches
`predictedUnstableScoreThreshold` (3.0) *and* at least
`minRefreshesBeforePrediction` (3) refreshes have been seen; accumulation stops
after `observationRefreshWindow` (12) refreshes (the predictor is an *early*
signal only — anything later is left to the behavioral watchdog, and bounding the
window stops a mid-stream ad break from tripping it late). With Twitch's ~2s
refresh cadence a chronically-bad stream (`shxtou`, `RTGame`, struggling
encoders) trips within roughly the first 3–4 refreshes (~6–8s), while a flawless
stream (score 0) or a single ad break (≤1.5) never does. All thresholds are named
`static let`s on `LowLatencyHLSProxy`; **they are first-cut values reasoned from
the HLS spec + Twitch's observed manifest behavior and still want on-device
confirmation against real known-bad streams.** Surfaced in the Diagnostics
overlay: a live `Predict: score x.x/3.0 · N refreshes · <reason>` line before a
trip, and `⚠︎ STABILITY MODE [predictive]` (vs `[observed]`) once latched. The
verdict is per channel session (cleared in `resetDiagnostics` /
`LowLatencyHLSProxy.resetInstabilityPrediction`).

**Rejected for this first cut: PDT / prefetch *staleness*.** "How old is the
freshest segment" (now − newest `#EXT-X-PROGRAM-DATE-TIME`) is an intuitive
encoder-falling-behind signal, but normal healthy low latency is already ~5–15s
behind live, and an absolute age measurement depends on the device clock matching
the broadcaster's — clock skew makes it false-trip-prone. The skew-invariant
structural signals above distinguish bad streams without that risk. A
*skew-invariant* version (the newest-content age *growing* across refreshes, or
prefetch dropping out after having been present) is a reasonable future addition.

The adaptive-rate technique mirrors low-latency DASH/HLS players (e.g. dash.js
`liveCatchup`): keep latency near a target by trimming a few percent off the
playback rate either side of 1.0 rather than hard seeks/pauses. Time-domain
pitch correction (`audioTimePitchAlgorithm = .timeDomain`) keeps the audio
natural through those changes.

Stutter-resistance in both Auto modes comes from ABR headroom plus the
anti-stall slow-down, not from a hard pin: ABR lets the stream step down instead
of stalling, and the slow-down rides out short buffer dips.

## Established facts (verified)

### The core latency problem
- **AVPlayer ignores `#EXT-X-TWITCH-PREFETCH:` tags.** AVPlayer's HLS parser
  implements RFC 8216 (+ Apple Low-Latency HLS) only; Twitch's prefetch tag is
  proprietary and is silently dropped. Those prefetch segments are exactly what
  makes Twitch "low latency" low latency, so a plain AVPlayer client trails the
  true edge by ~1–2 segments no matter how buffers are tuned.
- **tvOS has no `WKWebView`.** Frosty (iOS) reaches low latency by hosting
  Twitch's JS web player in a web view. That escape hatch does not exist on
  tvOS, so it is not an option for Strozz.

### The proxy
- The proxy rewrites the **master** playlist (variant + `URI="..."` lines onto
  the custom scheme) and the **media** playlist (promotes each
  `#EXT-X-TWITCH-PREFETCH:<url>` into a real `#EXTINF:<dur>,` + `<url>`
  segment). Segment URLs stay absolute `https`, so AVPlayer fetches them on its
  normal fast path.
- A **custom URL scheme** (not a localhost socket) is used on purpose: it avoids
  App Transport Security exceptions and the tvOS local-network privacy prompt,
  and keeps everything in-process.
- The HLS playlist UTI on this toolchain is **`public.m3u-playlist`** (there is
  no `public.m3u8-playlist`). It must be set on the content-information request
  or AVPlayer rejects the synthesized response. (Verified with a
  UniformTypeIdentifiers script.)
- **`AVURLAsset` retains its resource-loader delegate weakly.** The proxy must
  therefore be owned for the player's lifetime — it is held as `@State` on
  `PlayerView`.

### Quality / sharpness
- **`preferredPeakBitRate` is a ceiling, not a pin.** On the adaptive master
  playlist, ABR is free to serve a rendition *below* the ceiling. So selecting
  "1080p60" while staying on the master did **not** guarantee 1080p60 — ABR
  often sat lower, which looked soft.
- **An explicit quality pick now hard-pins that rendition's media playlist**
  (it stops using the adaptive master). ABR can no longer downshift it. "Auto"
  stays on the adaptive master.
- **A pinned rendition has no ABR fallback.** If its bitrate exceeds the
  connection, it rebuffers instead of stepping down — so "Auto" is the safe
  choice when a pin is unstable.
- **Playback speed never affects resolution.** Adaptive-rate changes (~0.90×–
  1.12×) cannot blur the picture; blur is always an ABR/rendition issue.

### The latency readout
- There are two different "latency" numbers, and they mean different things:
  - **Wall-clock behind-live** = `Date()` − `PROGRAM-DATE-TIME` of the current
    frame. This is how far behind the real broadcast the on-screen picture is —
    the metric a viewer actually experiences. Chat sync uses **excess** delay
    relative to normal live playback, not this entire value.
    For Twitch low-latency this is typically ~5–15s.
  - **Edge gap** = how far the playhead trails the freshest segment we can fetch
    (the seekable-window end). This is ~2–6s; it collapses to ~0 at the edge and
    is *not* a reliable "behind live" figure on its own.
- The on-screen badge **leads with wall-clock behind-live**, with the edge gap
  kept only as a fallback when wall-clock (`currentDate()`) is unavailable. The
  badge is **hidden by default** (`showLatencyBadge`).
- `PROGRAM-DATE-TIME` is approximate and occasionally stale (especially right
  after a stall/reload), so the raw wall-clock value can momentarily spike; the
  smoother applies outlier rejection, but transient jumps in the diagnostic
  readout do not reflect a real change in playback position.

### Recovery behavior
- **Decode-freeze watchdog now fires while the player is *waiting*, not only
  while `.playing` (UNPROVEN — added 2026-06).** Observed freeze: the picture
  was frozen while captions kept scrolling (and ran 2-3s *ahead* of the audio),
  with the overlay showing `State: Playing/waiting · evaluatingBufferingRate`,
  `Stalls: 0`, `Reloads: 0`, and a large `Edge gap: 26.7s` while catch-up ran at
  1.12×. That is a wedged *video decoder* with an advancing clock — exactly what
  `checkVideoDecodeFreeze` exists to catch. The bug: its guard required
  `player.timeControlStatus == .playing`, but the gentle catch-up rate controller
  constantly re-targets the rate, which flickers AVPlayer into
  `.waitingToPlayAtSpecifiedRate` (reason `evaluatingBufferingRate`). The guard
  failed on every such tick and reset the freeze timer, so the watchdog never
  reached its reload threshold. Fix: the guard now keys off `clockAdvanced >=
  0.05` (forward motion this sample) and `timeControlStatus != .paused` instead
  of requiring `.playing` — a genuine non-advancing stall keeps the clock still
  (delta ~0) so it still falls through to the hard-stall paths, and user
  pause/scrub are excluded upstream. The recovery reload also re-lands near live,
  so it clears the runaway `Edge gap` at the same time. `videoDecodeFreezeRecovery
  Seconds` was lowered 6s → 5s toward the ~5s recovery target. On-device this logs
  "video frozen (clock running) -> reload" and shows `State: FROZEN video`.
  **Status: targeted at the "captions move, video frozen" report but NOT yet
  reproduced/verified in the act — treat as a hypothesis.**
- **Involuntary live-edge drift is detected independently of the frozen-playhead
  heuristic.** With a large DVR window and `automaticallyWaitsToMinimizeStalling`
  on, AVPlayer can rewind the playhead far back inside the seekable window to
  refill its buffer and then play *forward* from there — so the old "playhead
  isn't advancing" stall check never fired, and the player could sit 120s+ behind
  live indefinitely. `samplePlaybackHealth` now also watches the edge gap while
  pinned to live and, past a threshold (~15s — far above the normal sub-second
  edge gap and ordinary rebuffer jitter, but low enough to rescue the viewer long
  before they're a minute behind), runs a **resync ladder**: a throttled
  lightweight seek back toward the edge (instant recovery the gentle rate
  catch-up can't achieve for a large hole), escalating to a full reload only after
  repeated failures.
- The playback watchdog, on a detected hard freeze, calls
  `recoverFromPlaybackStall`, which does a **full reload** (`load(...)`) and
  restarts playback near the live edge. A reload therefore looks like a large
  forward "jump" on screen — this is one known, code-level source of jumps
  (counted separately as "Reloads" in the Diagnostics overlay).
- **Return to live without reloading or chasing true live.** After scrubbing
  through the DVR window, returning to live simply resumes the *live-follow
  position* — a few seconds (`targetLiveEdgeSeconds`) back from the proxy's
  seekable tail, which is exactly where the viewer was before they rewound and the
  lowest latency playback can hold with the LL proxy on. `commitScrubSeek`
  recomputes that target from the current window and seeks the **same**
  `AVPlayerItem` there once. We deliberately do *not* try to reach the true
  wall-clock broadcast edge: with the proxy that tail is already as close to live
  as we get, and the old reload/seek-chase that tried only caused repeated
  rebuffering and — because a fresh item re-anchors near the edge — silently threw
  away the rewind window, so the viewer couldn't rewind again after catching up.
  Keeping the same item preserves the full seekable history. Because AVPlayer lets
  its seekable window go stale while playing from the rewind buffer (it stops
  refreshing the live playlist), the commit seek can land a few seconds further
  back than the pre-rewind position; `scheduleReturnToLiveCatchUp` then waits for
  the playlist to refresh and seeks the playhead up to the now-fresh
  `tail − targetLiveEdgeSeconds` once or twice. It targets the **reachable**
  seekable edge, never the wall-clock true edge (which the LL proxy makes
  unreachable), so it converges and stops rather than rebuffering on a moving
  target, and it is cancelled the instant the viewer leaves live again.
- The rewind bar's `0:00`/`LIVE` reference is that same live-follow point, not the
  raw seekable tail or the wall-clock edge: a stream the proxy holds e.g. 16s
  behind true live still reads `LIVE` while followed, and a 2-minute rewind reads
  `-2:00` (distance from the follow point), not `-2:16`.
- **Soft-stall deadlock recovery (the "Playing/waiting · evaluatingBufferingRate"
  freeze with a healthy buffer).** AVPlayer can park in
  `.waitingToPlayAtSpecifiedRate` (reason `.evaluatingBufferingRate` or
  `.toMinimizeStalls`) *even while it holds a perfectly healthy forward buffer*
  (`isPlaybackLikelyToKeepUp == true`, buffer not empty). It decided the network
  might not sustain the rate and then never re-evaluates on its own — because our
  adaptive-rate controller (`applyLiveLatencyCorrection`) only issues a play
  command when the **target rate changes**, and here it stays 1.0×. The playhead
  creeps (not a hard freeze, so "Stalls" stays 0 and the buffer-empty hard-stall /
  offline paths never fire) while behind-live grows without bound — the classic
  "9k viewers, ~24s → ~52s behind live, buffer ahead stuck at 4.3s" report.
  `samplePlaybackHealth` now detects "waiting despite a healthy buffer"
  (`isSoftStallSignal`, mutually exclusive with the buffer-empty `isHardStallSignal`
  by construction) and, after a short grace (`softStallNudgeSeconds`, 3s), kicks it
  with `player.playImmediately(atRate:)` — which explicitly *bypasses* AVPlayer's
  buffering-rate evaluation and plays the buffered media at once. If repeated
  nudges can't break it within `softStallReloadSeconds` (12s), it escalates to a
  reload (which also re-lands near live, recovering the latency that grew while
  stuck). On-device this surfaces a "soft-stall nudge (buf …s)" line in the
  Diagnostics event log. This also helps slow stream starts.
- **Buffer-agnostic frozen-playhead failsafe (UNPROVEN — added 2026-06, not yet
  confirmed to fix the freeze it targets).** Observed freeze: AVPlayer parked in
  `.waitingToPlayAtSpecifiedRate` (reason `toMinimizeStalls`) with the overlay
  showing `State: FROZEN` for 20s+ and **`Reloads: 0`** — i.e. *no recovery path
  fired at all*, and the stream only un-stuck itself after ~30–45s when AVPlayer
  self-healed. Root cause is a gap between the two existing detectors:
  - The **hard-stall** reload needs `isHardStallSignal` (buffer empty / not
    likely to keep up). In a `toMinimizeStalls` park AVPlayer stays *optimistic*
    (`isPlaybackBufferEmpty == false`, `isPlaybackLikelyToKeepUp == true`), so it
    never fires.
  - The **soft-stall** path needs a *known* forward-buffer reading at/above its
    floor (`(bufferAheadSeconds ?? 0) >= softStallBufferFloorSeconds`). The
    overlay read `Buffer ahead: —` (no loaded range spanned the playhead), so its
    floor check failed too.

  `samplePlaybackHealth` now adds a third arm (`isFrozenWaitDeadlock`) that fires
  precisely in that gap: `.waitingToPlayAtSpecifiedRate`, **not** a hard stall,
  **not** a soft stall, while the **live edge is still advancing**
  (`liveEdgeFrozenSince == nil`). The edge-advancing gate is what keeps it from
  reload-looping an *ended* stream (whose edge freezes immediately — that case
  stays owned by the offline-detection tiers). On a fast timer it nudges with
  `player.playImmediately(atRate:)` after `frozenPlayheadNudgeSeconds` (2s) and
  escalates to a reload after `frozenPlayheadReloadSeconds` (5s), so a freeze that
  used to take 30–45s should now get a cheap nudge within ~2s and a hard reload
  by ~5–6s. On-device this logs "frozen nudge (buf …s)" and "reload (frozen
  playhead)". **Status: this is the intended fix for the `Reloads: 0` freeze but
  it has NOT been reproduced/verified against a real freeze yet — the trigger is
  intermittent. Treat as a hypothesis until the overlay shows it catching one.**
- **End-of-stream / offline detection (the "stream ended but it just froze"
  bug).** When a broadcast ends or raids, Twitch's `streamLiveStatus` GraphQL
  keeps returning `.unknown` (not `.offline`) for tens of seconds to minutes, so
  every offline path that *asks Twitch* (`probeOfflineIfStreamEnded`, the reload
  recovery's pre-check, `load`'s post-failure check) fails to fire. The only
  trustworthy signal is local: **a live broadcast keeps advancing its seekable
  edge; an ended one freezes it.** `samplePlaybackHealth` tracks the max edge and
  how long it has been frozen (`liveEdgeFrozenSince`). Two Twitch-independent
  force-offline tiers (in addition to an 8s `probeOfflineIfStreamEnded` poke):
  - **Fast (`endOfStreamStalledForceOfflineSeconds`, 8s):** edge frozen **and**
    buffer starved (<1s) **and** a clean `isHardStallSignal`. This is the
    unambiguous "ended" signature — no content left to play and none arriving.
    It is deliberately set *below* the hard-stall reload window (≈12s of frozen
    playhead): a recovery reload calls `stopPlaybackWatchdog`, which wipes the
    `liveEdgeFrozenSince`/`lastLiveEdgeSeconds` freeze timer, so without this a
    dead stream loops reload→stall→reload (or sits on a frozen frame) forever and
    never surfaces offline — the nmplol/this-stream report. Because the edge
    freezes *before* the playhead (the buffer drains first), this fast tier
    provably fires before the reload can reset it, for any buffer depth.
  - **Slow (`endOfStreamEdgeForceOfflineSeconds`, 12s):** edge frozen + buffer
    starved even *without* a clean hard-stall signal (the anti-stall slow-down
    can keep flickering `timeControlStatus`), as a final backstop.
  A merely-struggling-but-live stream keeps advancing its edge (clears the timer)
  and, in stability mode, rides a deep non-starved buffer, so neither tier
  false-trips it. On-device the fast tier logs
  "offline forced (edge frozen + hard stall)".

## Background return and release review

### Coordinated native catch-up

Native drift correction never seeks or replaces the player item.
`NativeLiveCatchUp` requires four seconds of steady quality, advancing timestamps
and fresh video before correcting sustained excess delay of at least three
seconds. It enters at two seconds of forward buffer and **holds 1.05x**, rather
than retargeting rate on each sample. It returns to 1x near the calibrated live
position (0.75s excess), below 0.75s of buffer, on missing/stale timing or video,
or if AVPlayer does not retain the requested rate. A fifteen-second cooldown
prevents re-entry chatter. Pause/scrub, source changes and leaving live playback
stop correction. The healthy native cushion is subtracted, and neither it nor
chat's normal-delay baseline is recalibrated while speeding up.
The three-second native forward-buffer request also lets a delayed player meet
the two-second correction entry threshold without changing rate repeatedly or
starving playback again when correction finishes.

The reference is the rendition whose media is being requested, not the furthest
ahead inactive rendition. Startup is separate: prepare the native timeline behind
the loading surface and verify that its initial position is near live. If not,
perform one bounded initial live-edge alignment using AVPlayer's recommended
offset before revealing playback. An already-live start is left untouched.
The startup tolerance is 1.5 seconds of excess rather than the three-second
threshold used to trigger drift correction.
`automaticallyPreservesTimeOffsetFromLive` is then off for ongoing playback so
Apple cannot perform independent rebuffer seeks. Explicit
viewer-requested seeks/Back to live still work, and genuinely failed/stalled
playback retains bounded native recovery. Ordinary drift does not invoke it.

An October 6 physical xQc capture on build 1912 showed the earlier catch-up seek
starting for 3.110 seconds of excess while 1080p60 video was advancing with about
2.64 seconds buffered. It was followed by a 160p stall, a five-second seek
timeout, and a native hard-stall reload. There was no origin failure before the
seek. This motivated replacing the automatic seek rather than shortening its
timeout; it does not prove all Twitch interruptions are avoidable.

Build 1919's simulator check only established a reduction in delay, not full
convergence. Physical TV telemetry then showed **129 rate commands in under three
minutes, 128 followed by a time-jump notification within 300ms**, as latency grew
from about three seconds to over nine. Rate was following the normal segment
buffer sawtooth. The held-rate policy replaces that design; it does not restore
the app-issued drift seek. The live convergence check now requires near-live
startup, one catch-up entry and exit, return to normal rate, actual convergence
to the calibrated edge, and no item replacement/native retries.

A four-minute muted xQc simulator probe passed those stricter requirements after
an induced five-second pause, including the existing advancing-clock/fresh-frame
thresholds. The TV suite executed 396 tests with six opt-in skips and no failures;
the mobile live-start/quality/foreground probe and six lifecycle tests also
passed. These checks do not establish the corrected build's physical-TV outcome
or eliminate every possible adaptive-rendition stall.

Buddha's captured black-screen sequence also showed replacement attempts
followed by `currentItem == nil` and an indefinite `noItemToPlay` wait.
The app now rebuilds an AVPlayer in terminal failure (as required by AVFoundation),
or one that rejects its replacement item. Player-level status/errors are recorded
separately from item failures. A missing requested item triggers bounded recovery
instead of leaving a blank player indefinitely. Caption/visualizer clocks follow
the replacement player.

Deterministic tests cover the captured gap/buffer values, rate bounds/convergence,
quality churn, buffer/frame gates, pause/stale-item protection, zero automatic
seeks, active-rendition targeting, native-vs-legacy recovery exclusion, and
failed/rejected-player replacement. A bounded three-minute full-app simulator
run on Buddha included forced quality changes, advancing video and fresh decoded
frame observations, with no native fallback. Simulator results do not establish
that every cause of the physical-device black screen has been eliminated.

Native playback now stops its indexers and invalidates old callbacks when the
app backgrounds. On return it resolves a fresh signed Twitch master and creates
a new native engine instead of reusing a suspended engine with stale media URLs.
This addresses the captured Charli failure immediately after a roughly one-hour
background absence. Pause and rewind intent are preserved; an unavailable old
position is reported instead of silently resuming somewhere else.

The release review also corrected:

- Legacy Auto profile changes while watching a YouTube simulcast no longer
  replace its item with Twitch while leaving the source state set to YouTube.
- Async fallback restoration rechecks the current item, generation, user seek
  intent, pause, and visibility before resuming. New items and manual scrubs
  invalidate old restoration work.
- CMAF aggregation flushes an accumulated part before adding a valid fragment
  that would exceed the part target. Two valid 250ms fragments are emitted as
  separate parts instead of being combined into an invalid 500ms part.
- Previously nested test functions are now actual discovered XCTest methods.

The final simulator run passed 344 tests, with three physical-device-only tests
skipped. The standalone probe suite passed 31 tests. Background recovery was
covered deterministically without waking the physical TV; these checks do not
replace future observation of long background/foreground trips on hardware.

### Chat replay while rewinding a live broadcast

Rewinding into the in-progress VOD intentionally disconnects live IRC and uses
timestamped replay comments. The October 6 chat report occurred in that mode;
there was no frozen UI snapshot or delayed live-chat queue, but the older
telemetry did not include replay state, so it cannot identify the precise pause.

A current replay page with `hasNextPage=false` is now treated as temporary for
an in-progress recording: the comment frontier is polled every five seconds,
with deduplication, without reloading video. Completed VODs do not poll their
final page. A gap before the first comment no longer causes repeated backward
window resets. Network/parse failures show a replay error and retry with the
same throttle instead of advertising successful readiness. Telemetry records
live/replay mode, replay message count, frontier, requests, last refresh and errors.

### Inconsistent timestamps during adaptive switches

A later physical xQc switch from Source to 480p stalled at an unchanged player
clock while `currentDate()` jumped backward by about 1744 seconds. The latency
badge and chat sync inherited that false 29-minute delay; no matching backward
seek occurred. Date continuity is now checked against playhead movement even
while stalled, and rejected samples cannot replace the last trustworthy anchor.
Invalid mappings are excluded from chat holds and rewind destinations; the
latency display waits for trustworthy timing instead of substituting the
inconsistent seekable window. Item replacement resets the mapping explicitly.
Small forward refinements after resume or an adaptive switch are not permanently
blacklisted: a correction of at most six seconds needs two seconds of consistent
advancing playhead samples before re-anchoring. Frozen-clock, backward and larger
date-only jumps remain rejected. Live probes exposed both approximately 2.15-
and 4.24-second forward refinements; previously either could disable catch-up for
the rest of the item.

## Chat synchronization: extra delay, not total video latency

**Sync Chat to Extra Delay** is on by default. A one-time app-launch migration
enables it on every existing install, including previously stored off values.
The toggle remains available; turning it off after that migration is respected
on subsequent launches.
It never delays the outbound send API. Incoming messages, including the echo of
your own sent message, are held only for the estimated **extra** video delay.

`LiveChatSyncBaseline` tracks a reference per channel and video source:

- Native playback compares the displayed program date with the origin's
  `liveTargetDate()` (fresh indexed media minus the native hold-back).
  These dates share the same source clock, so broadcaster/device clock skew
  cancels. This is our stream's reachable live position, not a measurement
  of other Twitch viewers.
- Five steady, advancing samples over at least four seconds may establish
  a normal playback cushion. Native calibration must be within two seconds
  of the origin target. Startup, pause, scrubbing, recovery, deep-buffered
  profiles, and unhealthy playback cannot teach a larger baseline.
- On legacy playback, a previously learned baseline survives item reloads,
  fallback and quality changes. A baseline can also be learned during healthy
  Auto Low Latency playback near its reachable edge. A fresh high-quality or
  unsupported-source fallback cannot assume a universal three-second baseline.
- A stall or rewind cannot raise an established baseline. Fresh, consistently
  faster live playback can lower it. Switching channels or video sources resets
  it; VOD handoff continues to use the existing timestamped chat replay.
- Missing/stale timestamps leave chat live and expose an unavailable reference
  in settings/telemetry instead of inventing a delay. Differences under 0.75s
  are ignored to avoid holding chat for ordinary segment-delivery jitter.

With a learned 3s normal delay, 3s playback adds no chat hold, 8s adds 5s,
and 23s adds 20s. Existing queued live messages are retimed in **both**
directions as playback falls behind or catches up; unrelated backlog trickling
is unchanged. The previous 30s startup ramp is removed because calibration
already gates uncertain startup, and ramping a real rewind delay would leak
messages ahead of the picture. Returning to normal releases queued messages.
The local "Sent — appears in..." indicator follows the current additional hold;
the message has already been sent to Twitch.

This is an estimate of this session's extra delay. It is not proof of exact
social synchronization with all viewers or a guarantee against every spoiler.

## Realistic floor

Our shipping proxy hands AVPlayer whole prefetch segments; it does not generate
LL-HLS partial segments. Its observed delay does not establish a minimum delay
for AVPlayer itself. AVPlayer supports Apple's LL-HLS protocol, including partial
segments and blocking playlist reloads, but the origin must also satisfy its
transport requirements. A Twitch-to-LL-HLS bridge needs measurement on the target
device before assigning a latency target.

### Isolated native A/B prototype

`tools/run-ll-hls-probe.sh` runs two muted macOS AVPlayers side by side, without
changing the app, installing on Apple TV, or uploading to TestFlight:

- **Baseline:** compiles the actual `LowLatencyHLSProxy` and
  `LivePlaybackPolicy` from this checkout, uses the same selected rendition,
  and reproduces the low-latency rate policy. It deliberately excludes app
  watchdog recovery, UI, and adaptive rendition switching. It retains the default
  rewind playlist history but never initiates user scrubs.
  This is a proxy/policy baseline, not a complete running Strozz session.
- **Candidate:** when Twitch supplies CMAF, reads its in-progress segments,
  groups complete original fragments into roughly 400ms parts, and preserves
  their encoded bytes, decode timestamps, and source program-date anchor.
  `PART-TARGET=0.45` and `PART-HOLD-BACK=1.5` allow AVPlayer to choose its
  low-latency mode without repeated seeks or a custom catch-up controller.
  The candidate's default buffer preference is 1s. Keyframe-aligned parents,
  preload hints, blocking reloads, gzip playlists, and bounded retained bytes
  are provided by the experimental origin.
  The older MPEG-TS/FFmpeg remux experiment remains available but does not yet
  preserve source program-date mapping; it is **not** a verified low-latency path.
- **Evidence:** first decoded frame, fresh decoded-frame coverage, stationary
  playhead/paused/waiting fractions, buffer levels, native errors, and actual
  HTTP/2/part requests. A low-resolution luminance fingerprint provides a
  tentative relative alignment only when both players sustain decoding and the
  best alignment is distinguishable. Alignment uses short windows so drift
  cannot smear the whole run into an ambiguous match. Source program-date
  differences cross-check the decoded-video matches; absolute program-date age
  still depends on the broadcaster's clock and is not glass-to-glass latency.
  Native AVFoundation segment metrics also verify direct-CDN byte-range requests
  without storing the signed URLs.

The original desktop comparison bridge does not support adaptive quality, rewind, ad transitions, encryption,
or discontinuities. It stops explicitly on unsupported transitions rather than
skipping ads or concealing a broken timeline. Signed upstream URLs stay in
memory; evidence contains no playback tokens, audio, or full-resolution video.
All servers and subprocesses are owned by the bounded run.

Prerequisites: macOS/Xcode and Python 3.10+. CMAF needs no FFmpeg. The old TS
experiment requires an explicitly installed FFmpeg supporting fragmented MP4.
The HTTPS experiment also requires OpenSSL supporting `req -addext`.
The server dependency is separate from app dependencies:

```bash
./tools/with-apple-build-lease.sh strozz/ll-hls-probe-setup -- /bin/bash -c \
  'python3 -m venv build/ll-hls-probe/venv &&
   build/ll-hls-probe/venv/bin/pip install -r tools/requirements-ll-hls-probe.txt'

PYTHONDONTWRITEBYTECODE=1 build/ll-hls-probe/venv/bin/python -m unittest discover \
  -s tools/tests -p test_ll_hls_probe.py
```

There are two usable transports:

- **HTTPS/HTTP2 local origin:** serves playlists and cached parts. This proves
  the native protocol behavior, but requires the temporary-certificate approval
  described below.
- **Resource-loader playlists + direct CDN ranges:** `--resource-loader
  --direct-media` fulfills playlist requests through a custom scheme and gives
  AVPlayer real `BYTERANGE` parts on Twitch's original trusted HTTPS URLs.
  Preload requests redirect once their actual source byte range exists.
  This path does **not** create or trust a certificate and avoids a local
  media server. The prototype still uses a loopback Python process for
  playlist generation; a production port would generate those responses
  in-process in Swift. The source reader and AVPlayer currently download
  overlapping data, so reducing that overhead is a production requirement.

```bash
# No certificate or keychain changes; requires a channel with source CMAF.
bash tools/run-ll-hls-probe.sh CHANNEL /absolute/path/to/new-evidence 240 \
  --resource-loader --direct-media
```

`--resource-loader` **without** `--direct-media` is a negative-control experiment:
AVPlayer rejects custom-scheme media bytes with `custom url not redirect`.
This is why the practical path retains native HTTPS media delivery.

**Certificate approval is required for the HTTPS-origin comparison.** AVPlayer does
not accept the generated localhost certificate via the resource-loader trust
callback. With explicit approval, `--trust-localhost` temporarily adds only that
run's certificate to the login keychain, then removes its trust and exact
fingerprint in cleanup. It never changes system trust, existing certificates,
or TCP settings. Without the flag the experiment makes no keychain changes,
and native playback is expected to fail certificate validation. Do not grant
trust on the user's behalf without asking.

```bash
# Only after approval; choose a live channel and a NEW evidence directory.
bash tools/run-ll-hls-probe.sh CHANNEL /absolute/path/to/new-evidence 90 --trust-localhost
```

The duration is bounded to 30-300 seconds. Evidence is kept in the supplied
directory; output directories are never overwritten. `report.json` distinguishes
`native_candidate_playback_verified`, `comparison_valid`,
`sustained_partial_delivery_observed`, and `latency_improvement_observed`.
Exit status is nonzero unless both paths sustain native decoding, parts
continue across multiple post-startup windows, and at least two distinctive
decoded-video alignment windows show a candidate lead of at least one second.
The candidate must also have at least 99% fresh-frame coverage and at most
0.5% stationary-playhead samples. Some part requests alone are not a success.
Direct-CDN mode uses native segment/byte-range metrics rather than counting
local redirects as downloaded video.
A frozen baseline must not be presented as a latency win. Check
`temporary_certificate_removed`; a cleanup
failure is an error and preserves the certificate identity for recovery.

**Initial macOS prototype:** a plain HTTP/1.1 origin was rejected with
`Low Latency: Server must support http2 ECN and SACK`. After switching to HTTPS/
HTTP2 and approved temporary trust, a 90-second H.264 run produced 359 candidate
decoded-frame samples, no post-startup waiting samples, 371 HTTP/2 requests,
7 part requests, and 46 whole-segment requests. The baseline, in the original no-history harness configuration, stopped advancing
after about 15 seconds, so this run establishes native
candidate playback, **not** a reliable latency improvement or sustained
parts-only delivery. No Apple TV result or audio-sync guarantee is established.
The temporary certificate was removed and its absence verified.

In the final 90-second comparison, restoring the baseline's default history
retention kept **both** players advancing throughout the measurement:

| Observation | Baseline proxy/policy | Candidate origin |
| --- | --- | --- |
| Fresh decoded-frame samples | 356 | 359 |
| Post-startup decoded-frame coverage | 100% | 100% |
| Median buffered media | 2.92s | 3.93s |
| Native playback errors | None | None |

The candidate made 365 HTTP/2 requests and 315 blocking playlist requests, but
requested **47 complete segments and zero parts**, despite 457 parts being
published. Its reported configured live offset was 6s. The result is a valid
native playback comparison, **not successful sustained partial-segment playback
or a demonstrated reduction in delay**. Buffer duration is not live latency;
fingerprint matching did not produce a sufficiently distinct alignment to report
a reliable relative delay. Startup times also exclude origin warm-up and must
not be compared as end-to-end channel-switch performance.

### Native low-latency activation and follow-up results

The missing activation requirement was **`EXT-X-PROGRAM-DATE-TIME`**.
Appendix B.1 of the HLS specification requires it on every LL-HLS Media Playlist;
gzip delivery is also required. Preserving the original CMAF timeline avoids
inventing a mapping for remuxed timestamps.

A negative control removed **only** program-date tags from the otherwise-working
CMAF/gzip/HTTP2 path. AVPlayer reverted to a 6s configured/recommended offset,
requested 31 whole segments, and fetched zero parts in 60 seconds. With the
source date mapping present, it selected a 1.5s offset and continued fetching
parts. Merely writing a smaller `configuredTimeOffsetFromLive` was insufficient:
an early assignment was overwritten during preparation, and even a ready-time
assignment did not activate sustained parts in the timestamp-free stream.

Follow-up live measurements on two CMAF channels:

| Run | Candidate result | Delay evidence |
| --- | --- | --- |
| 3-minute HTTPS run, second channel | 425 post-startup parts, zero whole segments; continuous decoded frames, no waiting/stationary samples | Median source program-date age 2.15s; distinctive frame matches 12.5s and 19.25s ahead of the reduced baseline |
| 5-minute HTTPS soak | 725 post-startup parts, zero whole segments, zero failed local requests; continuous decoded frames, no waiting/stationary samples | Median source program-date age 3.54s; matched windows 11.25-25s ahead as the baseline drifted |
| 4-minute certificate-free direct-CDN soak | 270 native partial byte-range request events across the run; continuous decoded frames, no waiting/stationary samples | Median source program-date age 3.27s; matched windows 10.25s, 21.5s and 22.25s ahead |

The direct-CDN run also contained native events with a 2s duration. It is not
described as parts-only delivery; some requests use complete source objects.
The native metrics prove partial ranges continue throughout playback. A separate
2-minute direct-CDN run produced 301 partial-range events and a 1.5s native
offset, but only one distinctive alignment window, so its conservative
`latency_improvement_observed` result remained false.

These are **macOS AVPlayer prototype** results against the reduced
proxy/policy harness, not a comparison with the full shipping tvOS app.
The baseline slows and accumulates delay; its increasing gap must not be
marketed as a universal latency reduction. Program-date age is source-clock
dependent; the 1.5s native offset is not total capture-to-display delay.
Decoded video was measured while audio was muted, so audible synchronization,
long sessions, ad transitions, codec changes, and impaired-network behavior
remain unverified.

The native app implementation now lives in `NativeCMAF.swift` and
`NativeLowLatencyHLS.swift`. It indexes source fragments, generates adaptive
playlists, and delivers original-CDN byte ranges. The old profiles remain
unchanged. Runtime format changes and unsupported streams fall back for the
channel session rather than repeatedly restarting the native path. It retains
bounded source metadata for rewind, but never caches the media itself.
The production path must continue to preserve
adaptive quality, user-selected rewind positions, ad/raid transitions, and
the existing fallback. The app's later MPEG-TS path is independently packet-indexed and physically
verified as described above; those results do not come from the CMAF-only
prototype. Continuous device observation and transition coverage remain important.

### Upstream implementation comparison and reuse

The comparison used StreamNook commit
[`76b81ca`](https://github.com/StreamNook/StreamNook/tree/76b81ca0d935cd01b8e3cffaafcfc23de716aae9).
Its selected-rendition local origin generates parts for hls.js, with
headroom-aware rate control and per-channel cushion adaptation. Its current
settings enable the parts engine by default, despite older comments calling it
opt-in. Its latency targets are not independently measured tvOS results.

StreamNook's license is **PolyForm Noncommercial with additional permissions**,
not MIT/BSD-style unrestricted reuse. Do not copy or translate its engine and
relabel the result as MIT. Streamlink is BSD-2-Clause; hls.js is Apache-2.0;
reusing their code would still require preserving applicable notices and terms.
This prototype copies no StreamNook implementation. It uses the HLS/MP4 protocol
structures. The successful CMAF path does not remux or re-encode video. The older
TS comparison uses local FFmpeg as an external experimental tool, not as a
new bundled app dependency.

References:
[Apple LL-HLS](https://developer.apple.com/documentation/http-live-streaming/enabling-low-latency-http-live-streaming-hls),
[LL-HLS server profile](https://www.ietf.org/archive/id/draft-pantos-hls-rfc8216bis-19.html#appendix-B.1),
[StreamNook license](https://github.com/StreamNook/StreamNook/blob/76b81ca0d935cd01b8e3cffaafcfc23de716aae9/LICENSE),
[Streamlink Twitch plugin](https://github.com/streamlink/streamlink/blob/master/src/streamlink/plugins/twitch.py).

## Open questions (NOT yet confirmed — under investigation)

These are hypotheses. Do not treat them as fact until the Diagnostics overlay
(or another reproducible measurement) confirms them.

- **Remaining freezes.** Still observed occasionally. Exact trigger not yet
  pinned down. Candidate factors: forward buffer depth, a pinned rendition
  whose bitrate the connection can't sustain, or proxy refresh timing. The new
  buffer-agnostic frozen-playhead failsafe (see Recovery behavior) targets the
  specific `toMinimizeStalls` + `Reloads: 0` variant of this, but is **unproven**
  — it may not be the same freeze, and it hasn't been caught in the act yet.
- **"Jumps."** Candidate causes, not yet separated:
  1. AVPlayer's own skip-to-live after the buffer dips (native behavior).
  2. The watchdog reload (confirmed mechanism; magnitude/frequency TBD).
  3. A pinned rendition stalling then re-snapping.
  4. The proxy's `#EXTINF` duration heuristic: prefetch tags carry no duration,
     so the proxy synthesizes one. It now uses the **average** of the real
     segment durations (matching Streamlink) rather than just the previous
     segment, which is steadier near boundaries. Residual timeline drift from
     this estimate is still possible but less likely; unproven.
- **Are streams actually delivered at the selected resolution?** The Diagnostics
  overlay now shows the real rendered size (`presentationSize`) and the
  indicated bitrate, so this can finally be checked per stream instead of
  guessed.
- **Does the predictive instability detector survive a mid-roll ad transition?**
  Twitch's mid-roll ads splice via `#EXT-X-DISCONTINUITY` and can briefly perturb
  the manifest (discontinuity markers, occasionally off-cadence ad segments)
  without the *broadcaster's* encoder being unhealthy. The discontinuity score is
  capped (`discontinuityScoreCap = 1.5`, below the 3.0 trip threshold) precisely
  so an ad break can't trip the predictor on its own, and `testDiscontinuities`
  `AloneDoNotFalseTrip` covers the synthetic case — but this must be **confirmed
  on-device against a real mid-roll ad** to be sure the splice doesn't also throw
  enough irregular-`#EXTINF` or stalled-sequence points to clear the threshold
  alongside the discontinuities. Watch the overlay `Predict:` score across an ad
  to verify it stays under 3.0.

## Bounded multi-source lifecycle checks

`MultiviewContinuityLiveTests` separately exercises two to four simultaneous
native panes, expansion into normal controls/chat, and return. It checks the
identities of every AVPlayer, AVPlayerItem, and AVKit rendering controller as
well as advancing video samples during the transition. Hidden panes stay live
with lower adaptive quality preferences; attachments record their actual
resolution and encoded-media cache use, since preferences are not hard limits.
`STROZZ_MULTIVIEW_HOLD_SECONDS` can extend the expanded hold from 5 to 300 seconds.
The separate, explicit physical check accepts only channels in the on-device
live Following list and keeps its first stream as the sole audible pane.
Remote interaction tests use the separate `StrozzUI` scheme with
`STROZZ_MULTIVIEW_UI_TESTS=1` and selected `STROZZ_MATRIX_CHANNELS`. They verify
normal control navigation, the native quality menu, Back, and reactivation of
the same returned pane rather than relying on accessibility-container focus
flags alone. The remote regression starts from the second pane so a fallback
to the first tile cannot accidentally pass. The wall's native focus scope
prefers the remembered tile as buttons re-enter during collapse, before the
animation-completion focus request.

`MultiviewFocusRenderingTests` hosts the actual pane hit target over a known
four-color picture, gives its native Button focus, and checks the picture's
pixels across all four themes with transparency enabled/disabled. The pane uses
the shared content-only player button style: tvOS's `.plain` style can still
paint an opaque focus platter even with `.focusEffectDisabled()`. The separate
tile border remains the focus indicator. Decoded-frame continuity alone cannot
detect UI that obscures the video.

`PlayerChatLayoutTests` uses direct stream entry (not multiview expansion) and
checks the real video, chat, timeline, and collapse-button frames in Side,
Overlay, and Glass at 460- and 820-point chat widths. Enable
`STROZZ_PLAYER_LAYOUT_TESTS=1` with a live `STROZZ_MATRIX_CHANNELS` login in the
`StrozzUI` scheme. Only the shared video/chat container ignores the screen safe
area: separate child overrides let chat and controls disagree about the right
edge on direct entry. Side chat reserves video space; floating chat reserves
control space without shrinking the underlying video.

The TV header's viewer counts, numeric latency, and uptime inherit one
`.footnote.weight(.semibold)` style with monospaced digits. The numeric latency
is the difference between the native published live edge and the displayed
media date, including the normal live cushion; it is not the chat-sync
extra-delay estimate (which deliberately removes that cushion). Unknown or
discontinuous date mappings clear the value until verified again. The existing
readout toggle and control show/hide behavior are unchanged. The direct-entry
UI regression checks numeric content, matching text heights, chat clearance,
and disappearance together with the controls.

TV and mobile card previews share `NativeLivePreview`, including native startup,
bounded source refresh/fallback, video readiness, and teardown. Previews remain
muted and cannot initiate external playback.

### Adaptive rendition timeline regressions

An October 8 Kyle direct/native crossover reproduced a native-only downshift
freeze: direct HLS rendered all 165 post-startup samples, while native rendered
116 (117 on repeat). The playhead stayed near 72 seconds while the new
rendition's buffered range restarted near 30 seconds. Media kept arriving
quickly, but its rebased timeline did not reach the playhead for about 43 seconds.

The native origin now retains completed-segment metadata from the existing
optional rendition-report requests. A cold rendition keeps the earlier playlist
prefix instead of taking only the newest upstream sliding window, without
downloading or decoding unused video. Retention follows the existing history
and count bounds, drops media payloads, and never bridges a missing sequence
window. Restarting an inactive indexer clears its obsolete `reachedLiveEdge`
flag so an initial reload cannot immediately return its old edge as current
live. Active playlists still never wait on optional report work; hold-back and
forward-buffer targets are unchanged.

Before publishing an adaptive master, a coalesced initial manifest pass now
establishes one stable maximum target duration across its video renditions.
This follows rule 8.2 of Apple's
[HLS authoring specification](https://developer.apple.com/documentation/http-live-streaming/hls-authoring-specification-for-apple-devices).
Previously, Source and transcodes could advertise different targets (for
example 2 and 6 seconds). The initial metadata also supplies their timeline
prefixes. Initial playlist coverage, partial-segment retention, and media-cache
retention use the common advertised duration; this does not change
`PART-HOLD-BACK` or AVPlayer's forward-buffer preference. Initial preparation
must complete before the master is exposed, while subsequent optional report
refreshes remain off the active request path.

Unused rendition indexers now expire based on actual media demand, not
playlist probes. The existing eight-second grace period is unchanged, but
AVPlayer's metadata polling can no longer keep an obsolete rendition downloading
and indexing indefinitely alongside the displayed one. Diagnostics record
standalone/grid/expanded presentation, the requested bitrate/resolution budget,
and opt-in per-rendition timeline state without retaining signed URLs.

Two deterministic regressions reproduce both defects with the old behavior:
the cold indexer's first sequence incorrectly moves from 0 to 20, and the
dormant indexer immediately serves its stale edge. Both pass with the correction.
Kyle's corrected live crossover rendered 165/165 post-startup samples with at
most about one second of source-age variation, rather than hiding a timeline
rebase behind advancing frames.

The simulator-only
`NativeSourceDecodingLiveTests/testOptInAdaptiveRenditionTransitions` accepts
`STROZZ_ADAPTIVE_SWITCH_COMPARISON=1` and `STROZZ_DECODE_CHANNEL`. It compares
180 seconds each of direct/native playback sequentially and muted, changes
the same item's rendition preferences at 45/90/135 seconds, and requires real
resolution changes, fresh frames, and stable playback-date mapping.
`STROZZ_ADAPTIVE_SWITCH_NATIVE_ONLY=1` narrows a previously established failure.
`testOptInGridToExpandedAutoStaysAtSustainableQuality` with
`STROZZ_AUTO_EXPANSION_COMPARISON=1` separately releases the grid budget after
30 seconds and checks for repeated quality oscillation over 240 seconds.
Long multiview holds also check selected-pane frames and settled quality changes,
not only object identity and hidden-player clocks. Stability requires reaching
the stream's highest advertised resolution within 30 seconds, then no further
quality drops in the unthrottled run. A monotonic startup promotion is not
counted as oscillation. The earlier failing captured run still violates this
requirement (Buddha reached 1080p at 37 seconds); the corrected longer capture
reached it at 23 seconds with no later drops.

These checks have limits. Buddha's single-decoder expansion passed with both the
old and corrected timeline behavior, so it did not reproduce the physical TV's
roughly six-second quality cycling. The corrected real-player two-pane test on
tvOS 26.5 passed 90-second expanded holds, frame/quality checks, and retained
player/item/surface identity. On tvOS 27 Simulator, a hidden 360p pane instead
needed Source decode recovery, breaking item continuity, followed by a crash in
CoreMedia's logging path. AnthonyZ low-rendition decoding failed with both direct
and native AVPlayer on that runtime; that is not a test of twitch.tv and does
not explain away the user's website-versus-app comparison. Physical Auto
oscillation remains a separate symptom to verify, not a claimed universal cure.
The final four-pane 180-second holds retained every player/item/surface and
recorded 180/180 fresh samples for both expanded streams. Buddha held 1080p
after its initial promotion; Blau held 1080p throughout. The original runner
marked that capture failed because its old assertion counted four startup
quality changes, including promotions; the original failed bundle is retained.
The replacement assertions check the actual high-quality deadline and
subsequent downshifts against those recorded samples. Forced low-rendition
AnthonyZ checks still fail on tvOS 26.5 as well as 27, including direct
AVPlayer comparison; neither common target duration nor an experimental TS
initialization override eliminated that failure. The TS override and a
diagnostic-output-rebinding experiment were discarded, not shipped.

`NativeStreamMatrixLiveTests` is an opt-in, simulator-only test for comparing
real live sources without taking over a physical Apple TV. Set
`STROZZ_STREAM_MATRIX=1` and `STROZZ_MATRIX_CHANNELS` to one to ten comma-separated
live logins in the test-runner environment. Sources run sequentially with one
muted playback instance, not ten simultaneous decoders.
For longer soaks, `STROZZ_MATRIX_STEADY_SECONDS` accepts 180–1800 seconds and
`STROZZ_MATRIX_RESUMED_SECONDS` accepts 45–900 seconds. Increase the XCTest and
outer supervisor deadlines to cover every selected source, including startup
and position restoration, rather than interpreting a truncated run as a failure
of the player.

Each source must produce decoded video in AVKit, sustain three minutes of
playback, return through simulated background/interruption handlers without an
interruption-ended notification, play another 45 seconds, and preserve a
deliberately paused position across a second return. Per-source JSON attachments
retain quality, buffer, source-age,
prefetch/hold-back, frame progress, and recovery timing. A failed source remains
a failure while later sources still get exercised; completion is not a claim
that every assertion passed. Offline sources, native fallback, player errors,
item replacements, and startup timeouts have distinct failure labels, with
terminal source state retained in the attachment. They are not silently
substituted with another broadcaster. These in-process lifecycle checks do not
prove behavior during actual OS suspension or audible output.
Frame checks require a new pixel buffer with an advancing presentation timestamp,
not just a non-null buffer. Separate request attachments retain redacted AVPlayer
errors and resource timing; opt-in Debug origin traces capture generated local
playlist/part requests around a stall, without storing signed upstream URLs.

`NativeSourceDecodingLiveTests` compares direct Twitch HLS with the native engine
sequentially on the same simulator. Enable `STROZZ_DECODE_COMPARISON=1`, select
`STROZZ_DECODE_CHANNEL`, and optionally set `STROZZ_DECODE_QUALITY` to `Source`
or an available quality name. Both modes must render verified frames; an
advancing clock with a blank AVKit surface fails the comparison.
Physical comparison is a separate opt-in test, requires explicit channel and
quality selection, and stays muted unless `STROZZ_PHYSICAL_TEST_AUDIO=audible`.
Run it only with the viewer's permission: it takes over the app surface.

Use a currently live mix of MPEG-TS and CMAF, with and without upstream prefetch.
A broadcaster's language or name is not evidence of their ingest region or
the CDN route chosen for this client. Keep compilation jobs limited, watch host
CPU/thermal/memory pressure, and stop only the owned test lane and simulator if
the machine comes under pressure. Do not interpret a resource-aborted run or
advancing clock without video frames as passing playback.
Limit both Xcode build jobs and Swift-driver jobs; `-jobs 2` alone does not
necessarily bound the Swift compiler's workers. A guarded run may be incomplete
even when memory pressure stays normal, because sustained CPU saturation is
also a reason to stop.

### October 7, 2026 simulator sample

On the tvOS 27 simulator, Squeex, ESLCS, Elxokas, Burn, Gaules, Kamet0, and xQc
completed the measured scenarios: each returned 180/180 steady and 45/45 resumed
decoded-frame samples, zero waiting samples, no sub-480p collapse, and paused
restoration error below one millisecond. Gaules adapted between 720p and 1080p;
this is not evidence that Auto should lock to a resolution.

Shroud fell back with `NativeHLSError.unsupported` about 97 seconds after opening.
The narrower retry found the channel offline, confirmed by the live-status
lookup, so it could not reproduce or clear the original format failure. The
specific unsupported input remains unidentified. The original eight-source run
was interrupted during xQc when its resource-monitor command timed out; xQc
completed in the subsequent two-source run. Both aggregate XCTest runs remain
failed, rather than being presented as a clean eight-source pass.

Only one muted simulator decoder ran at a time, with two compiler jobs.
Memory pressure remained normal; the completed retry's lowest sampled CPU idle
was 17.81%. The owned simulator was shut down afterward. No physical TV was
manipulated. This bounded sample does not establish long-session reliability,
mobile UI parity, or a fix for active playback waiting after its buffer refills.

### October 8, 2026 reliability follow-up

The subsequent eight-channel run passed on TheBurntPeanut, rivers_gg, alanzoka,
agurin, and stylishnoob4, but failed on GronkhTV after return, Nico_la during
video startup, and matsuri_hs during steady playback. Those failures remain in
the original results; later passes do not erase them.

Two native-engine defects were isolated with failing deterministic regressions:
50fps TS parts could be 380ms despite the 382.5ms minimum, and a cold rendition
with requested parts already cached still waited to reach live before serving
them. The corrected parser and cached-request regression pass. A separate shared
buffer-recovery policy covers the observed refilled-buffer deadlock, including
one-shot resume, timeout escalation, and pause/invalid-buffer exclusions.

Nico_la's original 1080p50 rendition then rendered 45/45 measured frames in both
direct and native AVKit playback. The final shared mobile checks passed 27/27,
including live xQc, audio-reset, quality, and paused-return scenarios. The
corrected-engine xQc soak rendered 900/900 distinct steady-playback frames with
zero waiting samples; its aggregate test still failed after return when a 720p
rendition stopped producing verified video and Source recovery replaced the
item. A fixed-720p direct Twitch comparison also failed on the tvOS 27 simulator,
so that failure is not isolated to the native engine. A stable-runtime direct
comparison additionally encountered an upstream HTTP 500 and is inconclusive.

With explicit viewer permission, Anthonyz was checked on physical Apple TV at
720p60, with audio and no system-volume change. Both direct and native playback
rendered 45/45 measured frames without AVPlayer errors. Build 1938, with Production
CloudKit preserved, then returned to normal native 1080p60 Anthonyz playback.
This verifies that hardware path, not every broadcaster or an unlimited soak.
Further simulator runs stopped on sustained host CPU pressure; those runs are
incomplete. A narrowed Shroud retry then confirmed the channel offline rather
than reproducing its format event. The original GronkhTV CoreMedia error and Shroud format fallback
have not been isolated to reproducible input. There is no all-streams,
long-duration "rock solid" claim.

Reusable upstream sessions subsequently passed 41 TV checks and 31 mobile
checks, including live playback and cancellation isolation. All five reader
lifecycle regressions passed, including overlapping-request rejection. A longer
GronkhTV run recorded no stall/retry event over approximately 17 minutes before
host CPU pressure stopped the lane during return-from-background coverage.
That run is incomplete; its xQc portion never started.

## Diagnostics overlay (how to gather data)

Player → open chat settings (`slider.horizontal.3`) → **Playback**. Turn on the
**Diagnostics Overlay** toggle; doing so also reveals the advanced **Prefetch
Proxy** kill-switch and the simulate-event buttons. With Diagnostics on, the
player shows a panel (while controls are visible) reporting, all measured live
from the current item:

- **Mode** — proxy on/off and whether quality is Auto/adaptive or pinned. When
  the predictive detector is still watching a live stream this row is followed by
  a `Predict:` line (running score / threshold, refreshes seen, latest reason);
  once stability mode latches, the `STABILITY MODE` line is tagged `[predictive]`
  or `[observed]` to show which trigger fired.
- **Render** — actual decoded video size (`presentationSize`) and playback rate.
  This is the ground truth for "is it really 1080p".
- **Bitrate** — indicated (the rendition ABR chose) vs observed (measured
  throughput), from the access log.
- **Dropped frames / AVStalls** — AVPlayer's own access-log counters.
- **Buffer ahead** — seconds buffered past the playhead.
- **Edge gap / Encoder** — the two latency numbers described above.
- **Stalls / Jumps / Reloads** — running counts for this viewing session.
- **Event log** — the most recent stalls/jumps/reloads with "Ns ago" timing.

Counters reset when a new channel session starts (initial load or following a
raid). They intentionally persist across a watchdog reload so the reload is
visible.

How jumps are detected: each second we compare actual playhead advance against
wall-clock × rate. Unexplained forward movement ≥ 2.0s is logged as a forward
jump; backward movement ≥ 1.0s as a back jump. Normal catch-up (≤1.12x) stays
well under these thresholds.

### When reporting a freeze or jump

Note the **event log line** (e.g. `jump +6.4s forward (3s ago)`), plus the
**Render size**, **indicated bitrate**, **buffer ahead**, and whether you were
on **Auto** or a **pinned** quality at the time. That combination is what lets
us tell these causes apart and move them from "Open questions" to "Established
facts."
