//
//  DylibInjector.swift
//  WeChatTweak
//
//  Adds an LC_LOAD_DYLIB command using existing Mach-O header padding.
//

import Foundation
import MachO

struct DylibInjector {
    struct Report {
        let injectedArchitectures: [String]
        let alreadyInjectedArchitectures: [String]
    }

    enum Error: LocalizedError {
        case invalidFile
        case invalidDylibPath
        case unsupportedMachO(magic: UInt32)
        case malformedLoadCommands(arch: String)
        case insufficientHeaderPadding(arch: String, required: Int, available: Int)
        case nonZeroHeaderPadding(arch: String, fileOffset: UInt64)

        var errorDescription: String? {
            switch self {
            case .invalidFile:
                return "Invalid Mach-O file"
            case .invalidDylibPath:
                return "The injected dylib path must be non-empty UTF-8 without a NUL byte"
            case let .unsupportedMachO(magic):
                return "Unsupported Mach-O magic \(String(format: "0x%08x", magic))"
            case let .malformedLoadCommands(arch):
                return "[\(arch)] Malformed Mach-O load commands"
            case let .insufficientHeaderPadding(arch, required, available):
                return "[\(arch)] Not enough Mach-O header padding for the menu loader "
                    + "(required: \(required) bytes, available: \(available) bytes)"
            case let .nonZeroHeaderPadding(arch, fileOffset):
                return "[\(arch)] Refusing to overwrite non-zero Mach-O header padding at "
                    + String(format: "0x%llx", fileOffset)
            }
        }
    }

    private struct Slice {
        let cpu: UInt32
        let offset: Int
        let size: Int

        var architectureName: String {
            switch cpu {
            case UInt32(CPU_TYPE_X86_64):
                return "x86_64"
            case UInt32(CPU_TYPE_ARM64):
                return "arm64"
            default:
                return String(format: "cpu-0x%08x", cpu)
            }
        }
    }

    private enum InjectionState {
        case needsInjection
        case alreadyInjected
    }

    private struct Operation {
        let slice: Slice
        let state: InjectionState
        let command: Data
        let insertionOffset: Int
        let oldTableEnd: Int
        let oldCommandTail: Data
        let oldCommandCount: UInt32
        let oldCommandSize: UInt32
    }

    static func preflight(binary: URL, dylibPath: String) throws -> Report {
        let data = try Data(contentsOf: binary, options: .mappedIfSafe)
        return report(for: try makeOperations(data: data, dylibPath: dylibPath))
    }

    @discardableResult
    static func inject(binary: URL, dylibPath: String) throws -> Report {
        // Validate every slice before opening the binary for writes.
        let data = try Data(contentsOf: binary, options: .mappedIfSafe)
        let operations = try makeOperations(data: data, dylibPath: dylibPath)
        let report = report(for: operations)

        guard operations.contains(where: { $0.state == .needsInjection }) else {
            return report
        }

        let file = try FileHandle(forUpdating: binary)
        defer { try? file.close() }

        for operation in operations where operation.state == .needsInjection {
            // LC_CODE_SIGNATURE must remain last. Move it and any following load
            // commands forward before inserting the new command in its place.
            if !operation.oldCommandTail.isEmpty {
                try file.seek(
                    toOffset: UInt64(operation.insertionOffset + operation.command.count)
                )
                try file.write(contentsOf: operation.oldCommandTail)
            }

            try file.seek(toOffset: UInt64(operation.insertionOffset))
            try file.write(contentsOf: operation.command)

            try file.seek(toOffset: UInt64(operation.slice.offset + 16))
            try file.write(contentsOf: littleEndian(operation.oldCommandCount + 1))
            try file.seek(toOffset: UInt64(operation.slice.offset + 20))
            try file.write(
                contentsOf: littleEndian(
                    operation.oldCommandSize + UInt32(operation.command.count)
                )
            )
        }

        try file.synchronize()
        return report
    }

    static func architectures(
        in binary: URL,
        expectedFileType: UInt32? = nil
    ) throws -> Set<UInt32> {
        let data = try Data(contentsOf: binary, options: .mappedIfSafe)
        let parsedSlices = try slices(in: data)

        if let expectedFileType {
            for slice in parsedSlices {
                guard
                    let fileType = readUInt32LE(data, at: slice.offset + 12),
                    fileType == expectedFileType
                else {
                    throw Error.invalidFile
                }
            }
        }

        return Set(parsedSlices.map(\.cpu))
    }

    private static func makeOperations(data: Data, dylibPath: String) throws -> [Operation] {
        guard !dylibPath.isEmpty, !dylibPath.utf8.contains(0) else {
            throw Error.invalidDylibPath
        }

        let command = try makeDylibCommand(path: dylibPath)
        return try slices(in: data).map {
            try operation(for: $0, data: data, command: command, dylibPath: dylibPath)
        }
    }

