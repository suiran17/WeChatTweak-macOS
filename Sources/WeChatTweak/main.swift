//
//  main.swift
//
//  Created by Sunny Young.
//

import Foundation
import Dispatch
import ArgumentParser

// MARK: Versions
extension Tweak {
    struct Versions: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List all supported WeChat versions")

        @OptionGroup
        var options: Tweak.Options

        mutating func run() async throws {
            print("------ Current version ------")
            print(try Command.version(app: options.app))
            print("------ Supported versions ------")
            try await Config.load(url: options.config).forEach({ print($0.version) })
            Darwin.exit(EXIT_SUCCESS)
        }
    }
}

// MARK: Patch
extension Tweak {
    struct Patch: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Patch WeChat.app")

        @OptionGroup
        var options: Tweak.Options

        @Flag(help: "Validate all patches without changing or signing WeChat.app")
        var dryRun = false

        @Flag(help: "Do not create a .wechattweak-backup file before patching")
        var noBackup = false

        @Option(
            name: .customLong("menu-dylib"),
            help: "Path to libWeChatTweakMenu.dylib (defaults to the directory containing wechattweak)",
            transform: { URL(fileURLWithPath: $0) }
        )
        var menuDylib: URL?

        @Flag(
            name: .customLong("without-menu"),
            help: "Apply binary patches without installing the in-WeChat Tweak menu"
        )
        var withoutMenu = false

        mutating func run() async throws {
            print("------ Version ------")
            let version = try Command.version(app: options.app)
            print("WeChat version: \(version)")

            print("------ Config ------")
            guard let config = (try await Config.load(url: options.config)).first(where: { $0.version == version }) else {
                throw Error.unsupportedVersion
            }
            print("Matched build \(config.version), \(config.targets.count) target groups")

            var resolvedMenuRuntime: URL?
            if !withoutMenu {
                print("------ Menu preflight ------")
                let runtime = try MenuInstaller.resolveRuntime(explicitURL: menuDylib)
                let report = try MenuInstaller.preflight(app: options.app, runtime: runtime)
                resolvedMenuRuntime = runtime
                print("Menu runtime: \(runtime.path)")
                print(
                    "Loader: \(report.injectedArchitectures.count) to inject, "
                    + "\(report.alreadyInjectedArchitectures.count) already injected"
                )
            }

            print("------ Patch ------")
            let result = try Command.patch(
                app: options.app,
                config: config,
                dryRun: dryRun,
                createBackup: !noBackup
            )
            if dryRun {
                print("Dry run passed; no files were changed.")
                Darwin.exit(EXIT_SUCCESS)
            }

            var signingInputs = result.changedBinaries
            var menuChanged = false
            if let runtime = resolvedMenuRuntime {
                print("------ Menu ------")
                let report = try MenuInstaller.install(
                    app: options.app,
                    runtime: runtime,
                    createBackup: !noBackup
                )
                menuChanged = true
                signingInputs.append(report.destination)
                signingInputs.append(report.executable)
                print("Installed: \(report.destination.path)")
                print(
                    "Loader: \(report.injector.injectedArchitectures.count) injected, "
                    + "\(report.injector.alreadyInjectedArchitectures.count) already injected"
                )
            }

            if result.changedBinaries.isEmpty && !menuChanged {
                print("Already patched; no files were changed.")
            } else {
                print("------ Resign ------")
                try Command.resign(app: options.app, modifiedBinaries: signingInputs)
                print("Patch and signing completed.")
            }

            Darwin.exit(EXIT_SUCCESS)
        }
    }

}

// MARK: Tweak
struct Tweak: AsyncParsableCommand {
    enum Error: LocalizedError {
        case invalidApp
        case invalidConfig
        case invalidVersion
        case unsupportedVersion

        var errorDescription: String? {
            switch self {
            case .invalidApp:
                return "Invalid app path"
            case .invalidConfig:
                return "Invalid patch config"
            case .invalidVersion:
                return "Invalid app version"
            case .unsupportedVersion:
                return "Unsupported WeChat version"
            }
        }
    }

    struct Options: ParsableArguments {
        @Option(
            name: .shortAndLong,
            help: "Path of WeChat.app",
            transform: {
                guard FileManager.default.fileExists(atPath: $0) else {
                    throw Error.invalidApp
                }
                return URL(fileURLWithPath: $0)
            }
        )
        var app: URL = URL(fileURLWithPath: "/Applications/WeChat.app", isDirectory: true)

        @Option(
            name: .shortAndLong,
            help: "Local path or Remote URL of config.json",
            transform: {
                if FileManager.default.fileExists(atPath: $0) {
                    return URL(fileURLWithPath: $0)
                } else {
                    guard let url = URL(string: $0) else {
                        throw Error.invalidConfig
                    }
                    return url
                }
            }
        )
        var config: URL = Tweak.defaultConfigURL
    }

    static let configuration = CommandConfiguration(
        commandName: "wechattweak",
        abstract: "A command-line tool for tweaking WeChat.",
        subcommands: [
            Versions.self,
            Patch.self
        ]
    )

    static var defaultConfigURL: URL {
        let local = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("config.json")
        if FileManager.default.fileExists(atPath: local.path) {
            return local
        }
        return URL(
            string: "https://raw.githubusercontent.com/sunnyyoung/WeChatTweak/refs/heads/master/config.json"
        )!
    }

    mutating func run() async throws {
        print(Tweak.helpMessage())
        Darwin.exit(EXIT_SUCCESS)
    }
}

Task {
    await Tweak.main()
}

Dispatch.dispatchMain()
