# Playback architecture and troubleshooting

Current guidance for local Twitch live playback on Apple TV and iPhone/iPad.
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
- **Respect format and part contracts.** Source-CMAF requires muxed AVC/AAC-LC,
  compatible track IDs/timebases and audio configuration within a period, and no
  edit lists. Unsupported media fails explicitly, not by silently hiding a
  quality. Compatible initialization-URL rotations are not new periods.
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

TV retains JSONL under `Library/Caches/PlaybackDiagnostics`. Use the existing
tool rather than copying the full app container:

```bash
python3 tools/playback-diagnostics.py pull --device <device-id>
python3 tools/playback-diagnostics.py analyze <capture-directory> --all --json
```

`pull` accepts `--bundle`, `--output` (a new directory), `--session` and `--all`.
Default analysis follows `latest-session.json`; `--all` reports each session
separately, never combines concurrent panes. Mobile Debug writes the same
telemetry format under `Library/Caches/MobilePlaybackDiagnostics`; the TV pull
helper does not select that directory. Copy that scoped directory using
`devicectl`/Xcode, then use `analyze`.

Check build/session/time and file completeness before interpreting a capture.
If directory transfer fails, obtain the small latest-session marker and its
individual rotated log parts. A successful command or empty destination is not
proof of a complete transfer. The parser reports corrupt/partial data, sequence
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