    private static func operation(
        for slice: Slice,
        data: Data,
        command: Data,
        dylibPath: String
    ) throws -> Operation {
        let arch = slice.architectureName
        let headerOffset = slice.offset
        guard
            let magic = readUInt32LE(data, at: headerOffset),
            magic == UInt32(MH_MAGIC_64),
            let commandCount = readUInt32LE(data, at: headerOffset + 16),
            let commandBytes = readUInt32LE(data, at: headerOffset + 20)
        else {
            throw Error.invalidFile
        }

        let firstCommand = headerOffset + 32
        let tableEnd = firstCommand + Int(commandBytes)
        let sliceEnd = slice.offset + slice.size
        guard firstCommand <= tableEnd, tableEnd <= sliceEnd else {
            throw Error.malformedLoadCommands(arch: arch)
        }

        var cursor = firstCommand
        var codeSignatureOffset: Int?
        var firstDataOffset = slice.size
        var alreadyInjected = false

        for _ in 0..<commandCount {
            guard
                let loadCommand = readUInt32LE(data, at: cursor),
                let loadCommandSize = readUInt32LE(data, at: cursor + 4)
            else {
                throw Error.malformedLoadCommands(arch: arch)
            }

            let size = Int(loadCommandSize)
            guard size >= 8, size % 8 == 0, cursor <= tableEnd - size else {
                throw Error.malformedLoadCommands(arch: arch)
            }

            if loadCommand == UInt32(LC_CODE_SIGNATURE), codeSignatureOffset == nil {
                codeSignatureOffset = cursor
            }

            if loadCommand == UInt32(LC_LOAD_DYLIB) {
                let loadedPath = try dylibName(
                    in: data,
                    commandOffset: cursor,
                    commandSize: size
                )
                alreadyInjected = alreadyInjected || loadedPath == dylibPath
            }

            if loadCommand == UInt32(LC_SEGMENT_64) {
                firstDataOffset = try minimumDataOffset(
                    in: data,
                    slice: slice,
                    commandOffset: cursor,
                    commandSize: size,
                    currentMinimum: firstDataOffset
                )
            }

            cursor += size
        }

        guard cursor == tableEnd else {
            throw Error.malformedLoadCommands(arch: arch)
        }

        if alreadyInjected {
            return Operation(
                slice: slice,
                state: .alreadyInjected,
                command: command,
                insertionOffset: tableEnd,
                oldTableEnd: tableEnd,
                oldCommandTail: Data(),
                oldCommandCount: commandCount,
                oldCommandSize: commandBytes
            )
        }

        let tableEndInSlice = tableEnd - slice.offset
        let available = max(0, firstDataOffset - tableEndInSlice)
        guard command.count <= available else {
            throw Error.insufficientHeaderPadding(
                arch: arch,
                required: command.count,
                available: available
            )
        }

        let paddingEnd = tableEnd + command.count
        guard paddingEnd <= sliceEnd else {
            throw Error.insufficientHeaderPadding(
                arch: arch,
                required: command.count,
                available: max(0, sliceEnd - tableEnd)
            )
        }

        for index in tableEnd..<paddingEnd where data[index] != 0 {
            throw Error.nonZeroHeaderPadding(
                arch: arch,
                fileOffset: UInt64(index)
            )
        }

        let insertionOffset = codeSignatureOffset ?? tableEnd
        return Operation(
            slice: slice,
            state: .needsInjection,
            command: command,
            insertionOffset: insertionOffset,
            oldTableEnd: tableEnd,
            oldCommandTail: data.subdata(in: insertionOffset..<tableEnd),
            oldCommandCount: commandCount,
            oldCommandSize: commandBytes
        )
    }

    private static func minimumDataOffset(
        in data: Data,
        slice: Slice,
        commandOffset: Int,
        commandSize: Int,
        currentMinimum: Int
    ) throws -> Int {
        let arch = slice.architectureName
        guard
            commandSize >= 72,
            let segmentFileOffset = readUInt64LE(data, at: commandOffset + 40),
            let sectionCount = readUInt32LE(data, at: commandOffset + 64)
        else {
            throw Error.malformedLoadCommands(arch: arch)
        }

        let sectionBytes = Int(sectionCount) * 80
        guard
            sectionBytes / 80 == Int(sectionCount),
            sectionBytes <= commandSize - 72
        else {
            throw Error.malformedLoadCommands(arch: arch)
        }

        var result = currentMinimum
        if segmentFileOffset > 0, segmentFileOffset <= UInt64(slice.size) {
            result = min(result, Int(segmentFileOffset))
        }

        for sectionIndex in 0..<Int(sectionCount) {
            let sectionOffset = commandOffset + 72 + sectionIndex * 80
            guard let fileOffset = readUInt32LE(data, at: sectionOffset + 48) else {
                throw Error.malformedLoadCommands(arch: arch)
            }
            if fileOffset > 0, fileOffset <= UInt32(slice.size) {
                result = min(result, Int(fileOffset))
            }
        }

        return result
    }

