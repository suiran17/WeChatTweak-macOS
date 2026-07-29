//
//  Command.swift
//
//  Created by Sunny Young.
//

import Foundation

struct Command {
    struct PatchResult {
        let plans: [Patcher.Plan]

        var changedBinaries: [URL] {
            plans.filter(\.hasChanges).map(\.binary)
        }
    }

    enum Error: LocalizedError {
        case invalidInfoPlist(URL)
        case unsafeBinaryPath(String)
        case processFailed(executable: String, arguments: [String], status: Int32, output: String)

        var errorDescription: String? {
            switch self {
            case let .invalidInfoPlist(url):
                return "Unable to read CFBundleVersion from \(url.path)"
            case let .unsafeBinaryPath(path):
                return "Configured binary must stay inside WeChat.app: \(path)"
            case let .processFailed(executable, arguments, status, output):
                let command = ([executable] + arguments).joined(separator: " ")
                return "\(command) exited with \(status): \(output)"
            }
        }
    }

    static func version(app: URL) throws -> String {
        let infoURL = app.appendingPathComponent("Contents/Info.plist")
        guard
            let dictionary = NSDictionary(contentsOf: infoURL),
            let value = dictionary["CFBundleVersion"] as? String,
            !value.isEmpty
        else {
            throw Error.invalidInfoPlist(infoURL)
        }
        return value
    }

    static func patch(
        app: URL,
        config: Config,
        dryRun: Bool,
        createBackup: Bool
    ) throws -> PatchResult {
        let grouped = Dictionary(grouping: config.targets, by: \.binary)
        var plans: [Patcher.Plan] = []

        // Every target in every binary is planned and byte-validated before the
        // first backup or write occurs.
        for relativePath in grouped.keys.sorted() {
            let binary = try binaryURL(app: app, relativePath: relativePath)
            let inputs = grouped[relativePath, default: []].flatMap { target in
                target.entries.map { Patcher.Input(identifier: target.identifier, entry: $0) }
            }
            plans.append(try Patcher.plan(binary: binary, inputs: inputs))
        }

        let result = PatchResult(plans: plans)
        printPlan(result)
        guard !dryRun else { return result }

        if createBackup {
            for binary in result.changedBinaries {
                try backup(binary: binary)
            }
        }
        for plan in plans {
            try Patcher.apply(plan)
        }
        return result
    }

    static func resign(app: URL, modifiedBinaries: [URL]) throws {
        for binary in modifiedBinaries where binary.pathExtension == "dylib" {
            _ = try execute(
                executable: "/usr/bin/codesign",
                arguments: ["--force", "--sign", "-", binary.path]
            )
        }

        _ = try execute(
            executable: "/usr/bin/codesign",
            arguments: ["--force", "--deep", "--sign", "-", app.path]
        )
        _ = try execute(
            executable: "/usr/bin/codesign",
            arguments: ["--verify", "--deep", "--strict", app.path]
        )
    }

    private static func binaryURL(app: URL, relativePath: String) throws -> URL {
        guard
            !relativePath.isEmpty,
            !relativePath.hasPrefix("/"),
            !relativePath.split(separator: "/").contains("..")
        else {
            throw Error.unsafeBinaryPath(relativePath)
        }

        let appRoot = app.standardizedFileURL.resolvingSymlinksInPath()
        let binary = appRoot.appendingPathComponent(relativePath)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let prefix = appRoot.path.hasSuffix("/") ? appRoot.path : appRoot.path + "/"
        guard binary.path.hasPrefix(prefix) else {
            throw Error.unsafeBinaryPath(relativePath)
        }
        return binary
    }

    private static func backup(binary: URL) throws {
        let backup = URL(fileURLWithPath: binary.path + ".wechattweak-backup")
        guard !FileManager.default.fileExists(atPath: backup.path) else {
            print("Backup exists: \(backup.path)")
            return
        }
        try FileManager.default.copyItem(at: binary, to: backup)
        print("Backup created: \(backup.path)")
    }

    private static func printPlan(_ result: PatchResult) {
        for plan in result.plans {
            print("Binary: \(plan.binary.path)")
            for operation in plan.operations {
                let validation = operation.usesLegacyValidation ? ", legacy/no fingerprint" : ""
                print(
                    "  [\(operation.arch.rawValue)] \(operation.identifier) "
                    + "\(String(format: "0x%llx", operation.address)): "
                    + "\(operation.state.rawValue)\(validation)"
                )
            }
        }
    }

    @discardableResult
    private static func execute(executable: String, arguments: [String]) throws -> String {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard process.terminationStatus == 0 else {
            throw Error.processFailed(
                executable: executable,
                arguments: arguments,
                status: process.terminationStatus,
                output: text
            )
        }
        return text
    }
}
