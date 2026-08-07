//
//  main.swift
//
//  A dependency-free command line entry point that builds with the Swift 5.3
//  toolchain available on macOS Catalina.
//

import Foundation

enum TweakError: LocalizedError {
    case invalidApp(String)
    case invalidConfig(String)
    case missingValue(String)
    case unsupportedVersion(String)
    case unknownCommand(String)
    case unknownOption(String)

    var errorDescription: String? {
        switch self {
        case let .invalidApp(path):
            return "Invalid app path: \(path)"
        case let .invalidConfig(value):
            return "Invalid config path or URL: \(value)"
        case let .missingValue(option):
            return "Missing value for \(option)"
        case let .unsupportedVersion(version):
            return "Unsupported WeChat build: \(version)"
        case let .unknownCommand(command):
            return "Unknown command: \(command)"
        case let .unknownOption(option):
            return "Unknown option: \(option)"
        }
    }
}

struct CLIOptions {
    var app = URL(fileURLWithPath: "/Applications/WeChat.app", isDirectory: true)
    var config = TweakCLI.defaultConfigURL
    var dryRun = false
    var noBackup = false
    var menuDylib: URL?
    var withoutMenu = false
}

enum TweakCLI {
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

    static func usage() -> String {
        return """
        USAGE: wechattweak <command> [options]

        COMMANDS:
          versions                 List current and supported WeChat builds
          patch                    Install the matching patch and recall runtime

        OPTIONS:
          -a, --app <path>         Path to WeChat.app
          -c, --config <path|url>  Patch configuration (defaults to ./config.json)
          --dry-run                Validate without changing WeChat.app
          --no-backup              Do not create .wechattweak-backup files
          --menu-dylib <path>      Explicit libWeChatTweakMenu.dylib path
          --without-menu           Do not install the runtime dylib
          -h, --help               Show this help
        """
    }

    static func parse(_ arguments: [String]) throws -> (String, CLIOptions) {
        guard let command = arguments.first else {
            return ("help", CLIOptions())
        }
        if command == "-h" || command == "--help" || command == "help" {
            return ("help", CLIOptions())
        }
        guard command == "versions" || command == "patch" else {
            throw TweakError.unknownCommand(command)
        }

        var options = CLIOptions()
        var index = 1
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "-h", "--help":
                return ("help", options)
            case "-a", "--app":
                index += 1
                guard index < arguments.count else {
                    throw TweakError.missingValue(argument)
                }
                let path = arguments[index]
                guard FileManager.default.fileExists(atPath: path) else {
                    throw TweakError.invalidApp(path)
                }
                options.app = URL(fileURLWithPath: path, isDirectory: true)
            case "-c", "--config":
                index += 1
                guard index < arguments.count else {
                    throw TweakError.missingValue(argument)
                }
                let value = arguments[index]
                if FileManager.default.fileExists(atPath: value) {
                    options.config = URL(fileURLWithPath: value)
                } else if let url = URL(string: value), url.scheme != nil {
                    options.config = url
                } else {
                    throw TweakError.invalidConfig(value)
                }
            case "--dry-run":
                options.dryRun = true
            case "--no-backup":
                options.noBackup = true
            case "--menu-dylib":
                index += 1
                guard index < arguments.count else {
                    throw TweakError.missingValue(argument)
                }
                options.menuDylib = URL(fileURLWithPath: arguments[index])
            case "--without-menu":
                options.withoutMenu = true
            default:
                throw TweakError.unknownOption(argument)
            }
            index += 1
        }
        return (command, options)
    }

    static func runVersions(_ options: CLIOptions) throws {
        print("------ Current version ------")
        print(try Command.version(app: options.app))
        print("------ Supported versions ------")
        for config in try Config.load(url: options.config) {
            print(config.version)
        }
    }

    static func runPatch(_ options: CLIOptions) throws {
        print("------ Version ------")
        let version = try Command.version(app: options.app)
        print("WeChat version: \(version)")

        print("------ Config ------")
        guard let config = try Config.load(url: options.config).first(where: {
            $0.version == version
        }) else {
            throw TweakError.unsupportedVersion(version)
        }
        print("Matched build \(config.version), \(config.targets.count) target groups")

        var resolvedMenuRuntime: URL?
        if !options.withoutMenu {
            print("------ Runtime preflight ------")
            let runtime = try MenuInstaller.resolveRuntime(explicitURL: options.menuDylib)
            let report = try MenuInstaller.preflight(app: options.app, runtime: runtime)
            resolvedMenuRuntime = runtime
            print("Runtime: \(runtime.path)")
            print(
                "Loader: \(report.injectedArchitectures.count) to inject, "
                    + "\(report.alreadyInjectedArchitectures.count) already injected"
            )
        }

        print("------ Patch ------")
        let result = try Command.patch(
            app: options.app,
            config: config,
            dryRun: options.dryRun,
            createBackup: !options.noBackup
        )
        if options.dryRun {
            print("Dry run passed; no files were changed.")
            return
        }

        var signingInputs = result.changedBinaries
        var runtimeChanged = false
        if let runtime = resolvedMenuRuntime {
            print("------ Runtime ------")
            let report = try MenuInstaller.install(
                app: options.app,
                runtime: runtime,
                createBackup: !options.noBackup
            )
            runtimeChanged = true
            signingInputs.append(report.destination)
            signingInputs.append(report.executable)
            print("Installed: \(report.destination.path)")
            print(
                "Loader: \(report.injector.injectedArchitectures.count) injected, "
                    + "\(report.injector.alreadyInjectedArchitectures.count) already injected"
            )
        }

        if result.changedBinaries.isEmpty && !runtimeChanged {
            print("Already patched; no files were changed.")
        } else {
            print("------ Resign ------")
            try Command.resign(app: options.app, modifiedBinaries: signingInputs)
            print("Patch and signing completed.")
        }
    }

    static func main() {
        do {
            let (command, options) = try parse(Array(CommandLine.arguments.dropFirst()))
            switch command {
            case "versions":
                try runVersions(options)
            case "patch":
                try runPatch(options)
            default:
                print(usage())
            }
        } catch {
            fputs("Error: \(error.localizedDescription)\n", stderr)
            fputs("\n\(usage())\n", stderr)
            exit(EXIT_FAILURE)
        }
    }
}

TweakCLI.main()
