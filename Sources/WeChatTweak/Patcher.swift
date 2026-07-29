//
//  Patcher.swift
//  WeChatTweak
//
//  Created by Sunny Young on 2025/12/4.
//

import Darwin
import Foundation
import MachO

struct Patcher {
    struct Input {
        let identifier: String
        let entry: Config.Entry
    }

    enum State: String {
        case ready
        case alreadyPatched
    }

    struct Operation {
        let identifier: String
        let arch: Config.Arch
        let address: UInt64
        let fileOffset: UInt64
        let original: Data
        let replacement: Data
        let state: State
        let usesLegacyValidation: Bool
    }

    struct Plan {
        let binary: URL
        let operations: [Operation]

        var hasChanges: Bool {
            operations.contains { $0.state == .ready }
        }
    }

    enum Error: LocalizedError {
        case invalidFile(URL)
        case malformedMachO(String)
        case not64BitMachO(magic: UInt32)
        case vaNotFound(arch: String, va: UInt64)
        case noArchMatched
        case unexpectedBytes(identifier: String, arch: String, va: UInt64, actual: Data, expected: [Data])
        case overlappingPatches(first: String, second: String)
        case binaryChanged(identifier: String)

        var errorDescription: String? {
            switch self {
            case let .invalidFile(url):
                return "Invalid or missing Mach-O file: \(url.path)"
            case let .malformedMachO(reason):
                return "Malformed Mach-O: \(reason)"
            case let .not64BitMachO(magic):
                return "Unsupported Mach-O magic: \(String(format: "0x%08x", magic))"
            case let .vaNotFound(arch, va):
                return "[\(arch)] address \(Patcher.hex(va)) does not map to file data"
            case .noArchMatched:
                return "No configured architecture exists in this Mach-O"
            case let .unexpectedBytes(identifier, arch, va, actual, expected):
                let candidates = expected.map { Patcher.hex($0) }.joined(separator: " or ")
                return "[\(arch)] \(identifier) at \(Patcher.hex(va)) has \(Patcher.hex(actual)); expected \(candidates)"
            case let .overlappingPatches(first, second):
                return "Patch ranges overlap: \(first) and \(second)"
            case let .binaryChanged(identifier):
                return "Binary changed after validation while applying \(identifier); write aborted"
            }
        }
    }

    static func plan(binary: URL, inputs: [Input]) throws -> Plan {
        guard FileManager.default.fileExists(atPath: binary.path), !inputs.isEmpty else {
            if inputs.isEmpty { throw Error.noArchMatched }
            throw Error.invalidFile(binary)
        }

        let file = try FileHandle(forReadingFrom: binary)
        defer { try? file.close() }

        let slices = try machOSlices(file: file)
        var operations: [Operation] = []

        for slice in slices {
            let matching = inputs.filter { $0.entry.arch.cpu == slice.cpuType }
            for input in matching {
                let offset = try fileOffset(
                    file: file,
                    sliceOffset: slice.offset,
                    address: input.entry.addr,
                    byteCount: input.entry.asm.count,
                    arch: input.entry.arch
                )
                let actual = try read(file: file, offset: offset, count: input.entry.asm.count)
                let state: State

                if actual == input.entry.asm {
                    state = .alreadyPatched
                } else if input.entry.expected.isEmpty || input.entry.expected.contains(actual) {
                    state = .ready
                } else {
                    throw Error.unexpectedBytes(
                        identifier: input.identifier,
                        arch: input.entry.arch.rawValue,
                        va: input.entry.addr,
                        actual: actual,
                        expected: input.entry.expected
                    )
                }

                operations.append(
                    Operation(
                        identifier: input.identifier,
                        arch: input.entry.arch,
                        address: input.entry.addr,
                        fileOffset: offset,
                        original: actual,
                        replacement: input.entry.asm,
                        state: state,
                        usesLegacyValidation: input.entry.expected.isEmpty
                    )
                )
            }
        }

        guard !operations.isEmpty else {
            throw Error.noArchMatched
        }

        let sorted = operations.sorted { $0.fileOffset < $1.fileOffset }
        for pair in zip(sorted, sorted.dropFirst()) {
            let firstEnd = pair.0.fileOffset + UInt64(pair.0.replacement.count)
            if firstEnd > pair.1.fileOffset {
                throw Error.overlappingPatches(first: pair.0.identifier, second: pair.1.identifier)
            }
        }

        return Plan(binary: binary, operations: sorted)
    }

    static func apply(_ plan: Plan) throws {
        guard plan.hasChanges else { return }

        let file = try FileHandle(forUpdating: plan.binary)
        defer { try? file.close() }

        // Revalidate every range before the first write so an external change cannot
        // leave a partially patched file.
        for operation in plan.operations where operation.state == .ready {
            let current = try read(
                file: file,
                offset: operation.fileOffset,
                count: operation.original.count
            )
            guard current == operation.original else {
                throw Error.binaryChanged(identifier: operation.identifier)
            }
        }

        for operation in plan.operations where operation.state == .ready {
            try file.seek(toOffset: operation.fileOffset)
            try file.write(contentsOf: operation.replacement)
        }
        try file.synchronize()
    }

    private struct Slice {
        let cpuType: UInt32
        let offset: UInt64
    }

