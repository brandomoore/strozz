import AVFoundation
import XCTest
@testable import Strozz

@MainActor
final class NativePlaybackMetricCapture {
  private var item: AVPlayerItem?
  private var tasks: [Task<Void, Never>] = []
  private var requests: [[String: String]] = []

  func attach(_ next: AVPlayerItem?) {
    guard let next, next !== item else { return }
    stop()
    item = next
    guard #available(tvOS 18.0, *) else { return }
    tasks = [
      Task { @MainActor [weak self] in
        do {
          for try await event in next.metrics(forType: AVMetricHLSMediaSegmentRequestEvent.self) {
            self?.record(event.mediaResourceRequestEvent, kind: "media", url: event.url,
              duration: event.segmentDuration)
          }
        } catch {
          if !Task.isCancelled { self?.append(["kind": "metrics_error", "code": String((error as NSError).code)]) }
        }
      },
      Task { @MainActor [weak self] in
        do {
          for try await event in next.metrics(forType: AVMetricHLSPlaylistRequestEvent.self) {
            self?.record(event.mediaResourceRequestEvent, kind: "playlist", url: event.url)
          }
        } catch {
          if !Task.isCancelled { self?.append(["kind": "metrics_error", "code": String((error as NSError).code)]) }
        }
      },
    ]
  }

  func stop() {
    tasks.forEach { $0.cancel() }
    tasks.removeAll()
    for event in item?.errorLog()?.events ?? [] {
      var row = ["kind": "error_log", "domain": event.errorDomain, "code": String(event.errorStatusCode),
        "comment": PlaybackTelemetryWriter.redact(event.errorComment ?? "")]
      row["date"] = event.date?.ISO8601Format()
      row["scheme"] = event.uri.flatMap(URL.init(string:))?.scheme
      append(row)
    }
    item = nil
  }

  func attachment(name: String) throws -> XCTAttachment {
    stop()
    let data = try JSONSerialization.data(withJSONObject: requests, options: [.sortedKeys])
    let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
    attachment.name = name
    attachment.lifetime = .keepAlways
    return attachment
  }

  static func originAttachment(_ origin: NativeHLSOrigin, name: String) async throws -> XCTAttachment {
    let requests = await origin.requestDiagnostics()
    let data = try JSONSerialization.data(withJSONObject: requests, options: [.sortedKeys])
    let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
    attachment.name = name
    attachment.lifetime = .keepAlways
    return attachment
  }

  @available(tvOS 18.0, *)
  private func record(_ event: AVMetricMediaResourceRequestEvent?, kind: String, url: URL?,
                      duration: Double? = nil) {
    guard let event else { return }
    var row = [
      "kind": kind, "date": event.date.ISO8601Format(),
      "request_seconds": String(event.requestEndTime.timeIntervalSince(event.requestStartTime)),
      "transfer_seconds": String(event.responseEndTime.timeIntervalSince(event.responseStartTime)),
      "cached": String(event.wasReadFromCache),
    ]
    if let duration { row["duration"] = String(duration) }
    // Only locally generated paths are safe to retain; upstream URLs are signed.
    let resourceURL = url ?? event.url
    if let url = resourceURL, url.host == "127.0.0.1" || url.scheme == NativeLowLatencyHLS.scheme {
      row["path"] = url.path
      let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
      for name in ["_HLS_msn", "_HLS_part"] {
        if let value = query.first(where: { $0.name == name })?.value, Int(value) != nil { row[name] = value }
      }
    } else {
      row["extension"] = resourceURL?.pathExtension
    }
    row["wait_seconds"] = String(event.responseStartTime.timeIntervalSince(event.requestEndTime))
    if let error = event.errorEvent?.error {
      row["error"] = PlaybackTelemetryWriter.redact(error.localizedDescription)
      row["code"] = String((error as NSError).code)
    }
    append(row)
  }

  private func append(_ row: [String: String]) {
    requests.append(row)
    if requests.count > 2048 { requests.removeFirst(requests.count - 2048) }
  }
}
