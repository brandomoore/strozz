import XCTest
#if os(tvOS)
@testable import Strozz
#else
@testable import StrozzMobile
#endif

final class NativeHLSMediaServerTests: XCTestCase {
  func testMediaServingRetainsPlaybackExecutorAcrossSuspension() async throws {
    let executor = NativeHLSExecutor(pipeline: "test")
    let server = try NativeHLSMediaServer(executor: executor) { _ in
      executor.checkIsolated()
      await Task.yield()
      executor.checkIsolated()
      return Data([1, 2, 3])
    }
    let base = try await server.start()
    defer { server.stop() }
    let session = URLSession(configuration: .ephemeral)
    defer { session.invalidateAndCancel() }
    let (body, response) = try await session.data(from: base.appendingPathComponent("part/0/1/0.ts"))
    XCTAssertEqual(body, Data([1, 2, 3]))
    XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
  }

  func testLoopbackPartsHonorRangesAndDoNotServeUnknownResources() async throws {
    let bytes = Data(repeating: 0x47, count: 188 * 10)
    let server = try NativeHLSMediaServer { path in path == "/part/0/1/0.ts" ? bytes : nil }
    let base = try await server.start()
    defer { server.stop() }
    XCTAssertEqual(base.host, "127.0.0.1")
    let session = URLSession(configuration: .ephemeral)
    defer { session.invalidateAndCancel() }
    var request = URLRequest(url: base.appendingPathComponent("part/0/1/0.ts"))
    request.setValue("bytes=188-375", forHTTPHeaderField: "Range")
    let (part, response) = try await session.data(for: request)
    XCTAssertEqual(part, bytes.subdata(in: 188..<376))
    XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 206)
    XCTAssertEqual((response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Range"), "bytes 188-375/1880")
    request.setValue("bytes=999999-", forHTTPHeaderField: "Range")
    let (_, invalid) = try await session.data(for: request)
    XCTAssertEqual((invalid as? HTTPURLResponse)?.statusCode, 416)
    let (_, missing) = try await session.data(from: base.appendingPathComponent("missing"))
    XCTAssertEqual((missing as? HTTPURLResponse)?.statusCode, 404)
  }
}