    private static func machOSlices(file: FileHandle) throws -> [Slice] {
        let header = try read(file: file, offset: 0, count: 8)
        let magicBE = header.uint32BE(at: 0)

        switch magicBE {
        case UInt32(FAT_MAGIC), UInt32(FAT_CIGAM):
            let littleEndian = magicBE == UInt32(FAT_CIGAM)
            let count = Int(header.uint32(at: 4, littleEndian: littleEndian))
            guard count > 0, count < 64 else {
                throw Error.malformedMachO("invalid fat architecture count \(count)")
            }

            let table = try read(file: file, offset: 8, count: count * 20)
            return (0..<count).map { index in
                let base = index * 20
                return Slice(
                    cpuType: table.uint32(at: base, littleEndian: littleEndian),
                    offset: UInt64(table.uint32(at: base + 8, littleEndian: littleEndian))
                )
            }
        case UInt32(FAT_MAGIC_64), UInt32(FAT_CIGAM_64):
            let littleEndian = magicBE == UInt32(FAT_CIGAM_64)
            let count = Int(header.uint32(at: 4, littleEndian: littleEndian))
            guard count > 0, count < 64 else {
                throw Error.malformedMachO("invalid fat64 architecture count \(count)")
            }

            let table = try read(file: file, offset: 8, count: count * 32)
            return (0..<count).map { index in
                let base = index * 32
                return Slice(
                    cpuType: table.uint32(at: base, littleEndian: littleEndian),
                    offset: table.uint64(at: base + 8, littleEndian: littleEndian)
                )
            }
        default:
            let magicLE = header.uint32LE(at: 0)
            guard magicLE == UInt32(MH_MAGIC_64) else {
                throw Error.not64BitMachO(magic: magicLE)
            }
            return [Slice(cpuType: header.uint32LE(at: 4), offset: 0)]
        }
    }

    private static func fileOffset(
        file: FileHandle,
        sliceOffset: UInt64,
        address: UInt64,
        byteCount: Int,
        arch: Config.Arch
    ) throws -> UInt64 {
        let header = try read(file: file, offset: sliceOffset, count: 32)
        let magic = header.uint32LE(at: 0)
        guard magic == UInt32(MH_MAGIC_64) else {
            throw Error.not64BitMachO(magic: magic)
        }

        let commandCount = Int(header.uint32LE(at: 16))
        let commandBytes = UInt64(header.uint32LE(at: 20))
        var commandOffset = sliceOffset + 32
        let commandsEnd = commandOffset + commandBytes

        for _ in 0..<commandCount {
            let commandHeader = try read(file: file, offset: commandOffset, count: 8)
            let command = commandHeader.uint32LE(at: 0)
            let commandSize = UInt64(commandHeader.uint32LE(at: 4))
            guard commandSize >= 8, commandOffset + commandSize <= commandsEnd else {
                throw Error.malformedMachO("invalid load command size")
            }

            if command == UInt32(LC_SEGMENT_64) {
                guard commandSize >= 72 else {
                    throw Error.malformedMachO("short LC_SEGMENT_64")
                }
                let segment = try read(file: file, offset: commandOffset, count: 72)
                let vmAddress = segment.uint64LE(at: 24)
                let vmSize = segment.uint64LE(at: 32)
                let segmentFileOffset = segment.uint64LE(at: 40)
                let fileSize = segment.uint64LE(at: 48)
                let length = UInt64(byteCount)

                if address >= vmAddress,
                   address <= UInt64.max - length,
                   address + length <= vmAddress + vmSize {
                    let relative = address - vmAddress
                    guard relative <= fileSize, length <= fileSize - relative else {
                        throw Error.vaNotFound(arch: arch.rawValue, va: address)
                    }
                    return sliceOffset + segmentFileOffset + relative
                }
            }

            commandOffset += commandSize
        }

        throw Error.vaNotFound(arch: arch.rawValue, va: address)
    }

    private static func read(file: FileHandle, offset: UInt64, count: Int) throws -> Data {
        try file.seek(toOffset: offset)
        guard let data = try file.read(upToCount: count), data.count == count else {
            throw Error.malformedMachO("unexpected end of file")
        }
        return data
    }

    private static func hex(_ value: UInt64) -> String {
        String(format: "0x%llx", value)
    }

    private static func hex(_ data: Data) -> String {
        data.map { String(format: "%02X", $0) }.joined()
    }
}

private extension Data {
    func uint32LE(at offset: Int) -> UInt32 {
        uint32(at: offset, littleEndian: true)
    }

    func uint32BE(at offset: Int) -> UInt32 {
        uint32(at: offset, littleEndian: false)
    }

    func uint32(at offset: Int, littleEndian: Bool) -> UInt32 {
        let bytes = self[offset..<(offset + 4)]
        if littleEndian {
            return bytes.enumerated().reduce(0) { $0 | UInt32($1.element) << UInt32($1.offset * 8) }
        }
        return bytes.reduce(0) { ($0 << 8) | UInt32($1) }
    }

    func uint64LE(at offset: Int) -> UInt64 {
        uint64(at: offset, littleEndian: true)
    }

    func uint64(at offset: Int, littleEndian: Bool) -> UInt64 {
        let bytes = self[offset..<(offset + 8)]
        if littleEndian {
            return bytes.enumerated().reduce(0) { $0 | UInt64($1.element) << UInt64($1.offset * 8) }
        }
        return bytes.reduce(0) { ($0 << 8) | UInt64($1) }
    }
}
