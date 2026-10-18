#if os(macOS)
import CryptoKit
import Foundation
import Testing

/// The shell guards `make verify` runs, each driven against scratch files,
/// so a guard that stops catching what it is for fails here.
struct ScriptGuardTests {
    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()

    static func script(_ name: String) -> String { root.appendingPathComponent("scripts/\(name)").path }

    /// Runs `arguments` in `folder` with `environment` added, and gives back
    /// the exit status.
    @discardableResult
    static func run(_ arguments: [String], in folder: URL, environment: [String: String] = [:]) throws -> Int32 {
        try output(arguments, in: folder, environment: environment).status
    }

    /// The same, with everything it printed.
    static func output(_ arguments: [String], in folder: URL,
                       environment: [String: String] = [:]) throws -> (status: Int32, text: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = arguments
        process.currentDirectoryURL = folder
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { $1 }
        // Into a file, so a long run never fills a pipe and stalls.
        let log = folder.appendingPathComponent(".guard-\(UUID().uuidString).log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: log) }
        let handle = try FileHandle(forWritingTo: log)
        defer { try? handle.close() }
        process.standardOutput = handle
        process.standardError = handle
        try process.run()
        process.waitUntilExit()
        return (process.terminationStatus, try String(contentsOf: log, encoding: .utf8))
    }

    /// Writes `text` to `name` in `folder` as a script that can run.
    @discardableResult
    static func script(_ text: String, named name: String, in folder: URL) throws -> URL {
        let url = folder.appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    func scratchFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("guard-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("Config"),
                                                withIntermediateDirectories: true)
        return folder
    }

    // MARK: The local config check

    /// A guard against committing a real address fails when it can't look.
    @Test func theLocalConfigCheckFailsWhenItCantLook() throws {
        let folder = try scratchFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(try Self.run(["sh", Self.script("local-config-check.sh"), folder.path], in: folder) == 1)
        #expect(try Self.run(["sh", Self.script("local-config-check.sh"), folder.appendingPathComponent("nowhere").path],
                             in: folder) == 1)
    }

    /// A tracked config that sets an address fails, whichever file it is.
    @Test func theLocalConfigCheckFailsWhenATrackedConfigSetsAnAddress() throws {
        let repo = try scratchFolder()
        defer { try? FileManager.default.removeItem(at: repo) }
        let check = Self.script("local-config-check.sh")
        #expect(try Self.run(["git", "init", "--quiet"], in: repo) == 0)
        let config = repo.appendingPathComponent("Config/Cloud.xcconfig")
        try Data("// An empty address.\nPEBBLE_CLOUD_ENDPOINT =\n".utf8).write(to: config)
        #expect(try Self.run(["git", "add", "Config/Cloud.xcconfig"], in: repo) == 0)
        #expect(try Self.run(["sh", check, repo.path], in: repo) == 0)
        try Data("PEBBLE_CLOUD_ENDPOINT = https:/$()/cloud.example.com\n".utf8).write(to: config)
        #expect(try Self.run(["sh", check, repo.path], in: repo) == 1)
        // A comment after an empty value is still empty.
        try Data("PEBBLE_CLOUD_ENDPOINT = // none yet\n".utf8).write(to: config)
        #expect(try Self.run(["sh", check, repo.path], in: repo) == 0)
        // A conditional setting is a setting too.
        for line in ["PEBBLE_CLOUD_ENDPOINT[config=Debug] = https:/$()/cloud.example.com\n",
                     "PEBBLE_CLOUD_ENDPOINT[sdk=*] = https:/$()/cloud.example.com\n",
                     "  PEBBLE_CLOUD_ENDPOINT[sdk=iphoneos*][arch=*]=https:/$()/cloud.example.com\n"] {
            try Data(line.utf8).write(to: config)
            #expect(try Self.run(["sh", check, repo.path], in: repo) == 1, "\(line)")
        }
        try Data("PEBBLE_CLOUD_ENDPOINT[config=Debug] =\n".utf8).write(to: config)
        #expect(try Self.run(["sh", check, repo.path], in: repo) == 0)
        // A tracked file with a space in its name is still one file.
        let spaced = repo.appendingPathComponent("Config/My Cloud.xcconfig")
        try Data("PEBBLE_CLOUD_ENDPOINT = https:/$()/cloud.example.com\n".utf8).write(to: spaced)
        #expect(try Self.run(["git", "add", "Config/My Cloud.xcconfig"], in: repo) == 0)
        #expect(try Self.run(["sh", check, repo.path], in: repo) == 1)
    }

    /// project.yml carries build settings too: an address in any of its
    /// settings, plain or conditional, or written straight into the
    /// Info.plist key, fails. Passing the setting through, or leaving it
    /// empty, passes.
    @Test func theLocalConfigCheckFailsWhenProjectYmlSetsAnAddress() throws {
        let repo = try scratchFolder()
        defer { try? FileManager.default.removeItem(at: repo) }
        let check = Self.script("local-config-check.sh")
        #expect(try Self.run(["git", "init", "--quiet"], in: repo) == 0)
        let project = repo.appendingPathComponent("project.yml")
        let passThrough = "targets:\n  Pebble:\n    info:\n      properties:\n        PebbleCloudEndpoint: $(PEBBLE_CLOUD_ENDPOINT)\n"
        try Data(passThrough.utf8).write(to: project)
        #expect(try Self.run(["git", "add", "project.yml"], in: repo) == 0)
        #expect(try Self.run(["sh", check, repo.path], in: repo) == 0)
        for settings in ["    settings:\n      PEBBLE_CLOUD_ENDPOINT: https://cloud.example.com\n",
                         "    settings:\n      configs:\n        Debug:\n          PEBBLE_CLOUD_ENDPOINT: \"https://cloud.example.com\"\n",
                         "    settings:\n      \"PEBBLE_CLOUD_ENDPOINT[sdk=*]\": https://cloud.example.com # mine\n"] {
            try Data((passThrough + settings).utf8).write(to: project)
            #expect(try Self.run(["sh", check, repo.path], in: repo) == 1, "\(settings)")
        }
        for empty in ["    settings:\n      PEBBLE_CLOUD_ENDPOINT: \"\"\n", "    settings:\n      PEBBLE_CLOUD_ENDPOINT:\n"] {
            try Data((passThrough + empty).utf8).write(to: project)
            #expect(try Self.run(["sh", check, repo.path], in: repo) == 0, "\(empty)")
        }
        let written = passThrough.replacingOccurrences(of: "$(PEBBLE_CLOUD_ENDPOINT)", with: "https://cloud.example.com")
        try Data(written.utf8).write(to: project)
        #expect(try Self.run(["sh", check, repo.path], in: repo) == 1)
        // The project's own file passes.
        #expect(try Self.run(["sh", check], in: Self.root) == 0)
    }

    /// A tracked config it can't read, such as one deleted from the working
    /// tree, fails rather than reading as empty.
    @Test func theLocalConfigCheckFailsWhenATrackedConfigCantBeRead() throws {
        let repo = try scratchFolder()
        defer { try? FileManager.default.removeItem(at: repo) }
        let check = Self.script("local-config-check.sh")
        #expect(try Self.run(["git", "init", "--quiet"], in: repo) == 0)
        let config = repo.appendingPathComponent("Config/Cloud.xcconfig")
        try Data("PEBBLE_CLOUD_ENDPOINT =\n".utf8).write(to: config)
        #expect(try Self.run(["git", "add", "Config/Cloud.xcconfig"], in: repo) == 0)
        #expect(try Self.run(["sh", check, repo.path], in: repo) == 0)
        try FileManager.default.removeItem(at: config)
        #expect(try Self.run(["sh", check, repo.path], in: repo) == 1)
        // Root reads a file whatever its permissions say, so a runner that
        // runs as root can't make one unreadable this way; there, the
        // deleted file above is the check.
        guard getuid() != 0 else { return }
        try Data("PEBBLE_CLOUD_ENDPOINT =\n".utf8).write(to: config)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: config.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: config.path) }
        #expect(try Self.run(["sh", check, repo.path], in: repo) == 1)
    }

    // MARK: The Release check

    /// What Xcode sets for a script phase in a build, and only then.
    static func inBuild(_ folder: URL) -> [String: String] {
        ["TARGET_BUILD_DIR": folder.path, "SCRIPT_INPUT_FILE_COUNT": "1"]
    }

    /// Inside a build, only Debug that isn't an archive may keep an address.
    /// Every other build with one fails, whatever its configuration is
    /// called, and an archive fails even in Debug. An empty one passes.
    @Test func theReleaseCheckFailsWhenAReleaseBuildHasAnAddress() throws {
        let folder = try scratchFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let check = Self.script("release-endpoint-check.sh")
        func status(_ configuration: String, _ endpoint: String, action: String = "build") throws -> Int32 {
            try Self.run(["sh", check], in: folder, environment: Self.inBuild(folder).merging([
                "CONFIGURATION": configuration, "PEBBLE_CLOUD_ENDPOINT": endpoint, "ACTION": action,
                "PEBBLE_CLOUD_POLICY": "",
            ]) { $1 })
        }
        let address = "https://cloud.example.com"
        for configuration in ["Release", "TestFlight", "Beta", "Profile", "debug", "Debug2"] {
            #expect(try status(configuration, address) == 1, "\(configuration)")
            #expect(try status(configuration, "") == 0, "\(configuration)")
            #expect(try status(configuration, "  ") == 0, "\(configuration)")
        }
        // An archive is `install` to xcodebuild, whatever the configuration.
        for action in ["install", "archive"] {
            #expect(try status("Debug", address, action: action) == 1, "\(action)")
            #expect(try status("Release", address, action: action) == 1, "\(action)")
            #expect(try status("Debug", "", action: action) == 0, "\(action)")
        }
        #expect(try status("Debug", address) == 0)
        #expect(try status("Debug", address, action: "") == 0)
    }

    /// The policy version the app's words describe, read from the source
    /// as the check reads it.
    static func currentPolicy() throws -> String {
        let source = try String(contentsOf: root.appendingPathComponent(
            "Packages/PebbleKit/Sources/PebbleCore/CloudPolicy.swift"), encoding: .utf8)
        let line = try #require(source.split(separator: "\n").first { $0.contains("public static let currentVersion = ") })
        return String(try #require(line.split(separator: "\"").dropFirst().first))
    }

    /// A build that could ship may keep an address only with
    /// PEBBLE_CLOUD_POLICY equal to the policy the app shows and a plain
    /// https address. No policy, another one, or http fails, each saying
    /// what to fix and never the address. An empty address passes, and
    /// then the cloud can't be turned on (`anEmptyAddressCantBeTurnedOn`).
    @Test func theReleaseCheckPassesAShippedBuildOnlyWithTheCurrentPolicy() throws {
        let folder = try scratchFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let check = Self.script("release-endpoint-check.sh")
        let policy = try Self.currentPolicy()
        #expect(policy == "mdx-zero-retention-2")
        func run(_ endpoint: String, _ policy: String, configuration: String = "Release",
                 action: String = "build") throws -> (status: Int32, text: String) {
            try Self.output(["sh", check], in: folder, environment: Self.inBuild(folder).merging([
                "CONFIGURATION": configuration, "PEBBLE_CLOUD_ENDPOINT": endpoint, "ACTION": action,
                "PEBBLE_CLOUD_POLICY": policy,
            ]) { $1 })
        }
        let address = "https://secret-host.example.com/base"
        // No policy key with an address fails, and says to set it.
        let none = try run(address, "")
        #expect(none.status == 1)
        #expect(none.text.contains("PEBBLE_CLOUD_POLICY is not set"))
        #expect(none.text.contains("Set PEBBLE_CLOUD_POLICY = \(policy) in Config/Cloud.xcconfig"))
        // Another policy version fails, says the policy changed, and names
        // both. The version before this one, which the words no longer
        // describe, is among them.
        for other in ["mdx-zero-retention-1", "mdx-zero-retention-0", policy + "x", "MDX-ZERO-RETENTION-2"] {
            let wrong = try run(address, other)
            #expect(wrong.status == 1, "\(other)")
            #expect(wrong.text.contains("The cloud policy changed: PEBBLE_CLOUD_POLICY is \(other), but the app shows the \(policy) policy."),
                    "\(other)")
        }
        // Plain http, or an address that isn't plain, fails.
        for bad in ["http://secret-host.example.com", "HTTPS://secret-host.example.com", "https://",
                    "https://user@secret-host.example.com", "https://secret-host.example.com/?key=1",
                    "https://secret-host.example.com/#x", "https://secret host.example.com", "secret-host.example.com"] {
            let refused = try run(bad, policy)
            #expect(refused.status == 1, "\(bad)")
            #expect(refused.text.contains("Write it as https:// and a host"), "\(bad)")
            #expect(!refused.text.contains("secret"), "\(bad)")
        }
        // The current policy and a plain https address pass, in every
        // configuration and an archive too.
        for configuration in ["Release", "TestFlight", "Debug"] {
            for action in ["build", "install", "archive"] {
                #expect(try run(address, policy, configuration: configuration, action: action).status == 0,
                        "\(configuration) \(action)")
            }
        }
        #expect(try run(" \(address) ", " \(policy) ").status == 0)
        // An empty address passes with or without a policy.
        for empty in ["", "  "] {
            #expect(try run(empty, "").status == 0)
            #expect(try run(empty, policy).status == 0)
            #expect(try run(empty, "mdx-zero-retention-0").status == 0)
        }
        #expect(!none.text.contains("secret-host"))
    }

    /// On its own, the check reads the policy from the settings beside the
    /// address, the same way.
    @Test func theReleaseCheckOnItsOwnPassesOnlyWithTheCurrentPolicy() throws {
        let folder = try scratchFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let check = Self.script("release-endpoint-check.sh")
        let policy = try Self.currentPolicy()
        func settings(_ endpoint: String, _ policy: String?) -> String {
            let address = "    PEBBLE_CLOUD_ENDPOINT = \(endpoint)"
            return policy.map { address + "' '    PEBBLE_CLOUD_POLICY = \($0)" } ?? address
        }
        func status(_ endpoint: String, _ policy: String?) throws -> (status: Int32, text: String) {
            let environment = try fakeXcodebuild(in: folder, configurations: ["Debug", "Release"],
                                                 settings: ["Release": settings(endpoint, policy)])
            return try Self.output(["sh", check], in: folder, environment: environment)
        }
        let address = "https://secret-host.example.com"
        let none = try status(address, nil)
        #expect(none.status == 1)
        #expect(none.text.contains("PEBBLE_CLOUD_POLICY is not set"))
        #expect(try status(address, "").status == 1)
        #expect(try status(address, "mdx-zero-retention-0").status == 1)
        let old = try status(address, "mdx-zero-retention-1")
        #expect(old.status == 1)
        #expect(old.text.contains("The cloud policy changed: PEBBLE_CLOUD_POLICY is mdx-zero-retention-1, but the app shows the \(policy) policy."))
        #expect(try status("http://secret-host.example.com", policy).status == 1)
        #expect(try status(address, policy).status == 0)
        #expect(try status("", nil).status == 0)
        #expect(try status("", policy).status == 0)
        // Two policies that disagree fail.
        let two = settings(address, policy) + "' '    PEBBLE_CLOUD_POLICY = mdx-zero-retention-0"
        let environment = try fakeXcodebuild(in: folder, configurations: ["Debug", "Release"], settings: ["Release": two])
        #expect(try Self.run(["sh", check], in: folder, environment: environment) == 1)
        #expect(!none.text.contains("secret-host"))
    }

    /// The address is meant for one machine, so a failing build says only
    /// that one is set, never what it is.
    @Test func theReleaseCheckNeverPrintsTheAddress() throws {
        let folder = try scratchFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let run = try Self.output(["sh", Self.script("release-endpoint-check.sh")], in: folder,
                                  environment: Self.inBuild(folder).merging([
            "CONFIGURATION": "Release", "PEBBLE_CLOUD_ENDPOINT": "https://secret-host.example.com", "ACTION": "build",
        ]) { $1 })
        #expect(run.status == 1)
        #expect(run.text.contains("PEBBLE_CLOUD_ENDPOINT is set"))
        #expect(!run.text.contains("secret-host"))
    }

    /// A CONFIGURATION left in a shell, or set by CI, is not a build: the
    /// check on its own still reads every configuration and fails on an
    /// address, rather than passing as if Xcode had run it.
    @Test func aStrayConfigurationInTheShellDoesNotSkipTheCheck() throws {
        let folder = try scratchFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let set = "    PEBBLE_CLOUD_ENDPOINT = https://cloud.example.com"
        var environment = try fakeXcodebuild(in: folder, configurations: ["Debug", "Release"],
                                             settings: ["Release": set])
        for stray in ["Release", "Debug"] {
            environment["CONFIGURATION"] = stray
            #expect(try Self.run(["sh", Self.script("release-endpoint-check.sh")], in: folder,
                                 environment: environment) == 1, "\(stray)")
        }
        let asked = try String(contentsOf: folder.appendingPathComponent("asked.txt"), encoding: .utf8)
        #expect(asked == "Pebble Release\nPebble Release\n", "the configurations were read each time")
    }

    /// A stand-in for xcodebuild with the configurations and settings
    /// given, so the check on its own can be driven without a project.
    ///
    /// Each settings text is spliced into the stand-in between single
    /// quotes, as one argument to printf. A text that holds `' '` closes
    /// the quote and opens another, so printf gets two arguments and
    /// prints two lines: that is how the disagreeing settings fixture
    /// prints two values.
    func fakeXcodebuild(in folder: URL, configurations: [String], settings: [String: String]) throws -> [String: String] {
        let bin = folder.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        var cases = ""
        for (configuration, text) in settings {
            cases += "  \(configuration)) printf '%s\\n' '\(text)' ;;\n"
        }
        let list = configurations.map { "        \($0)" }.joined(separator: "\n")
        try Self.script("""
        #!/bin/sh
        case " $* " in
          *" -list "*) printf '%s\\n' 'Information about project "Pebble":' '    Build Configurations:' '\(list)' '' '    Schemes:' '        Pebble'; exit 0 ;;
        esac
        configuration=""
        target=""
        while [ $# -gt 0 ]; do
          case "$1" in
            -configuration) configuration="$2" ;;
            -target) target="$2" ;;
          esac
          shift
        done
        echo "$target $configuration" >> "\(folder.path)/asked.txt"
        case "$configuration" in
        \(cases)  *) exit 65 ;;
        esac
        """, named: "xcodebuild", in: bin)
        return ["PATH": bin.path + ":" + (ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"),
                "CONFIGURATION": ""]
    }

    /// On its own, it reads the app target's settings in every
    /// configuration but Debug, and fails if any has an address, whatever
    /// that configuration is called.
    @Test func theReleaseCheckOnItsOwnChecksEveryConfigurationButDebug() throws {
        let folder = try scratchFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let check = Self.script("release-endpoint-check.sh")
        let set = "    PEBBLE_CLOUD_ENDPOINT = https://cloud.example.com"
        let empty = "    PEBBLE_CLOUD_ENDPOINT = "
        let fine = try fakeXcodebuild(in: folder, configurations: ["Debug", "Release", "TestFlight"],
                                      settings: ["Debug": set, "Release": empty, "TestFlight": empty])
        #expect(try Self.run(["sh", check], in: folder, environment: fine) == 0)
        let asked = try String(contentsOf: folder.appendingPathComponent("asked.txt"), encoding: .utf8)
        #expect(asked == "Pebble Release\nPebble TestFlight\n", "the app target only, and never Debug")
        let beta = try fakeXcodebuild(in: folder, configurations: ["Debug", "Release", "TestFlight"],
                                      settings: ["Debug": empty, "Release": empty, "TestFlight": set])
        let run = try Self.output(["sh", check], in: folder, environment: beta)
        #expect(run.status == 1)
        #expect(!run.text.contains("cloud.example.com"))
    }

    /// Settings that disagree about the address, as two targets with their
    /// own would, fail rather than trusting the first one printed.
    @Test func theReleaseCheckFailsWhenTheSettingsDisagree() throws {
        let folder = try scratchFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let both = "    PEBBLE_CLOUD_ENDPOINT = ' '    PEBBLE_CLOUD_ENDPOINT = https://cloud.example.com"
        let environment = try fakeXcodebuild(in: folder, configurations: ["Debug", "Release"],
                                             settings: ["Release": both])
        #expect(try Self.run(["sh", Self.script("release-endpoint-check.sh")], in: folder, environment: environment) == 1)
    }

    /// Outside a build it asks xcodebuild, and fails when it can't.
    @Test func theReleaseCheckFailsWhenItCantReadTheSettings() throws {
        let folder = try scratchFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let check = Self.script("release-endpoint-check.sh")
        let missing = folder.appendingPathComponent("Missing.xcodeproj").path
        #expect(try Self.run(["sh", check, missing], in: folder, environment: ["CONFIGURATION": ""]) == 1)
        // It lists the configurations, but can't read one of them.
        let environment = try fakeXcodebuild(in: folder, configurations: ["Debug", "Release"], settings: [:])
        #expect(try Self.run(["sh", check], in: folder, environment: environment) == 1)
    }

    /// The check is a pre-build phase of the app target itself, with
    /// nothing that lets it fail quietly, and `make build-release` runs it
    /// before it builds.
    @Test func everyReleaseBuildRunsTheCheck() throws {
        let project = try String(contentsOf: Self.root.appendingPathComponent("project.yml"), encoding: .utf8)
        let targets = try #require(project.range(of: "\ntargets:"))
        let app = try #require(project.range(of: "\n  Pebble:\n", range: targets.upperBound..<project.endIndex))
        let next = project.range(of: "\n  [A-Za-z]+:\n", options: .regularExpression,
                                 range: app.upperBound..<project.endIndex)?.lowerBound ?? project.endIndex
        let appTarget = project[app.upperBound..<next]
        let phases = try #require(appTarget.range(of: "    preBuildScripts:\n"))
        let phase = appTarget[phases.upperBound...].split(separator: "\n").prefix(3)
        #expect(phase.first?.hasPrefix("      - name: ") == true)
        #expect(phase.dropFirst().first == "        script: sh \"$SRCROOT/scripts/release-endpoint-check.sh\"")
        // Every build, not only one whose inputs changed.
        #expect(phase.last == "        basedOnDependencyAnalysis: false")
        for loophole in ["|| true", "|| exit 0", "continue-on-error", "; true"] {
            #expect(!appTarget.contains(loophole), "\(loophole)")
        }
        let makefile = try String(contentsOf: Self.root.appendingPathComponent("Makefile"), encoding: .utf8)
        #expect(makefile.contains("build-release: generate\n\tsh scripts/release-endpoint-check.sh\n"))
    }

    // MARK: The comment lint

    /// Review history and people's names in comments fail; the same words
    /// outside a comment, or words that only look alike, pass.
    @Test func theCommentLintCatchesReviewHistoryAndNames() throws {
        let folder = try scratchFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let lint = Self.script("comment-lint.sh")
        // Made-up names under a made-up salt, hashed here and not by the
        // lint, so no real name is ever in the repository and a lint that
        // stops hashing as it promises misses them.
        let salt = "0badc0de5a17ed00feedfacecafebeef"
        let hashes = folder.appendingPathComponent("names.sha256")
        try Data((["# Made up.", "salt: \(salt)"] + ["ada byron", "jo ann", "quillon"].map { Self.sha256(salt + $0) })
            .joined(separator: "\n").appending("\n").utf8).write(to: hashes)
        func lintRun(_ file: URL) throws -> Int32 {
            try Self.run(["sh", lint, "--hashes", hashes.path, file.path], in: folder)
        }
        let names = ["Ada Byron", "Jo.Ann", "Quillon"]
        // Built from pieces, so this file never holds what the lint looks for.
        let fix = "Fix", round = "round", item = "item"
        var bad: [(name: String, text: String)] = [
            ("a.swift", "    // MARK: \(fix) \(round) 5\n"),
            ("b.swift", "    // fix \(round.uppercased()) 5\n"),
            ("bb.swift", "    // MARK: \(fix.uppercased())ED \(round.uppercased())\n"),
            ("c.swift", "/// Asked for in \(item) 11.\n"),
            ("d.swift", "let x = 1 // since \(round) 4\n"),
            ("e.swift", "/*\n * What this guards.\n * \(fix) \(round) 3\n */\n"),
            ("f.swift", "/* \(fix) \(round) 2 */\n"),
            ("g.sh", "# \(fix) \(round) 3 asked for this\n"),
            ("project.yml", "targets: # since \(round) 2\n"),
            ("manifest.txt", "# \(fix) \(round) 4 follow-ups\ntest: aTest\n"),
        ]
        for (index, name) in names.enumerated() {
            bad.append(("name\(index).swift", "/// \(name) decided this.\n"))
            bad.append(("lower\(index).swift", "/// thanks to \(name.lowercased())\n"))
            bad.append(("possessive\(index).swift", "// \(name)'s call\n"))
            bad.append(("curly\(index).swift", "// \(name.uppercased())\u{2019}s call\n"))
        }
        for (name, text) in bad {
            let file = folder.appendingPathComponent(name)
            try Data(text.utf8).write(to: file)
            #expect(try lintRun(file) == 1, "missed: \(text)")
            try FileManager.default.removeItem(at: file)
        }
        let good = folder.appendingPathComponent("Good.swift")
        try Data(("/// Rounds to 4 places.\n#expect(text.contains(\"\(fix) \(round) 5\"))\n"
                  + "let url = \"https://example.com/\(item) 3\"\n"
                  + "let who = \"Quillon\" // a sample\n"
                  + "/// Quill, Quillons, Ada alone and Byron alone are no name.\n").utf8).write(to: good)
        #expect(try lintRun(good) == 0)
        // A name of two words matches across any space; a symbol in a name
        // only splits its words.
        let two = folder.appendingPathComponent("Two.swift")
        try Data("// asked by Ada   Byron\n".utf8).write(to: two)
        #expect(try lintRun(two) == 1)
        try Data("// JoXAnn is a made-up word\n".utf8).write(to: two)
        #expect(try lintRun(two) == 0)
        // A match says where, and never the name.
        try Data("// asked by Ada Byron\n".utf8).write(to: two)
        let found = try Self.output(["sh", lint, "--hashes", hashes.path, two.path], in: folder)
        #expect(found.status == 1)
        #expect(found.text.contains("Two.swift:1: a name from the list"))
        #expect(!found.text.lowercased().contains("byron"))
        // A hash file it can't read, or with no salt, is an error.
        #expect(try Self.run(["sh", lint, "--hashes", folder.appendingPathComponent("nowhere").path, good.path],
                             in: folder) == 1)
        let text = try String(contentsOf: hashes, encoding: .utf8)
        try Data(text.replacingOccurrences(of: "salt: \(salt)\n", with: "").utf8).write(to: hashes)
        #expect(try lintRun(good) == 1)
        #expect(try Self.run(["sh", lint, "--self-test"], in: folder) == 0)
    }

    static func sha256(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// The real names are never in the repository in plain text: no list
    /// is committed, the local one is ignored by git, and the committed
    /// file holds one salt and then only hashes and comments.
    @Test func theNamesAreCommittedOnlyAsSaltedHashes() throws {
        #expect(!FileManager.default.fileExists(atPath: Self.script("comment-lint-names.txt")))
        let ignore = try String(contentsOf: Self.root.appendingPathComponent(".gitignore"), encoding: .utf8)
        #expect(ignore.split(separator: "\n").contains("Config/comment-lint-names.local.txt"))
        let committed = try String(contentsOf: Self.root.appendingPathComponent("Config/comment-lint-names.sha256"),
                                   encoding: .utf8)
        #expect(Self.hashFileProblems(committed).isEmpty, "\(Self.hashFileProblems(committed))")
        #expect(!Self.hashFileProblems("# no salt\n\(Self.sha256("x"))\n").isEmpty)
        #expect(!Self.hashFileProblems("salt: 0badc0de5a17ed00feedfacecafebeef\nquillon\n").isEmpty)
        #expect(!Self.hashFileProblems("salt: 0badc0de5a17ed00feedfacecafebeef\n\n").isEmpty)
        // A copy of the lint in a scratch repository with no hash file
        // fails, rather than checking no names.
        let folder = try scratchFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("scripts"),
                                                withIntermediateDirectories: true)
        let lint = folder.appendingPathComponent("scripts/comment-lint.sh")
        try FileManager.default.copyItem(atPath: Self.script("comment-lint.sh"), toPath: lint.path)
        let code = folder.appendingPathComponent("Code.swift")
        try Data("/// Rounds to 4 places.\nlet x = 1\n".utf8).write(to: code)
        #expect(try Self.run(["sh", lint.path, code.path], in: folder) == 1)
        // --hash-names hashes a made-up local list with a fresh salt, and
        // keeps that salt when run again.
        let local = folder.appendingPathComponent("Config/comment-lint-names.local.txt")
        let made = folder.appendingPathComponent("Config/comment-lint-names.sha256")
        try Data("# Made up.\n\nQuillon\nAda  Byron\n".utf8).write(to: local)
        let hashed = try Self.output(["sh", lint.path, "--hash-names"], in: folder)
        #expect(hashed.status == 0, "\(hashed.text)")
        #expect(!hashed.text.lowercased().contains("quillon"), "it never prints the list")
        let first = try String(contentsOf: made, encoding: .utf8)
        #expect(Self.hashFileProblems(first).isEmpty, "\(Self.hashFileProblems(first))")
        let salt = String(try #require(first.split(separator: "\n").first { $0.hasPrefix("salt: ") }?.dropFirst(6)))
        let hashes = first.split(separator: "\n").filter { !$0.hasPrefix("#") && !$0.hasPrefix("salt: ") }.map(String.init)
        #expect(Set(hashes) == Set(["quillon", "ada byron"].map { Self.sha256(salt + $0) }))
        #expect(try Self.run(["sh", lint.path, "--hash-names"], in: folder) == 0)
        #expect(try String(contentsOf: made, encoding: .utf8) == first)
        // In step with the local list the lint passes and finds the names;
        // behind it, it fails until the hash file is rebuilt.
        #expect(try Self.run(["sh", lint.path, code.path], in: folder) == 0)
        try Data("/// Quillon asked for this.\n".utf8).write(to: code)
        #expect(try Self.run(["sh", lint.path, code.path], in: folder) == 1)
        try Data("/// Rounds to 4 places.\n".utf8).write(to: code)
        try Data("Quillon\nAda Byron\nZeno Quark\n".utf8).write(to: local)
        #expect(try Self.run(["sh", lint.path, code.path], in: folder) == 1)
        #expect(try Self.run(["sh", lint.path, "--hash-names"], in: folder) == 0)
        #expect(try Self.run(["sh", lint.path, code.path], in: folder) == 0)
    }

    /// What is wrong with a hash file: it must hold exactly one salt line
    /// of 32 hex digits, and every other line is a hash of 64 or a comment.
    static func hashFileProblems(_ text: String) -> [String] {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).dropLast(text.hasSuffix("\n") ? 1 : 0)
        func isHex(_ text: Substring, count: Int) -> Bool {
            text.count == count && text.allSatisfy { "0123456789abcdef".contains($0) }
        }
        func isSalt(_ line: Substring) -> Bool { line.hasPrefix("salt: ") && isHex(line.dropFirst(6), count: 32) }
        var problems = lines.enumerated().compactMap { index, line in
            isSalt(line) || isHex(line, count: 64) || line.hasPrefix("#")
                ? nil : "line \(index + 1) is not the salt, a hash or a comment"
        }
        let salts = lines.filter(isSalt).count
        if salts != 1 { problems.append("\(salts) salt lines") }
        return problems
    }

    /// CI runs the lint with no secret, a fork's pull request included.
    @Test func ciRunsTheCommentLintWithNoSecret() throws {
        let workflow = try String(contentsOf: Self.root.appendingPathComponent(".github/workflows/ci.yml"), encoding: .utf8)
        #expect(!workflow.contains("COMMENT_LINT"))
        #expect(!workflow.contains("secrets."))
        let verify = try #require(workflow.range(of: "      - name: Verify\n"))
        #expect(workflow[verify.upperBound...].hasPrefix("        run: make verify\n"))
    }

    /// The lint looks at project.yml, the Makefile and the mutation
    /// manifest too, not only the code folders.
    @Test func theCommentLintCoversTheProjectFiles() throws {
        let lint = try String(contentsOf: URL(fileURLWithPath: Self.script("comment-lint.sh")), encoding: .utf8)
        let defaults = try #require(lint.split(separator: "\n").first { $0.contains("|| set -- ") })
        for path in ["Packages/PebbleKit/Sources", "Packages/PebbleKit/Tests", "App", "AppUITests", "scripts",
                     "project.yml", "Makefile"] {
            #expect(defaults.contains(" \(path)"), "\(path)")
        }
        #expect(lint.contains("-name '*.txt'"))
        #expect(try Self.run(["sh", Self.script("comment-lint.sh")], in: Self.root) == 0)
    }

    /// `make verify` runs the lint, its self-test and the mutation check,
    /// the Release check by one rule (verify builds `build-release`, whose
    /// first step is the check, pinned in `everyReleaseBuildRunsTheCheck`),
    /// and the tests that only a Release build can run.
    @Test func verifyRunsTheCommentLintAndTheMutationCheck() throws {
        let makefile = try String(contentsOf: Self.root.appendingPathComponent("Makefile"), encoding: .utf8)
        let verify = try #require(makefile.split(separator: "\n").first { $0.hasPrefix("verify:") })
        let steps = verify.split(separator: " ")
        #expect(steps.contains("comment-lint"))
        #expect(steps.contains("mutation-check"))
        #expect(steps.contains("build-release"))
        #expect(steps.contains("release-test"))
        #expect(makefile.contains("comment-lint:\n\tsh scripts/comment-lint.sh --self-test\n\tsh scripts/comment-lint.sh\n"))
        #expect(makefile.contains("release-test:\n\tsh scripts/release-probe.sh\n"))
    }

    /// The release probe builds PebbleCore in Release, refuses to count a
    /// Debug build, and fails on any address read, from the raw setting or
    /// from Info.plist. `make release-test` runs it; this keeps it honest.
    @Test func theReleaseProbeRunsTheShippedCode() throws {
        let probe = try String(contentsOf: URL(fileURLWithPath: Self.script("release-probe.sh")), encoding: .utf8)
        #expect(probe.contains(#"swift run --package-path "$probe" -c release"#))
        #expect(probe.contains("#if DEBUG\nprint(\"release-probe: built as Debug, so it proves nothing\")\nexit(1)\n#else"))
        #expect(probe.contains("if CloudEndpoint.url(from: raw) != nil || reads([CloudEndpoint.infoKey: raw])\n"))
        #expect(probe.contains("    || reads([CloudEndpoint.infoKey: raw, CloudEndpoint.policyKey: policy + \"-other\"])\n"))
        #expect(probe.contains("    || reads([CloudEndpoint.infoKey: raw, CloudEndpoint.policyKey: \"mdx-zero-retention-1\"])\n"))
        #expect(probe.contains("    || reads([CloudEndpoint.infoKey: \"http://cloud.example.com\", CloudEndpoint.policyKey: policy])\n"))
        #expect(probe.contains("    || reads([CloudEndpoint.infoKey: \"\", CloudEndpoint.policyKey: policy]) {\n"))
        #expect(probe.contains("if !reads([CloudEndpoint.infoKey: raw, CloudEndpoint.policyKey: policy]) {\n"))
        #expect(probe.contains("let policy = CloudPolicy.currentVersion\n"))
        #expect(probe.contains("set -eu"))
        for loophole in ["|| true", "exit 0"] {
            #expect(!probe.contains(loophole), "\(loophole)")
        }
    }

    // MARK: The mutation check

    /// A scratch repository laid out as the mutation check expects, with
    /// one source file and a stand-in for swift. The stand-in knows four
    /// tests: `killsIt` fails once the code is broken, `survivesIt` never
    /// fails, `hangsWhenBroken` hangs once it is broken, leaving a helper
    /// of its own running as `swift test` does, and `hangsAlways` hangs
    /// even on the unbroken copy. Each helper's process id goes to the
    /// file `HELPERS` names, when it is set.
    func mutationRepo(manifest: String) throws -> (root: URL, environment: [String: String]) {
        let root = try scratchFolder()
        for part in ["scripts", "App", "AppUITests", ".github", "docs", "Packages/PebbleKit/Sources/Fixture"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(part),
                                                    withIntermediateDirectories: true)
        }
        for file in ["Makefile", "project.yml", ".gitignore", "README.md", "AGENTS.md"] {
            try Data().write(to: root.appendingPathComponent(file))
        }
        try FileManager.default.copyItem(atPath: Self.script("mutation-check.sh"),
                                         toPath: root.appendingPathComponent("scripts/mutation-check.sh").path)
        try Data("let works = true\n".utf8).write(to: root.appendingPathComponent("Packages/PebbleKit/Sources/Fixture/Code.swift"))
        try Data(manifest.utf8).write(to: root.appendingPathComponent("scripts/manifest.txt"))
        let swift = try Self.script(#"""
        #!/bin/sh
        [ "$1" = build ] && exit 0
        package=""
        filter=""
        while [ $# -gt 0 ]; do
          case "$1" in
            --package-path) package="$2" ;;
            --filter) filter="$2" ;;
          esac
          shift
        done
        works=no
        grep -q 'let works = true' "$package/Sources/Fixture/Code.swift" && works=yes
        ran=0
        failed=0
        for test in killsIt survivesIt hangsWhenBroken hangsAlways; do
          printf '/%s(' "$test" | grep -Eq -- "$filter" || continue
          ran=$((ran + 1))
          case "$test" in
            killsIt) [ "$works" = yes ] || failed=1 ;;
            hangsWhenBroken)
              if [ "$works" = no ]; then
                # Off the output, so only stopping the group can end it.
                sleep 30 >/dev/null 2>&1 &
                [ -n "${HELPERS:-}" ] && echo "$!" >> "$HELPERS"
                exec sleep 30
              fi
              ;;
            hangsAlways) exec sleep 30 ;;
          esac
          echo "✔ Test $test() passed"
        done
        echo "Test run with $ran tests"
        exit "$failed"
        """#, named: "fake-swift", in: root)
        return (root, ["MUTATION_SWIFT": swift.path, "MUTATION_TIMEOUT": "2", "MUTATION_BASELINE_TIMEOUT": "2"])
    }

    func mutationCheck(_ manifest: String, environment extra: [String: String] = [:]) throws -> (status: Int32, text: String) {
        let (root, environment) = try mutationRepo(manifest: manifest)
        defer { try? FileManager.default.removeItem(at: root) }
        return try Self.output(["sh", "scripts/mutation-check.sh", "scripts/manifest.txt"], in: root,
                               environment: environment.merging(extra) { $1 })
    }

    static let breaksTheCode = "file: Packages/PebbleKit/Sources/Fixture/Code.swift\nperl: s~works = true~works = false~\n"

    /// An entry whose test fails once its code is broken passes the check.
    @Test func theMutationCheckPassesWhenTheTestFails() throws {
        let run = try mutationCheck("test: killsIt\n" + Self.breaksTheCode)
        #expect(run.status == 0, "\(run.text)")
        #expect(run.text.contains("killed    killsIt"))
    }

    /// A test that still passes with its code broken protects nothing, so
    /// the whole check fails.
    @Test func theMutationCheckFailsWhenATestSurvives() throws {
        let run = try mutationCheck("test: killsIt survivesIt\n" + Self.breaksTheCode)
        #expect(run.status == 1)
        #expect(run.text.contains("SURVIVED  survivesIt"))
    }

    /// A test that doesn't exist, a file that doesn't, or a change that no
    /// longer applies all fail the check.
    @Test func theMutationCheckFailsForAMissingTestOrFile() throws {
        let noTest = try mutationCheck("test: noSuchTest\n" + Self.breaksTheCode)
        #expect(noTest.status == 1)
        // Caught up front, before anything is broken.
        #expect(noTest.text.contains("mutation-check: no test named noSuchTest"))
        #expect(!noTest.text.contains("PROBLEM"))
        let noFile = try mutationCheck("test: killsIt\nfile: Packages/PebbleKit/Sources/Fixture/Nowhere.swift\nperl: s~a~b~\n")
        #expect(noFile.status == 1)
        #expect(noFile.text.contains("no file Packages/PebbleKit/Sources/Fixture/Nowhere.swift"))
        let stale = try mutationCheck("test: killsIt\nfile: Packages/PebbleKit/Sources/Fixture/Code.swift\nperl: s~gone~x~\n")
        #expect(stale.status == 1)
        #expect(stale.text.contains("no longer applies"))
    }

    /// A test that only hangs once its code is broken is reported apart
    /// from the real failures, never counted as one of them, and fails the
    /// run: a slow test can't be told from one that would survive. Only
    /// MUTATION_ALLOW_TIMEOUTS=1 lets it by.
    @Test func theMutationCheckReportsATimeoutApartFromAKill() throws {
        let run = try mutationCheck("test: hangsWhenBroken killsIt\n" + Self.breaksTheCode)
        #expect(run.text.contains("TIMED OUT hangsWhenBroken"))
        #expect(run.text.contains("1 tests failed, 1 timed out instead"))
        #expect(!run.text.contains("killed    hangsWhenBroken"))
        #expect(run.status == 1, "\(run.text)")
        let allowed = try mutationCheck("test: hangsWhenBroken killsIt\n" + Self.breaksTheCode,
                                        environment: ["MUTATION_ALLOW_TIMEOUTS": "1"])
        #expect(allowed.status == 0, "\(allowed.text)")
        #expect(allowed.text.contains("mutation-check: ok"))
    }

    /// A test stopped for taking too long is stopped with everything it
    /// started, so no helper is left running to hold the next build.
    @Test func aTimedOutTestLeavesNothingRunning() throws {
        let folder = try scratchFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let helpers = folder.appendingPathComponent("helpers.txt")
        _ = try mutationCheck("test: hangsWhenBroken\n" + Self.breaksTheCode,
                              environment: ["HELPERS": helpers.path, "MUTATION_ALLOW_TIMEOUTS": "1"])
        let ids = try String(contentsOf: helpers, encoding: .utf8).split(separator: "\n").compactMap { Int32($0) }
        #expect(!ids.isEmpty, "the stand-in started no helper")
        for id in ids {
            // Stopped already, or within a moment of it.
            var running = kill(id, 0) == 0
            for _ in 0..<20 where running {
                Thread.sleep(forTimeInterval: 0.1)
                running = kill(id, 0) == 0
            }
            #expect(!running, "helper \(id) was left running")
            if running { kill(id, SIGKILL) }
        }
    }

    /// An entry with several changes needs every one to apply: one that no
    /// longer does fails the check, even when the others still do.
    @Test func everyChangeInAnEntryMustApply() throws {
        let file = "file: Packages/PebbleKit/Sources/Fixture/Code.swift\n"
        let both = try mutationCheck("test: killsIt\n" + file + "perl: s~works~doesNot~\nperl: s~true~false~\n")
        #expect(both.status == 0, "\(both.text)")
        let stale = try mutationCheck("test: killsIt\n" + file + "perl: s~works = true~works = false~\nperl: s~gone~x~\n")
        #expect(stale.status == 1)
        #expect(stale.text.contains("no longer applies to Packages/PebbleKit/Sources/Fixture/Code.swift: s~gone~x~"))
    }

    /// The first run of every listed test, before anything is broken, is
    /// bounded too: a hang there fails the check instead of stalling verify.
    @Test func theMutationCheckStopsAHangBeforeAnythingIsBroken() throws {
        let run = try mutationCheck("test: hangsAlways\n" + Self.breaksTheCode)
        #expect(run.status == 1)
        #expect(run.text.contains("didn't finish in 2s before anything was broken"))
    }
}
#endif
