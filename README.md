<p align="center">
  <img src="Branding/strozz_logo.svg" alt="Strozz logo" width="128" />
</p>

<h1 align="center">Strozz</h1>

<p align="center">
  Your streams, together on Apple TV — Twitch, YouTube, and Kick simulcasts, with chat and native emotes.
</p>

<p align="center">
  <a href="LICENSE"><img src="https://img.shields.io/badge/License-MIT-blue.svg" alt="License: MIT" /></a>
  <a href="https://www.apple.com/apple-tv-4k/"><img src="https://img.shields.io/badge/Platform-tvOS-black.svg?logo=apple" alt="Platform: tvOS" /></a>
  <a href="https://github.com/sponsors/thatcube"><img src="https://img.shields.io/badge/Donate-%E2%9D%A4-db61a2?logo=githubsponsors&logoColor=white" alt="Donate" /></a>
</p>

Strozz brings live streams and chat together on the big screen. Watch Twitch and
YouTube, follow supported creators across their YouTube and Kick simulcasts, or
watch several channels in multi-view. It's built for the Apple TV remote and the
tvOS focus engine — not a stretched phone app — with native 7TV, BTTV, and FFZ
emotes. It's free and open source.

An initial **iPhone and iPad app (iOS 18+)** is also available to build from the
`StrozzMobile` scheme. It shares the Twitch streaming, account, and chat services,
with a separate touch interface rather than the TV's remote controls.

## Features

