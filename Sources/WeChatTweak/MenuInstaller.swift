//
//  MenuInstaller.swift
//  WeChatTweak
//

import Foundation
import MachO

struct MenuInstaller {
    static let runtimeFilename = "libWeChatTweakMenu.dylib"
    static let loadPath = "@executable_path/\(runtimeFilename)"

    struct Report {
        let destination: URL
        let executable: URL
        let injector: DylibInjector.Report
    }

    enum Error: LocalizedError {
        case runtimeNotFound(candidates: [String])
        case invalidRuntime(path: String)
        case incompatibleRuntime(missingArchitectures: [String])
        case appIsNotWritable(path: String)

        var errorDescription: String? {
            switch self {
            case let .runtimeNotFound(candidates):
                return "WeChatTweak menu runtime was not found. Checked: "
                    + candidates.joined(separator: ", ")
            case let .invalidRuntime(path):
                return "Invalid WeChatTweak menu runtime: \(path)"
            case let .incompatibleRuntime(missingArchitectures):
                return "The menu runtime is missing required architectures: "
                    + missingArchitectures.joined(separator: ", ")
            case let .appIsNotWritable(path):
                return "The WeChat app is not writable at \(path)"
            }
        }
    }

    static func resolveRuntime(explicitURL: URL?) throws -> URL {
        if let explicitURL {
            let resolved = explicitURL.standardizedFileURL.resolvingSymlinksInPath()
            guard FileManager.default.fileExists(atPath: resolved.path) else {
                throw Error.invalidRuntime(path: resolved.path)
            }
            return resolved
        }

        var candidates: [URL] = []
        if let executable = Bundle.main.executableURL {
            candidates.append(
                executable.resolvingSymlinksInPath()
                    .deletingLastPathComponent()
                    .appendingPathComponent(runtimeFilename)
            )
        }
        if let argument = CommandLine.arguments.first, !argument.isEmpty {
            candidates.append(
                URL(fileURLWithPath: argument)
                    .standardizedFileURL
                    .resolvingSymlinksInPath()
                    .deletingLastPathComponent()
                    .appendingPathComponent(runtimeFilename)
            )
        }
        candidates.append(
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent(runtimeFilename)
        )

        var checked: [String] = []
        for candidate in candidates {
            let path = candidate.standardizedFileURL.path
            guard !checked.contains(path) else { continue }
            checked.append(path)
            if FileManager.default.fileExists(atPath: path) {
                return URL(fileURLWithPath: path).resolvingSymlinksInPath()
            }
        }
        throw Error.runtimeNotFound(candidates: checked)
    }

    @discardableResult
    static func preflight(app: URL, runtime: URL) throws -> DylibInjector.Report {
        let binary = app.appendingPathComponent("Contents/MacOS/WeChat")
        let runtimeArchitectures: Set<UInt32>
        do {
            runtimeArchitectures = try DylibInjector.architectures(
                in: runtime,
                expectedFileType: UInt32(MH_DYLIB)
            )
        } catch {
            throw Error.invalidRuntime(path: runtime.path)
        }

        let executableArchitectures = try DylibInjector.architectures(
            in: binary,
            expectedFileType: UInt32(MH_EXECUTE)
        )
        let missing = executableArchitectures.subtracting(runtimeArchitectures)
        guard missing.isEmpty else {
            throw Error.incompatibleRuntime(
                missingArchitectures: missing.map(architectureName).sorted()
            )
        }

        let macOSDirectory = app.appendingPathComponent("Contents/MacOS", isDirectory: true)
        guard FileManager.default.isWritableFile(atPath: macOSDirectory.path) else {
            throw Error.appIsNotWritable(path: macOSDirectory.path)
        }

        return try DylibInjector.preflight(binary: binary, dylibPath: loadPath)
    }

    @discardableResult
    static func install(
        app: URL,
        runtime: URL,
        createBackup: Bool
    ) throws -> Report {
        _ = try preflight(app: app, runtime: runtime)

        let executable = app.appendingPathComponent("Contents/MacOS/WeChat")
        if createBackup {
            let backup = URL(fileURLWithPath: executable.path + ".wechattweak-backup")
            if !FileManager.default.fileExists(atPath: backup.path) {
                try FileManager.default.copyItem(at: executable, to: backup)
                print("Backup created: \(backup.path)")
            } else {
                print("Backup exists: \(backup.path)")
            }
        }

        let destination = app
            .appendingPathComponent("Contents/MacOS", isDirectory: true)
            .appendingPathComponent(runtimeFilename)
        let runtimeData = try Data(contentsOf: runtime, options: .mappedIfSafe)
        try runtimeData.write(to: destination, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: destination.path
        )

        let injector = try DylibInjector.inject(
            binary: executable,
            dylibPath: loadPath
        )
        return Report(
            destination: destination,
            executable: executable,
            injector: injector
        )
    }

    private static func architectureName(_ cpu: UInt32) -> String {
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
