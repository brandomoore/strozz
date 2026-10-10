import SwiftUI

struct MobileStreamReadouts: View {
  let state: LivePlaybackPosition.State
  let startedAt: Date?
  let viewerCount: Int?
  let showDuration: Bool
  let onGoLive: () -> Void
  @Environment(\.themePalette) private var palette

  var body: some View {
    HStack(spacing: 14) {
      if let viewerCount {
        HStack(spacing: 4) {
          Icon(glyph: .user, size: 18).accessibilityHidden(true)
          Text(viewerCount, format: .number.notation(.compactName))
        }
        .padding(.vertical, 5)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("\(viewerCount, format: .number) viewers"))
        .accessibilityIdentifier("mobile-viewer-readout")
      }
      MobileLiveReadout(state: state, startedAt: showDuration ? startedAt : nil, onGoLive: onGoLive)
    }
    .font(.subheadline)
    .monospacedDigit()
    .lineLimit(1)
    .minimumScaleFactor(0.75)
    .foregroundStyle(palette.videoControlForeground)
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
        .frame(minHeight: 44)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
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
