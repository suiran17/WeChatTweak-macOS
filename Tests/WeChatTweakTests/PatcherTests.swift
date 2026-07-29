import Foundation
import XCTest
@testable import WeChatTweak

final class PatcherTests: XCTestCase {
    func testConfigDecodesBinaryAndExpectedFingerprints() throws {
        let config = try decodeConfig(expected: #"["AABB", "CCDD"]"#, patch: "1122")
        let target = try XCTUnwrap(config.targets.first)
        let entry = try XCTUnwrap(target.entries.first)

        XCTAssertEqual(target.binary, "Contents/Resources/wechat.dylib")
        XCTAssertEqual(entry.expected, [Data([0xAA, 0xBB]), Data([0xCC, 0xDD])])
        XCTAssertEqual(entry.asm, Data([0x11, 0x22]))
    }

    func testConfigRejectsMismatchedFingerprintLength() {
        XCTAssertThrowsError(try decodeConfig(expected: #""AA""#, patch: "1122"))
    }

    func testPlanApplyAndIdempotencyForThinMachO() throws {
        let fixture = try makeFixture(bytes: [0xAA, 0xBB])
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let config = try decodeConfig(expected: #""AABB""#, patch: "1122")
        let entry = try XCTUnwrap(config.targets.first?.entries.first)
        let input = Patcher.Input(identifier: "fixture", entry: entry)

        let firstPlan = try Patcher.plan(binary: fixture.binary, inputs: [input])
        XCTAssertEqual(firstPlan.operations.map(\.state), [.ready])
        try Patcher.apply(firstPlan)

        let bytes = try Data(contentsOf: fixture.binary)
        XCTAssertEqual(Data(bytes[0x120..<0x122]), Data([0x11, 0x22]))

        let secondPlan = try Patcher.plan(binary: fixture.binary, inputs: [input])
        XCTAssertEqual(secondPlan.operations.map(\.state), [.alreadyPatched])
        XCTAssertFalse(secondPlan.hasChanges)
    }

    func testUnexpectedBytesStopsAtPlanningStage() throws {
        let fixture = try makeFixture(bytes: [0xDE, 0xAD])
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let config = try decodeConfig(expected: #""AABB""#, patch: "1122")
        let entry = try XCTUnwrap(config.targets.first?.entries.first)

        XCTAssertThrowsError(
            try Patcher.plan(
                binary: fixture.binary,
                inputs: [Patcher.Input(identifier: "fixture", entry: entry)]
            )
        ) { error in
            XCTAssertTrue(error.localizedDescription.contains("has DEAD"))
        }
    }

    private func decodeConfig(expected: String, patch: String) throws -> Config {
        let json = """
        {
          "version": "test",
          "targets": [{
            "identifier": "fixture",
            "binary": "Contents/Resources/wechat.dylib",
            "entries": [{
              "arch": "x86_64",
              "addr": "1020",
              "expected": \(expected),
              "asm": "\(patch)"
            }]
          }]
        }
        """
        return try JSONDecoder().decode(Config.self, from: Data(json.utf8))
    }

    private func makeFixture(bytes: [UInt8]) throws -> (directory: URL, binary: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WeChatTweakTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let binary = directory.appendingPathComponent("fixture.dylib")

        var data = Data()
        data.appendLittleEndian(UInt32(MH_MAGIC_64))
        data.appendLittleEndian(UInt32(bitPattern: CPU_TYPE_X86_64))
        data.appendLittleEndian(UInt32(bitPattern: CPU_SUBTYPE_X86_64_ALL))
        data.appendLittleEndian(UInt32(MH_DYLIB))
        data.appendLittleEndian(UInt32(1))
        data.appendLittleEndian(UInt32(72))
        data.appendLittleEndian(UInt32(0))
        data.appendLittleEndian(UInt32(0))

        data.appendLittleEndian(UInt32(LC_SEGMENT_64))
        data.appendLittleEndian(UInt32(72))
        data.append(Data(repeating: 0, count: 16))
        data.appendLittleEndian(UInt64(0x1000))
        data.appendLittleEndian(UInt64(0x100))
        data.appendLittleEndian(UInt64(0x100))
        data.appendLittleEndian(UInt64(0x100))
        data.appendLittleEndian(UInt32(VM_PROT_READ | VM_PROT_EXECUTE))
        data.appendLittleEndian(UInt32(VM_PROT_READ | VM_PROT_EXECUTE))
        data.appendLittleEndian(UInt32(0))
        data.appendLittleEndian(UInt32(0))

        data.append(Data(repeating: 0, count: 0x200 - data.count))
        data.replaceSubrange(0x120..<0x122, with: bytes)
        try data.write(to: binary)
        return (directory, binary)
    }
}

private extension Data {
    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) {
            append(contentsOf: $0)
        }
    }
}
