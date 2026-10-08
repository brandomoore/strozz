import SwiftUI

struct BroadcastUptimeView: View {
  let startedAt: Date?
  var iconSize: CGFloat = 16

  var body: some View {
    if let startedAt {
      TimelineView(.periodic(from: .now, by: 60)) { context in
        if let duration = BroadcastUptime.duration(since: startedAt, now: context.date) {
          HStack(spacing: 8) {
            Icon(glyph: .clock, size: iconSize)
            Text(duration, format: .units(allowed: [.hours, .minutes], width: .narrow))
              .monospacedDigit()
          }
          .accessibilityElement(children: .ignore)
          .accessibilityLabel(Text("Streaming for \(duration, format: .units(allowed: [.hours, .minutes], width: .narrow))"))
          .accessibilityIdentifier("broadcast-uptime")
        }
      }
    }
  }
}
