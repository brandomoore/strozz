import SwiftUI

struct BroadcastUptimeView: View {
  let startedAt: Date?

  var body: some View {
    if let startedAt {
      TimelineView(.periodic(from: .now, by: 60)) { context in
        if let duration = BroadcastUptime.duration(since: startedAt, now: context.date) {
          Text("Streaming for \(duration, format: .units(allowed: [.hours, .minutes], width: .narrow))")
            .monospacedDigit()
            .accessibilityIdentifier("broadcast-uptime")
        }
      }
    }
  }
}
