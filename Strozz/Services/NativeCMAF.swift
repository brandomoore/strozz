import Foundation

enum NativeHLSError: String, Error, Sendable {
  case unsupported = "This stream uses a format the native player cannot index."
  case transition = "The stream changed format or entered a discontinuity."
  case invalidMedia = "The stream's media timeline could not be verified."
  case unavailable = "The native live stream is unavailable."
  case timeout = "The native live stream did not respond in time."
  case indexerOverrun = "The native stream indexer could not keep up with the incoming data."
  case transportTable = "The transport stream has an unsupported program table."
  case transportCodec = "The transport stream does not contain H.264 and AAC."
  case transportKeyframe = "The transport segment did not start at a verified H.264 keyframe."
  case partDuration = "A partial segment exceeded the supported duration."
}

/// Byte-level indexing only: encoded audio/video remains on Twitch's CDN.
enum NativeCMAF {
  struct Box {
    let type: String
    let payload: Data
  }

  static func integer(_ data: Data, _ offset: Int, _ count: Int = 4) throws -> UInt64 {
    guard offset >= 0, count <= 8, offset <= data.count - count else {
      throw NativeHLSError.invalidMedia
    }
    return data.dropFirst(offset).prefix(count).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
  }

  static func boxes(_ data: Data) throws -> [Box] {
    var result: [Box] = []
    var offset = 0
    while offset < data.count {
      guard data.count - offset >= 8 else { throw NativeHLSError.invalidMedia }
      let size = try integer(data, offset)
      let header = size == 1 ? 16 : 8
      let length = size == 1 ? try integer(data, offset + 8, 8) : size
      guard length >= header, length <= 32 * 1024 * 1024,
        length <= data.count - offset else { throw NativeHLSError.invalidMedia }
      let type = String(decoding: data.dropFirst(offset + 4).prefix(4), as: UTF8.self)
      result.append(Box(type: type, payload: data.subdata(in: offset + header..<offset + Int(length))))
      offset += Int(length)
    }
    return result
  }

  static func child(_ data: Data, _ name: String) throws -> Data {
    let found = try boxes(data).filter { $0.type == name }
    guard found.count == 1 else { throw NativeHLSError.invalidMedia }
    return found[0].payload
  }

  struct Track: Sendable {
    let id: UInt64
    let scale: UInt64
    let duration: UInt64
    let flags: UInt64
  }

  static func videoTrack(_ initialization: Data) throws -> Track {
    let moov = try child(initialization, "moov")
    for box in try boxes(moov) where box.type == "trak" {
      let mdia = try child(box.payload, "mdia")
      let handler = try child(mdia, "hdlr")
      guard String(decoding: handler.dropFirst(8).prefix(4), as: UTF8.self) == "vide" else { continue }
      let tkhd = try child(box.payload, "tkhd")
      let mdhd = try child(mdia, "mdhd")
      let id = try integer(tkhd, tkhd.first == 1 ? 20 : 12)
      let scale = try integer(mdhd, mdhd.first == 1 ? 20 : 12)
      guard scale > 0 else { throw NativeHLSError.invalidMedia }
      for entry in try boxes(child(moov, "mvex")) where entry.type == "trex" {
        if try integer(entry.payload, 4) == id {
          return Track(id: id, scale: scale, duration: try integer(entry.payload, 12),
                       flags: try integer(entry.payload, 20))
        }
      }
    }
    throw NativeHLSError.unsupported
  }

  struct Timing: Sendable {
    let start: Double
    let duration: Double
    let independent: Bool
  }

  static func timing(_ moof: Data, track: Track) throws -> Timing {
    for box in try boxes(moof) where box.type == "traf" {
      let tfhd = try child(box.payload, "tfhd")
      guard try integer(tfhd, 4) == track.id else { continue }
      let flags = try integer(tfhd, 0) & 0xFFFFFF
      guard flags & 1 == 0 else { throw NativeHLSError.unsupported }
      var position = 8 + (flags & 2 != 0 ? 4 : 0)
      var duration = track.duration
      if flags & 8 != 0 {
        duration = try integer(tfhd, position)
        position += 4
      }
      if flags & 16 != 0 { position += 4 }
      let defaults = flags & 32 != 0 ? try integer(tfhd, position) : track.flags
      let tfdt = try child(box.payload, "tfdt")
      let start = try integer(tfdt, 4, tfdt.first == 1 ? 8 : 4)
      var total: UInt64 = 0
      var firstFlags: UInt64?
      for run in try boxes(box.payload) where run.type == "trun" {
        let flags = try integer(run.payload, 0) & 0xFFFFFF
        let count = try integer(run.payload, 4)
        guard count <= 100_000 else { throw NativeHLSError.invalidMedia }
        var offset = 8 + (flags & 1 != 0 ? 4 : 0)
        var initialFlags = defaults
        if flags & 4 != 0 {
          initialFlags = try integer(run.payload, offset)
          offset += 4
        }
        for index in 0..<count {
          let sampleDuration = flags & 0x100 != 0 ? try integer(run.payload, offset) : duration
          if flags & 0x100 != 0 { offset += 4 }
          if flags & 0x200 != 0 { offset += 4 }
          var sampleFlags = index == 0 ? initialFlags : defaults
          if flags & 0x400 != 0 {
            sampleFlags = try integer(run.payload, offset)
            offset += 4
          }
          if flags & 0x800 != 0 { offset += 4 }
          guard sampleDuration > 0, offset <= run.payload.count else { throw NativeHLSError.invalidMedia }
          total += sampleDuration
          if firstFlags == nil { firstFlags = sampleFlags }
        }
      }
      guard total > 0, let firstFlags else { throw NativeHLSError.invalidMedia }
      return Timing(start: Double(start) / Double(track.scale),
                    duration: Double(total) / Double(track.scale), independent: firstFlags & 0x10000 == 0)
    }
    throw NativeHLSError.invalidMedia
  }