    private static func dylibName(
        in data: Data,
        commandOffset: Int,
        commandSize: Int
    ) throws -> String {
        guard
            commandSize >= 24,
            let nameOffsetValue = readUInt32LE(data, at: commandOffset + 8)
        else {
            throw Error.invalidFile
        }

        let nameOffset = Int(nameOffsetValue)
        guard nameOffset >= 24, nameOffset < commandSize else {
            throw Error.invalidFile
        }

        let start = commandOffset + nameOffset
        let end = commandOffset + commandSize
        guard
            let terminator = data[start..<end].firstIndex(of: 0),
            let name = String(data: data[start..<terminator], encoding: .utf8)
        else {
            throw Error.invalidFile
        }
        return name
    }

    private static func makeDylibCommand(path: String) throws -> Data {
        let pathBytes = Data(path.utf8)
        let unalignedSize = 24 + pathBytes.count + 1
        let commandSize = (unalignedSize + 7) & ~7
        guard commandSize <= Int(UInt32.max) else {
            throw Error.invalidDylibPath
        }

        var command = Data(repeating: 0, count: commandSize)
        write(UInt32(LC_LOAD_DYLIB), to: &command, at: 0)
        write(UInt32(commandSize), to: &command, at: 4)
        write(UInt32(24), to: &command, at: 8)
        command.replaceSubrange(24..<(24 + pathBytes.count), with: pathBytes)
        return command
    }

    private static func slices(in data: Data) throws -> [Slice] {
        guard let magicBE = readUInt32BE(data, at: 0) else {
            throw Error.invalidFile
        }

        if magicBE == UInt32(FAT_MAGIC) || magicBE == UInt32(FAT_CIGAM) {
            let swapped = magicBE == UInt32(FAT_CIGAM)
            guard let countValue = swapped
                ? readUInt32LE(data, at: 4)
                : readUInt32BE(data, at: 4)
            else {
                throw Error.invalidFile
            }

            let count = Int(countValue)
            guard count <= (data.count - 8) / 20 else {
                throw Error.invalidFile
            }

            var result: [Slice] = []
            result.reserveCapacity(count)
            for index in 0..<count {
                let archOffset = 8 + index * 20
                let cpu = swapped
                    ? readUInt32LE(data, at: archOffset)
                    : readUInt32BE(data, at: archOffset)
                let offset = swapped
                    ? readUInt32LE(data, at: archOffset + 8)
                    : readUInt32BE(data, at: archOffset + 8)
                let size = swapped
                    ? readUInt32LE(data, at: archOffset + 12)
                    : readUInt32BE(data, at: archOffset + 12)

                guard let cpu, let offset, let size else {
                    throw Error.invalidFile
                }

                let intOffset = Int(offset)
                let intSize = Int(size)
                guard
                    intOffset <= data.count,
                    intSize <= data.count - intOffset
                else {
                    throw Error.invalidFile
                }
                result.append(Slice(cpu: cpu, offset: intOffset, size: intSize))
            }
            return result
        }

        guard
            let magicLE = readUInt32LE(data, at: 0),
            magicLE == UInt32(MH_MAGIC_64),
            let cpu = readUInt32LE(data, at: 4)
        else {
            throw Error.unsupportedMachO(magic: magicBE)
        }
        return [Slice(cpu: cpu, offset: 0, size: data.count)]
    }

    private static func report(for operations: [Operation]) -> Report {
        Report(
            injectedArchitectures: operations.compactMap {
                $0.state == .needsInjection ? $0.slice.architectureName : nil
            },
            alreadyInjectedArchitectures: operations.compactMap {
                $0.state == .alreadyInjected ? $0.slice.architectureName : nil
            }
        )
    }

    private static func readUInt32LE(_ data: Data, at offset: Int) -> UInt32? {
        guard offset >= 0, offset <= data.count - 4 else { return nil }
        return data.withUnsafeBytes {
            UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
        }
    }

    private static func readUInt32BE(_ data: Data, at offset: Int) -> UInt32? {
        guard offset >= 0, offset <= data.count - 4 else { return nil }
        return data.withUnsafeBytes {
            UInt32(bigEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
        }
    }

    private static func readUInt64LE(_ data: Data, at offset: Int) -> UInt64? {
        guard offset >= 0, offset <= data.count - 8 else { return nil }
        return data.withUnsafeBytes {
            UInt64(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt64.self))
        }
    }

    private static func write<T: FixedWidthInteger>(
        _ value: T,
        to data: inout Data,
        at offset: Int
    ) {
        withUnsafeBytes(of: value.littleEndian) {
            data.replaceSubrange(offset..<(offset + $0.count), with: $0)
        }
    }

    private static func littleEndian<T: FixedWidthInteger>(_ value: T) -> Data {
        withUnsafeBytes(of: value.littleEndian) { Data($0) }
    }
}
