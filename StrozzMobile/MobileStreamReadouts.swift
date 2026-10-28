import SwiftUI

struct MobileStreamReadouts: View {
  let state: LivePlaybackPosition.State
  let startedAt: Date?
  let viewerCount: Int?
  let showDuration: Bool
  var viewerCounts: [PlatformViewerCount] = []
  let onGoLive: () -> Void
  @Environment(\.themePalette) private var palette

  var body: some View {
    ViewThatFits(in: .horizontal) {
      HStack(spacing: 14) { viewerReadout; liveReadout }
      VStack(alignment: .leading, spacing: 6) { viewerReadout; liveReadout }
    }
    .font(.subheadline)
    .monospacedDigit()
    .lineLimit(1)
    .minimumScaleFactor(0.75)
    .foregroundStyle(palette.videoControlForeground)
  }

  private var liveReadout: some View {
    MobileLiveReadout(state: state, startedAt: showDuration ? startedAt : nil, onGoLive: onGoLive)
      .fixedSize(horizontal: true, vertical: false)
  }

  @ViewBuilder
  private var viewerReadout: some View {
      if !viewerCounts.isEmpty {
        ViewThatFits(in: .horizontal) {
          HStack(spacing: 8) { platformBadges }.fixedSize(horizontal: true, vertical: false)
          VStack(alignment: .leading, spacing: 4) { platformBadges }
        }
        .font(.caption)
        .accessibilityIdentifier("mobile-viewer-readout")
      } else if let viewerCount {
        HStack(spacing: 4) {
          Icon(glyph: .user, size: 18).accessibilityHidden(true)
          Text(viewerCount, format: .number.notation(.compactName))
        }
        .padding(.vertical, 5)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("\(viewerCount, format: .number) viewers"))
        .accessibilityIdentifier("mobile-viewer-readout")
      }
  }

  private var platformBadges: some View {
    ForEach(viewerCounts) { value in
      HStack(spacing: 3) {
        Icon(glyph: glyph(value.platform), size: 16).accessibilityHidden(true)
        Text(value.count, format: .number.notation(.compactName))
      }
      .accessibilityElement(children: .ignore)
      .accessibilityLabel("\(value.platform.rawValue) \(value.count) viewers")
    }
  }

  private func glyph(_ platform: PlatformViewerCount.Platform) -> Glyph {
    switch platform {
    case .twitch: .brandTwitch
    case .kick: .brandKick
    case .youtube: .brandYoutube
    }
  }
}

private struct MobileLiveReadout: View {
  let state: LivePlaybackPosition.State
  let startedAt: Date?
  let onGoLive: () -> Void
  @Environment(\.themePalette) private var palette

  var body: some View {
    switch state {
    case .live:
      HStack(spacing: 4) {
        Circle().fill(palette.liveIndicator).frame(width: 7, height: 7).accessibilityHidden(true)
        if let startedAt {
          TimelineView(.periodic(from: .now, by: 1)) { context in
            let elapsed = context.date.timeIntervalSince(startedAt)
            if elapsed.isFinite, elapsed >= 0 {
              Text(Duration.seconds(elapsed), format: .time(pattern: .hourMinuteSecond(padHourToLength: 2)))
                .accessibilityLabel(Text("Live, streaming for \(Duration.seconds(elapsed), format: .units(allowed: [.hours, .minutes], width: .wide))"))
                .accessibilityIdentifier("mobile-stream-uptime")
            } else {
              Text("Live")
            }
          }
        } else {
          Text("Live")
        }
      }
      .padding(.vertical, 5)
      .accessibilityElement(children: .contain)
      .accessibilityIdentifier("mobile-live-status")
    case .checking:
      Text("Checking live")
        .padding(.vertical, 5)
        .accessibilityIdentifier("mobile-live-checking")
    case .paused, .behind:
      Button(action: onGoLive) {
        HStack(spacing: 5) {
          if case .behind(let seconds) = state {
            Text("\(seconds, format: .number.precision(.fractionLength(0)))s behind")
              .accessibilityIdentifier("mobile-live-delay")
          } else {
            Text("Paused").accessibilityIdentifier("mobile-live-paused")
          }
          Icon(glyph: .playerPlayFilled, size: 14).accessibilityHidden(true)
        }
        .padding(.horizontal, 10)
        .frame(minHeight: 44)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .modifier(MobilePlayerButtonSurface())
      .accessibilityLabel("Back to live")
      .accessibilityValue(recoveryStatus)
      .accessibilityHint("Resume at the live edge")
      .accessibilityIdentifier("mobile-go-live")
    }
  }

  private var recoveryStatus: Text {
    if case .behind(let seconds) = state {
      Text("\(seconds, format: .number.precision(.fractionLength(0)))s behind")
    } else {
      Text("Paused")
    }
  }
}