  struct Entry: Sendable {
    let sequence: Int
    let url: URL
    let duration: Double?
    let date: Date?
  }

  struct Manifest: Sendable {
    let initialization: URL?
    let targetDuration: Int
    let discontinuity: Int
    let entries: [Entry]
  }

  static func attributes(_ line: String) -> [String: String] {
    var quoted = false
    var field = ""
    var fields: [String] = []
    for character in line {
      if character == "\"" { quoted.toggle() }
      if character == ",", !quoted { fields.append(field); field = "" } else { field.append(character) }
    }
    fields.append(field)
    return fields.reduce(into: [:]) { result, field in
      let pair = field.split(separator: "=", maxSplits: 1).map(String.init)
      if pair.count == 2 { result[pair[0]] = pair[1].trimmingCharacters(in: CharacterSet(charactersIn: "\"")) }
    }
  }

  static func manifest(_ text: String, url: URL) throws -> Manifest {
    guard text.hasPrefix("#EXTM3U") else { throw NativeHLSError.invalidMedia }
    var map: URL?
    var sequence: Int?
    var discontinuity = 0
    var targetDuration = 6
    var duration: Double?
    var date: Date?
    var entries: [Entry] = []
    var prefetch = false
    for raw in text.components(separatedBy: .newlines) {
      let line = raw.trimmingCharacters(in: .whitespaces)
      let value = line.split(separator: ":", maxSplits: 1).dropFirst().first.map(String.init) ?? ""
      if line == "#EXT-X-DISCONTINUITY" || line == "#EXT-X-ENDLIST" || line == "#EXT-X-GAP"
        || line.hasPrefix("#EXT-X-KEY:") || line.hasPrefix("#EXT-X-BYTERANGE:") {
        throw NativeHLSError.transition
      }
      if line.hasPrefix("#EXT-X-DATERANGE:") {
        guard ["timestamp", "twitch-session", "twitch-stream-source", "twitch-trigger"]
          .contains(attributes(value)["CLASS"] ?? "") else { throw NativeHLSError.transition }
      } else if line.hasPrefix("#EXT-X-MEDIA-SEQUENCE:") {
        sequence = Int(value)
      } else if line.hasPrefix("#EXT-X-TARGETDURATION:") {
        guard let target = Int(value), (1...10).contains(target) else { throw NativeHLSError.invalidMedia }
        targetDuration = target
      } else if line.hasPrefix("#EXT-X-DISCONTINUITY-SEQUENCE:") {
        guard let number = Int(value) else { throw NativeHLSError.invalidMedia }
        discontinuity = number
      } else if line.hasPrefix("#EXT-X-MAP:") {
        let attrs = attributes(value)
        guard attrs["BYTERANGE"] == nil, let path = attrs["URI"] else { throw NativeHLSError.unsupported }
        map = URL(string: path, relativeTo: url)?.absoluteURL
      } else if line.hasPrefix("#EXT-X-PROGRAM-DATE-TIME:") {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        date = formatter.date(from: value)
        if date == nil {
          formatter.formatOptions = [.withInternetDateTime]
          date = formatter.date(from: value)
        }
        guard date != nil else { throw NativeHLSError.invalidMedia }
      } else if line.hasPrefix("#EXTINF:") {
        duration = value.split(separator: ",").first.flatMap { Double($0) }
        guard let duration, duration.isFinite, duration > 0, duration <= 10 else { throw NativeHLSError.invalidMedia }
      } else if line.hasPrefix("#EXT-X-TWITCH-PREFETCH:") || (!line.isEmpty && !line.hasPrefix("#")) {
        let isPrefetch = line.hasPrefix("#")
        let path = isPrefetch ? value : line
        guard let number = sequence, let media = URL(string: path, relativeTo: url)?.absoluteURL,
          media.scheme == "https" else { throw NativeHLSError.invalidMedia }
        entries.append(Entry(sequence: number, url: media, duration: isPrefetch ? nil : duration,
                             date: isPrefetch ? nil : date))
        sequence = number + 1
        if let duration { date = date?.addingTimeInterval(duration) }
        duration = nil
        prefetch = prefetch || isPrefetch
      }
    }
    guard prefetch, map == nil || map?.scheme == "https",
      entries.contains(where: { $0.date != nil }) else { throw NativeHLSError.unsupported }
    return Manifest(initialization: map, targetDuration: targetDuration, discontinuity: discontinuity, entries: entries)
  }
}