The feature list below describes the Apple TV app. See
[iPhone and iPad](#iphone-and-ipad) for the smaller mobile feature set.

### Watch

- **Chat beside the video.** Live streams play with the video on the left and a
  chat pane on the right, so you never have to choose between watching and
  reading along.
- **Low latency by default.** A low-latency mode closes most of the gap to the
  live edge, so you're not minutes behind the moment. Healthy playback that
  drifts behind uses a held 1.05x catch-up rate, without an automatic seek/reload
  or repeated speed changes as the segment buffer fluctuates.
- **Rewind live.** Seek back within the live window (DVR) to catch what you
  missed without leaving the stream.
- **Pick your quality.** Choose Auto or an explicit resolution, ordered
  highest-to-lowest, and Strozz remembers your choice.
- **Audio-only mode.** Drop to audio with a reactive visualizer — handy for
  music streams, Just Chatting, or background listening.
- **Sleep timer.** Set a timer or "end of stream," with a gentle "still
  watching?" check, a starry sleeping screen, and one press to snap back to the
  live edge.
- **VODs and clips.** Watch past broadcasts and top clips from channel pages;
  VODs include synced chat replay and variable speed (0.5×–2×).
- **Multi-view.** Watch several live channels at once, picked from your follows
  and recommendations.
- **Live captions (beta).** Optional on-device captions for streams, with size,
  position, and styling controls.

### Chat

- **Third-party emotes, built in.** 7TV, BTTV, and FFZ emotes (global and
  channel, including animated ones) render right alongside Twitch's native, sub,
  and channel emotes.
- **Badges and bits.** Global and channel badges plus cheermotes are shown just
  like they are on the web.
- **Read anonymously, or chat when signed in.** Chat connects anonymously by
  default and auto-reconnects; sign in to send messages.
- **Replay keeps up with live recordings.** After a deep rewind, chat replay
  checks for newly archived comments rather than stopping at the current last page.
- **Make chat yours.** Adjust text and emote size, font (including
  OpenDyslexic), spacing, width, and layout — side, overlay, or glass.
- **Live moments surfaced.** Polls, predictions, hype trains, creator goals, and
  incoming/outgoing raids appear as calm, display-only overlays.
- **Simulcast chat merge (experimental).** When a streamer you're watching is
  also live on YouTube or Kick, their chats can be merged into a single pane.
  When YouTube chat connects, the player can show its live viewer count even
  if the streamer is not in the shared YouTube alias catalog.

### Discover

- **Home built around your follows.** See the channels you follow that are live
  now, plus recommendations.
- **Recommendations you control.** Optional personalized picks built from
  on-device watch history and your followed categories — or anonymous trending
  when you're signed out or have it turned off.
- **Browse and search.** Explore top categories and their live streams, and
  search channels and categories with live results.
- **Channel pages.** Top clips, past broadcasts, and similar channels for every
  channel.
- **Top Shelf.** Your live follows and recommendations surface on the tvOS home
  screen above the app icon.
- **YouTube, too.** Connect a YouTube account to see your subscribed streamers
  who are live and watch YouTube-only streams; streamers live on both platforms
  show up as one combined card.

### Make it comfortable

- **Themes.** System, Dark, OLED, and Light.
- **Night Shift.** An optional warm screen wash that eases in after sunset on a
  solar or manual schedule.
- **Tune the grid.** Adjustable stream-card sizes and a stream-language filter.

## Getting started

Strozz is an early, non-commercial project and isn't on the App Store. To run it
you'll build it yourself from source with Xcode and your own Twitch developer
`client_id`. See **[CONTRIBUTING.md](CONTRIBUTING.md)** for the full setup.

You'll want:

- An Apple TV running **tvOS 18 or newer** (live playback and Top Shelf need
  real hardware).
- A Twitch account, if you want to sign in — browsing and anonymous chat work
  without one.

## Reporting bugs & requesting features

Found a bug or have an idea? Please open a
[GitHub issue](https://github.com/brandomoore/strozz/issues). Including your Apple TV
model, tvOS version, and the stream where something went wrong helps a lot. See
**[CONTRIBUTING.md](CONTRIBUTING.md)** for details.

## iPhone and iPad

The mobile version includes personalized Twitch recommendations, a full followed
channel directory, channel profiles, past broadcasts with local resume, category
browsing, search, native low-latency live playback, standard Auto
and fixed qualities (including audio-only), and live chat with Twitch/7TV/BTTV/FFZ
emotes. Sign in through **Account > Sign in to Twitch**, open the Twitch link,
approve the displayed code, then return to Strozz. Browsing, playback, and
reading chat also work anonymously.

Selecting a fixed video quality retains the native engine when native playback
is selected, on both TV and mobile. Explicit standard playback, Audio Only, and
AirPlay retain their standard paths; a genuine unsupported-format fallback is
still reported rather than disguised as native playback.

Home automatically previews one mostly visible stream at a time, nearest the
middle of the screen. A small, leading-aligned heading scrolls with the feed
instead of occupying a fixed navigation bar. Previews are always muted and stop when you scroll away,
switch tabs, open a stream, or background the app. Lower-bandwidth preview
renditions are preferred; an undecodable preview gets one Source-quality retry.
Home defaults to **For you**: live followed and most-watched channels lead the
feed, followed by personalized discovery from the shared recommendation engine.
Watch frequency on this device ranks familiar channels; global popular streams
are only the signed-out/no-history or personalization-disabled feed.
**Following** is a flat list of every followed channel, including offline ones.
Tap an offline channel to open its profile and past broadcasts; long-press any
followed row for its profile or a saved broadcast's Continue option.
**Home, Browse, and Account** remain in the bottom bar. Home also shows up to six
compact live-followed shortcuts. Large stream thumbnails show a red-dot **Live** badge at top-right,
viewer counts at bottom-left, and the muted
preview indicator at bottom-right. Compact Following thumbnails combine a red
live dot and viewer count in one small badge, without a separate LIVE pill.
Anonymous/demo recommendations are
never presented as personal follows.
The category rail scrolls to the screen edges, and the feed draws behind the
floating tab bar while leaving enough end-of-feed clearance to reach the last card.
For you / Following pins below the status bar as you scroll; the Strozz heading and
category filters scroll away.

Past broadcasts use native on-demand controls with seeking. **Continue watching**
on Home and channel profiles resumes saved progress; finished broadcasts leave
that list. Watch history and resume positions stay on this device, are separated
by signed-in account, and do not import Twitch's or the Apple TV's watch history.
Account provides a personalization toggle and a confirmed history/progress reset.
Signed-out/demo streams never masquerade as followed channels.

Video sits above chat on a portrait iPhone; landscape iPhone shows video alone.
A wide iPad window places chat beside video, while narrow multitasking windows
stack them. Dedicated over-video controls provide play/pause, mute, quality,
**Back to live** (return from paused/delayed playback), fullscreen/rotation,
chat visibility, sharing the Twitch link, and Apple's AirPlay picker. Rendering
still uses AVKit. Controls hide after inactivity and reappear on tap; they stay
available when paused or using VoiceOver. AirPlay switches native low latency
to standard playback because a receiver cannot access the app's loopback
media server; keep the app open while using it. System,
Dark, OLED, and Light appearances are available in Account, and chat follows
Dynamic Type and Reduce Motion. App panels use opaque theme-aware surfaces.
Browse shows three categories across on iPhone (two at accessibility text sizes)
and an adaptive grid on iPad. Typing in Browse's search field switches to compact
channel and category results with artwork and viewer counts.

This is not full TV feature parity: VOD chat replay, clips, multiview, YouTube/Kick playback
and chat merging, rewards, and advanced TV settings are not included. Playback
stops in the background; Picture in Picture/background audio are not yet
supported. Returning resolves fresh stream URLs instead of reviving an expired
native engine. Paused/rewound positions are preserved when still available; an
expired position shows an error rather than silently jumping to live.
Transient native-engine failures get up to two fresh native attempts in a
rolling minute before standard fallback; unsupported formats still fail over
explicitly instead of leaving playback stuck.
If audio advances without decodable video, the mobile player makes one recovery
attempt using the primary video rendition and displays the actual selected
quality and a notice. A failed recovery shows an error instead of staying black.

Use the same Twitch client configuration described in CONTRIBUTING.md, then:

```bash
./tools/generate-project.sh
./tools/xcbuild.sh -project Strozz.xcodeproj -scheme StrozzMobile \
  -destination 'generic/platform=iOS Simulator' build
# Substitute an available iPhone or iPad simulator UUID:
./tools/xcbuild.sh -project Strozz.xcodeproj -scheme StrozzMobile \
  -destination 'platform=iOS Simulator,id=<SIMULATOR_UUID>' test
```

`StrozzMobileTests` covers playback lifecycle and layout policy;
`StrozzMobileUITests` covers navigation and themes. Set
`STROZZ_MOBILE_LIVE_TESTS=1` in the scheme's **Test** environment to opt into
bounded real-stream/frame, browse/search, quality, and rotation checks. They
connect anonymously, run muted, and never send chat messages. Set
`STROZZ_MOBILE_LIVE_CHANNEL` to a live channel for the native full-player check;
the test requires native playback rather than treating a compatibility fallback
as a native success.

Both platform targets use `com.thatcube.Strozz` in the new universal App Store
Connect record. This is a separate app from the legacy `com.thatcube.Twozz`
installation, not an in-place update. Credentials are local to each device; signing
in on the TV does not sign in the phone. The existing Fastlane lanes still ship
**tvOS only**. Adding this target does not upload or distribute an iOS build.

## Contributing & development

Build instructions, the Twitch auth setup, how playback is resolved, versioning,
and release steps all live in **[CONTRIBUTING.md](CONTRIBUTING.md)**. Notes on
the low-latency playback work are in
[`docs/low-latency.md`](docs/low-latency.md).

### Brand assets

Strozz now has its own Apple app identity: `com.thatcube.Strozz`, with
`com.thatcube.Strozz.TopShelfExtension`, App Group `group.com.thatcube.Strozz`,
and Keychain service `com.thatcube.Strozz.watch-rewards`. The new universal
App Store Connect record is `6819913170`; the legacy `com.thatcube.Twozz`
record (`6782643545`, now named **Strozz Old**) and its installed data remain
untouched.

This is a clean replacement installation. Testers install the new TestFlight
app and sign in again; local preferences, history, and saved sessions are not
automatically imported. Separate storage prevents signing out of the new app
from deleting the old app's credentials. Twitch-side follows, points, and
streaks remain attached to the Twitch account. iCloud sign-in sync is a separate
feature and is not enabled merely by changing the bundle ID.

The Xcode project, scheme, source module, assets, and repository use Strozz.
Channel links use `strozz://`; the parser also recognizes legacy `twozz://` and
`twizz://` links. With both apps installed, custom-scheme routing can be ambiguous;
use the intended app's own navigation until switching fully to the replacement.
Shared build/cleanup protocol identifiers also stay
unchanged for interoperability. Historical Git branches and commits are not
renamed or rewritten.

The diagnostics CLI defaults to the new app. To inspect a still-installed
legacy build, explicitly pass `--bundle com.thatcube.Twozz`. Keep historical
release archives and receipts associated with their original bundle ID.

`Branding/strozz_logo.svg` is the canonical Strozz mark. The in-app SVG and
transparent splash artwork use it unchanged; the layered tvOS icons and static
Top Shelf images pair it with charcoal (`#1C1C1E`) and a subtle purple radial
glow. The background follows Plozz's smooth treatment, without grain or static.

To regenerate all catalog variants while preserving their dimensions and layers:

```bash
python3 -m pip install -r tools/requirements-brand-assets.txt
python3 tools/generate_brand_assets.py
python3 -m unittest discover -s tools/tests -p 'test_brand_assets.py'
```

The iOS `MobileAppIcon` uses the same mark and opaque charcoal treatment.
Regenerate only that 1024-pixel icon with
`python3 tools/generate_brand_assets.py --mobile-only`.

### Go Live Alerts

In-app live-channel alerts are **off by default**, including after updating from
the old opt-out behavior. Strozz asks once on Home after Twitch sign-in: keep
alerts off, enable **All Channels**, or **Choose Channels** individually. You
can change this later under **Settings > Go Live Alerts**.
**Review Options** reopens the introduction without resetting your selections
or making the automatic prompt repeat.

All Channels includes current and future Twitch follows. Turning any channel off
switches to a custom selection of your current follows, with new follows off.
Turning every individual switch back on does not opt into future follows; use
Enable All for that. Search-based bulk actions affect only matching channels.
Turning alerts off also dismisses any pending alerts and clears the queue.

These settings stay on this Apple TV and affect only Strozz's in-app alerts.
Twitch's supported [Get Followed Channels API](https://dev.twitch.tv/docs/api/reference/#get-followed-channels)
does not expose notification-bell preferences, so Strozz does not sync them or
change Twitch notifications on other devices.

### YouTube live-source selection

YouTube playback requires a currently live broadcast, not just a playable HLS
playlist or the `isLiveContent` flag (which remains set on archived streams).
Channel lookups use the primary player response, never arbitrary video IDs from
uploads or recommendations. The native player response must confirm the selected
video ID and current live status before playback. If it cannot, the YouTube
source stays unavailable and Twitch remains selected; an already-selected
YouTube source uses the existing bounded retry and Twitch fallback notice.

### Playback diagnostics

Live playback lets AVPlayer buffer before starting instead of forcing an
immediate first frame. With **Prefer YouTube** enabled, Strozz gives source
selection up to four seconds before falling back to Twitch; it does not start
Twitch and then automatically interrupt it with a YouTube switch. YouTube uses
an eight-second forward-buffer preference to help absorb short delivery gaps.
Because a buffer preference cannot fetch video that has not aired yet, native
YouTube playback targets a six-second margin behind its available live edge. It does not
automatically seek away the extra headroom gained during a buffering wait. For
simulcasts, three stalls within thirty seconds trigger the existing single fresh
retry, with only two extra seconds of live-edge margin; persistent trouble then
falls back to Twitch instead of repeatedly reloading or adding more delay.
This can add initial loading time in exchange for smoother playback; it cannot
eliminate upstream or network interruptions.
The loading screen clears when AVPlayer starts playing, independently of the
longer startup-health check, so it does not cover video that's already audible.
The in-player stream title stays with the channel across source switches and
playback retries; changing channels clears it before fetching the new metadata.

Closing a live player refreshes the Home rails and the originating Following,
category, or search list. Stream-card identity follows the streamer, not the
broadcast ID or ranking, so tvOS can retain focus through live-status updates
and reordering. Return refreshes do not force focus back to the first card.

When you return to a stream, Strozz restarts its stall-detection window rather
than counting time spent in the background as a freeze. An empty buffer or
expired playlist triggers a live-status check and recovery, not a "stream ended"
verdict: that message requires Twitch to confirm the channel is offline.
Leaving while following live also preserves that intent: returning from the
background or a channel page refreshes the current source to its live position,
rather than leaving playback paused at the old point. Brief trips that remain
near live avoid an unnecessary reload. Deliberate pauses, rewinds, and VOD
positions are preserved. "LIVE" means the source's playable live position,
including its normal buffering margin, not zero broadcast/network latency.

Multiview pauses its wall when Strozz goes into the background. On return, it
re-resolves each pane's live playlist and resumes all streams without changing
the chosen grid/spotlight layout or audio selection.

Chat's timed read pause releases its frozen snapshot when the countdown ends;
collapsing chat or changing channels also resets scrolling state. The live list
follows a permanent bottom anchor as its bounded message buffer rotates. While
following live, it fully lays out a viewport-sized tail rather than relying on
lazy row-height estimates that can leave a blank panel after emotes resize.
Pausing or scrolling still exposes the full retained history.
Twitch chat checks the join handshake and sends a heartbeat every thirty seconds
after joining. A missing join acknowledgement, failed send, missing heartbeat
reply, or server reconnect request enters the existing backoff/rejoin loop
without clearing visible messages. Quiet channels do not trigger recovery just
because nobody is chatting.
When playback catches up to live, queued chat is retimed to the shorter video
delay and its release task wakes for the earliest pending message. Foreground
return also rechecks pending deadlines, so an old pre-suspension sync delay
cannot hold newer chat behind a sleeping task.

While a channel is open, its 7TV emote set is rechecked every minute, including
during VOD chat replay. Newly added emotes update messages already on screen.
Successful provider catalogs are cached separately; failed requests are retried
without discarding known emotes or caching an outage as an empty catalog.
Playback diagnostics include catalog size and pending-retry state, not emote
names or chat text.

### Twitch rewards and polls (experimental)

In **Settings > Accounts > Twitch Rewards**, connect watch rewards using
the same Twitch account as your normal Strozz login. This is a separate,
unofficial Twitch TV device-code connection: approve it on Twitch's activation
page using your phone. Strozz never asks for your password. The rewards session
is stored in a device-only Keychain item, not in preferences or the Top Shelf
shared container. Disconnecting removes the saved rewards session from the TV;
it does not sign out your normal account or revoke other Twitch sessions.

When connected, Strozz reports one minute only after observing a minute of
advancing, visible Twitch live playback. Pauses, buffering, seeking, background
time, previews, YouTube playback, and VODs do not count. In multiview, only the
selected audio pane is reported; opening the full player stops reporting the
underlying grid. Changing channels or player items starts a fresh measurement.
It does not farm unseen channels or share announcements.

The gift button in the live Twitch player opens **Polls & Rewards** without
leaving the video. View your channel-point balance, cast one free vote in the
current poll, or redeem streamer rewards, highlighted messages, and random,
chosen, or modified emote unlocks. Each redemption requires confirmation;
Strozz rechecks the current price, availability, and balance before submitting.
Bits purchases, paid poll votes, predictions, and sub-only-message redemptions
are not supported. Rewards marked **Available on Twitch** cannot be redeemed
from Strozz.

**Collect watch bonuses** is enabled with the rewards connection and can be
turned off in Accounts. It claims only Twitch-provided bonuses during observed,
advancing playback, using the same visibility and multiview rules above.
Opening the rewards menu alone never claims a bonus or spends points.
Balances and successful actions come from Twitch acknowledgements, not local
estimates. If a result is unconfirmed, check Twitch before retrying.

The player controls show the watch-streak count returned by Twitch. A missing
milestone is shown as awaiting Twitch, never as a locally invented streak.
An accepted watch report is **not** proof that Twitch credited it: eligibility
and streak updates remain Twitch's decision. The integration can stop working
if Twitch changes its private endpoints; errors are surfaced instead of
silently claiming success. Twitch TV sessions may have no scheduled expiry
(`expires_in: 0`); Strozz still validates them on first use after launch and
hourly during viewing. Expired or revoked rewards sessions require reconnecting.

Strozz keeps a bounded, local JSONL playback log in its app cache so lag reports
can be examined after the fact. Logging samples playback state about every two
seconds and records noteworthy state changes, stalls, access/error-log updates,
seeks, and recovery actions. It is diagnostic observation only; enabling it does
not change playback tuning. Samples also include chat connection/read-pause
flags, message-buffer counts, time since the last IRC frame, and reconnect
counts/reasons, current sync delay, and queued release/wake deadlines; they do
not include chat text or chat participants. Watch-rewards diagnostics record
report acknowledgements and server-returned streak counts, never access tokens
or activation codes.

Pull the retained logs from the paired Apple TV and summarize the current or
most recent session:

```bash
python3 tools/playback-diagnostics.py pull --device <device-id>
```

Select a paired Apple TV with `--device` or the `STROZZ_DEVICE_ID` environment
variable. The default bundle is `com.thatcube.Strozz`. Every pull goes into a new
UTC-stamped directory under the gitignored `playback-diagnostics/` directory:

```bash
python3 tools/playback-diagnostics.py pull \
  --device <device-id> --bundle com.thatcube.Strozz
python3 tools/playback-diagnostics.py pull --device <device-id> --session <session-uuid> --json
```

Previously pulled data can be analyzed without Xcode or a connected device:

```bash
python3 tools/playback-diagnostics.py analyze playback-diagnostics/<timestamp>
python3 tools/playback-diagnostics.py analyze <file.jsonl> --session <session-uuid>
python3 tools/playback-diagnostics.py analyze playback-diagnostics/<timestamp> --all --json
```

By default, analysis uses `latest-session.json`, or the session containing the
newest record when no manifest is available. `--all` reports retained sessions
separately; sessions are never silently combined. A copied, incomplete final
JSON line is warned about and ignored, while completed corrupt lines and unknown
schema versions fail analysis. Sequence gaps, dropped telemetry, reclaimed
rotation parts, bounded native access/error-log backlog skips, and sessions that
are still active are marked as partial evidence.

The cache retains at most eight 4 MiB files across all sessions (about 32 MiB)
and tvOS may reclaim it. It does not contain OAuth credentials, full URLs,
request headers, server IP addresses, AVPlayer session IDs, SDK localized error
prose, or error comments. Failures retain only structured evidence such as
error domain/code, AVPlayer error-log status code, and an explicit HTTP status
when AVFoundation includes one. YouTube resolution records the client/version
and sanitized failure category, never visitor context or response bodies. Public channel names and
viewing timestamps do appear. The tool reads locally and never uploads logs.

YouTube simulcasts use the native-HLS client shared with YouTube-only playback
and captions. Startup respects AVPlayer's native buffering wait; a stall
notification does not force an empty-buffer YouTube item to restart immediately.
The obsolete Android VR client and silent web-manifest fallback
are not used. A terminal media error (even when the item still reports ready),
or 20 seconds without clock progress while playback is intended, triggers one
fresh YouTube resolution. Automatic attempts are at least 10 seconds apart.
If that attempt also fails, the player refreshes the Twitch source and shows a
brief, non-focusable notice. It does not change the saved YouTube preference or
automatically switch back during that channel visit; the source picker remains
available for a deliberate retry.

Interpret summaries cautiously. Proxy timings cover playlist/master requests,
not media segment transfers; AVPlayer access-log throughput is a coarse
cumulative estimate, not an instantaneous network test. Low buffer, bitrate
differences, dropped frames, healthy-buffer waits, decode freezes, controller
interventions, and thermal state can support hypotheses but do not prove a root
cause. Rates cover the retained record window; initial cumulative values in a
partial tail are treated as baselines, so its counter deltas are lower bounds.
`recovery_completed` describes the recovery task returning
(`load_returned`, `load_failed`, or `offline`); later clock/frame progress is the
health evidence. `first_clock_progress` confirms clock movement.
Stall notifications and AVPlayer's reset-aware stall counter are reported
separately from clock-classified episodes, not added together. Repeated short
hiccups can fall below the four-second clock threshold, so zero classified
episodes does not mean playback was uninterrupted.
`first_video_output_frame` is currently native-Twitch-only, may be up to one
watchdog interval late, and records an observed pixel buffer rather than proof
that a picture was rendered on screen. A seek callback arriving after the
15-second `seek_deadline_exceeded` event confirms only that the target callback
landed, not that a picture rendered. The proxy's last failure status, error code,
and monotonic uptime remain in samples after a later success so the failure is
not mistaken for the latest request.

## Donate

Strozz is free and open source, and it always will be. There's no paywall, no
ads, and no obligation to give anything.

If the app has been useful to you and you'd like to chip in toward its upkeep —
things like the Apple Developer Program fee and time spent maintaining it —
donations are welcome and genuinely appreciated. Anything is plenty, and not
donating is completely fine too.

**[Donate via GitHub Sponsors](https://github.com/sponsors/thatcube)** — one-time
or recurring, whatever suits you.

## Credits

Strozz is an unofficial, non-commercial Twitch client. It is **not affiliated
with, endorsed by, or sponsored by** Twitch Interactive, Inc. or Amazon. Twitch
is a trademark of its owner.

Third-party emote support is provided through the public [7TV](https://7tv.app),
[BetterTTV](https://betterttv.com), and [FrankerFaceZ](https://www.frankerfacez.com)
services, and belongs to them.

## License

[MIT](LICENSE) © 2026 thatcube

<!-- app-family:start -->
<!-- Generated by https://github.com/thatcube/brando — edit apps.json there, not this block. -->

---

<p align="center"><b>More open source</b></p>

<p align="center">
  <a href="https://github.com/thatcube/hozz" title="Hozz — Apple Health, exported to storage you own"><picture><source media="(prefers-color-scheme: dark)" srcset="https://raw.githubusercontent.com/thatcube/brando/main/logos/lockups/hozz-dark.svg" /><img src="https://raw.githubusercontent.com/thatcube/brando/main/logos/lockups/hozz-light.svg" height="40" alt="Hozz" /></picture></a>
  &nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;
  <a href="https://github.com/thatcube/Mozz" title="Mozz — Your music, wherever it lives"><picture><source media="(prefers-color-scheme: dark)" srcset="https://raw.githubusercontent.com/thatcube/brando/main/logos/lockups/mozz-dark.svg" /><img src="https://raw.githubusercontent.com/thatcube/brando/main/logos/lockups/mozz-light.svg" height="40" alt="Mozz" /></picture></a>
  &nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;
  <a href="https://github.com/thatcube/Plozz" title="Plozz — Movies &amp; TV on Apple TV, iPhone &amp; iPad"><picture><source media="(prefers-color-scheme: dark)" srcset="https://raw.githubusercontent.com/thatcube/brando/main/logos/lockups/plozz-dark.svg" /><img src="https://raw.githubusercontent.com/thatcube/brando/main/logos/lockups/plozz-light.svg" height="40" alt="Plozz" /></picture></a>
  &nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;
  <a href="https://github.com/brandomoore/strozz" title="Strozz — Twitch on Apple TV, with real emotes"><picture><source media="(prefers-color-scheme: dark)" srcset="https://raw.githubusercontent.com/thatcube/brando/main/logos/lockups/strozz-dark.svg" /><img src="https://raw.githubusercontent.com/thatcube/brando/main/logos/lockups/strozz-light.svg" height="40" alt="Strozz" /></picture></a>
</p>

<p align="center">
  <a href="https://brando.page">
    <picture>
      <source media="(prefers-color-scheme: dark)" srcset="https://raw.githubusercontent.com/thatcube/brando/main/logos/brando-white.svg" />
      <img src="https://raw.githubusercontent.com/thatcube/brando/main/logos/brando-black.svg" height="22" alt="Brandon Moore" />
    </picture>
  </a>
</p>
<!-- app-family:end -->
