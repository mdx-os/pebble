#if os(macOS)
import Foundation
import Testing
import TestScratch

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
    }

    /// The same, for a tracked config whose file modes keep it from being
    /// read. Root reads a file whatever its modes say, so this one runs only
    /// where they hold, and fails rather than skips in CI.
    @Test(.fileModesHoldOrCI, .failsAsRoot)
    func theLocalConfigCheckFailsWhenATrackedConfigIsUnreadable() throws {
        let repo = try scratchFolder()
        defer { try? FileManager.default.removeItem(at: repo) }
        let check = Self.script("local-config-check.sh")
        #expect(try Self.run(["git", "init", "--quiet"], in: repo) == 0)
        let config = repo.appendingPathComponent("Config/Cloud.xcconfig")
        try Data("PEBBLE_CLOUD_ENDPOINT =\n".utf8).write(to: config)
        #expect(try Self.run(["git", "add", "Config/Cloud.xcconfig"], in: repo) == 0)
        #expect(try Self.run(["sh", check, repo.path], in: repo) == 0)
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
    /// nothing that lets it fail quietly, and `make build-release-simulator`
    /// runs it before it builds, so `make build-release`, which builds that
    /// first, does too.
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
        #expect(makefile.contains("build-release-simulator: generate\n\tsh scripts/release-endpoint-check.sh\n"))
        #expect(makefile.contains("\nbuild-release: generate build-release-simulator\n"))
    }

    // MARK: The comment lint

    /// Review history and people's names in comments fail; the same words
    /// outside a comment, or words that only look alike, pass.
    @Test func theCommentLintCatchesReviewHistoryAndNames() throws {
        let folder = try scratchFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let lint = Self.script("comment-lint.sh")
        // Made-up names, in a list outside the repository, so no real name
        // is ever in it.
        let list = folder.appendingPathComponent("names.txt")
        try Data("# Made up.\n\nAda Byron\nJo Ann\nQuillon\n".utf8).write(to: list)
        func lintRun(_ file: URL) throws -> Int32 {
            try Self.run(["sh", lint, file.path], in: folder, environment: ["COMMENT_LINT_NAMES": list.path])
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
        let found = try Self.output(["sh", lint, two.path], in: folder, environment: ["COMMENT_LINT_NAMES": list.path])
        #expect(found.status == 1)
        #expect(found.text.contains("Two.swift:1: a name from the list"))
        #expect(!found.text.lowercased().contains("byron"))
        // A list it can't read, with a name of three words, or with no
        // names is an error, never a pass.
        func withList(_ names: String) throws -> Int32 {
            try Self.run(["sh", lint, good.path], in: folder, environment: ["COMMENT_LINT_NAMES": names])
        }
        #expect(try withList(folder.appendingPathComponent("nowhere").path) == 1)
        let broken = folder.appendingPathComponent("broken.txt")
        for text in ["Ada Lovelace Byron\n", "# nothing here\n\n"] {
            try Data(text.utf8).write(to: broken)
            #expect(try withList(broken.path) == 1, "\(text)")
        }
        #expect(try Self.run(["sh", lint, "--self-test"], in: folder) == 0)
    }

    /// The names are never in the repository, in plain text or hashed: a
    /// hash of a short name is undone by trying every name. No list or
    /// hash file is committed, a local list is ignored by git, and a list
    /// inside the repository is refused. With no list the lint says it
    /// checked no names, and still fails on review history.
    @Test func theNamesListIsNeverInTheRepository() throws {
        for gone in ["scripts/comment-lint-names.txt", "Config/comment-lint-names.txt", "Config/comment-lint-names.sha256"] {
            #expect(!FileManager.default.fileExists(atPath: Self.root.appendingPathComponent(gone).path), "\(gone)")
        }
        let ignore = try String(contentsOf: Self.root.appendingPathComponent(".gitignore"), encoding: .utf8)
        #expect(ignore.split(separator: "\n").contains("Config/comment-lint-names.local.txt"))
        let source = try String(contentsOf: URL(fileURLWithPath: Self.script("comment-lint.sh")), encoding: .utf8)
        for gone in ["Digest::SHA", "sha256", "--hash-names"] {
            #expect(!source.contains(gone), "\(gone)")
        }
        let folder = try scratchFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("scripts"),
                                                withIntermediateDirectories: true)
        let lint = folder.appendingPathComponent("scripts/comment-lint.sh")
        try FileManager.default.copyItem(atPath: Self.script("comment-lint.sh"), toPath: lint.path)
        func lintRun(_ file: URL, names: String) throws -> (status: Int32, text: String) {
            try Self.output(["sh", lint.path, file.path], in: folder, environment: ["COMMENT_LINT_NAMES": names])
        }
        let code = folder.appendingPathComponent("Code.swift")
        try Data("/// Quillon asked for this.\nlet x = 1\n".utf8).write(to: code)
        // No list: the name passes, and the lint says it checked no names.
        let unchecked = try lintRun(code, names: "")
        #expect(unchecked.status == 0, "\(unchecked.text)")
        #expect(unchecked.text.contains("names were not checked"))
        // Review history fails with no list all the same.
        let item = "item"
        let history = folder.appendingPathComponent("History.swift")
        try Data("/// Asked for in \(item) 11.\n".utf8).write(to: history)
        #expect(try lintRun(history, names: "").status == 1)
        // A list inside the repository is refused, and never printed; the
        // same list outside it finds the name.
        let inside = folder.appendingPathComponent("names.txt")
        try Data("Quillon\n".utf8).write(to: inside)
        let refused = try lintRun(code, names: inside.path)
        #expect(refused.status == 1)
        #expect(refused.text.contains("inside the repository"))
        #expect(!refused.text.lowercased().contains("quillon"), "it never prints the list")
        let outside = try scratchFolder()
        defer { try? FileManager.default.removeItem(at: outside) }
        let list = outside.appendingPathComponent("names.txt")
        try FileManager.default.copyItem(at: inside, to: list)
        let caught = try lintRun(code, names: list.path)
        #expect(caught.status == 1)
        #expect(caught.text.contains("Code.swift:1: a name from the list"))
        #expect(!caught.text.lowercased().contains("quillon"))
        try Data("/// Rounds to 4 places.\n".utf8).write(to: code)
        let clean = try lintRun(code, names: list.path)
        #expect(clean.status == 0)
        #expect(!clean.text.contains("names were not checked"))
    }

    /// CI runs the lint with no secret, a fork's pull request included, so
    /// it checks review history there and says it checked no names.
    @Test func ciRunsTheCommentLintWithNoSecret() throws {
        let workflow = try String(contentsOf: Self.root.appendingPathComponent(".github/workflows/ci.yml"), encoding: .utf8)
        #expect(!workflow.contains("COMMENT_LINT"))
        #expect(!workflow.contains("secrets."))
        let verify = try #require(workflow.range(of: "      - name: Verify\n"))
        #expect(workflow[verify.upperBound...].hasPrefix("        run: make verify-ci\n"))
    }

    /// CI runs all of make verify on every pull request and every push to
    /// main: verify-ci
    /// in the Verify job, and the full mutation check, every entry with no
    /// timeout let by, in a job of its own with a longer limit. The whole
    /// mutation job is pinned, so no condition, dependency or extra step
    /// can be slipped in anywhere in it.
    @Test func ciRunsTheFullMutationCheckInItsOwnJob() throws {
        let workflow = try String(contentsOf: Self.root.appendingPathComponent(".github/workflows/ci.yml"), encoding: .utf8)
        // Everything before the jobs is pinned too: every pull request,
        // whatever its target, every push to main, and no settings the jobs
        // inherit. No job may set its own environment or defaults either.
        #expect(workflow.hasPrefix(Self.workflowHead))
        for inherited in ["env:", "defaults:", "MAKEFLAGS"] {
            #expect(!workflow.contains(inherited), "\(inherited)")
        }
        #expect(workflow.contains("    name: Verify on Mac, iPhone and iPad\n"))
        for filter in ["paths:", "paths-ignore", "branches-ignore", "types:"] {
            #expect(!workflow.contains(filter), "\(filter)")
        }
        let opening = try #require(workflow.range(of: "\n  mutation:\n"))
        let after = workflow[opening.upperBound...]
        let close = after.range(of: "\n  [^ \n]", options: .regularExpression)?.lowerBound ?? after.endIndex
        let block = ("  mutation:\n" + after[..<close]).trimmingCharacters(in: .newlines)
        #expect(block == Self.mutationJob)
        let job = try #require(workflow.range(of: "    name: Mutation check\n"))
        let rest = workflow[job.upperBound...]
        let steps = rest.split(separator: "\n").filter { $0.hasPrefix("        run: ") }
        #expect(steps.contains("        run: make mutation-check"))
        #expect(!rest.contains("        if: "))
        for loophole in ["ONLY", "MUTATION_ALLOW_TIMEOUTS", "continue-on-error"] {
            #expect(!workflow.contains(loophole), "\(loophole)")
        }
        let limit = try #require(rest.split(separator: "\n").first { $0.hasPrefix("    timeout-minutes: ") })
        #expect((Int(limit.dropFirst("    timeout-minutes: ".count)) ?? 0) >= 90)
    }

    /// The start of ci.yml, up to its first job, exactly.
    static let workflowHead = """
    name: CI

    on:
      push:
        branches: [main]
      pull_request:

    permissions:
      contents: read

    concurrency:
      group: ci-${{ github.ref }}
      cancel-in-progress: true

    jobs:
      verify:

    """

    /// The mutation job in ci.yml, exactly. Changing it means changing this
    /// on purpose.
    static let mutationJob = """
      mutation:
        name: Mutation check
        runs-on: macos-26
        timeout-minutes: 150
        steps:
          - uses: actions/checkout@v5
            with:
              fetch-depth: 0

          - name: Install tools
            run: brew install xcodegen gitleaks

          - name: Show toolchain
            run: |
              xcodebuild -version
              swift --version

          - name: Mutation check
            run: make mutation-check
    """

    /// The lint looks at project.yml, the Makefile and the mutation
    /// manifest too, not only the code folders.
    @Test func theCommentLintCoversTheProjectFiles() throws {
        let lint = try String(contentsOf: URL(fileURLWithPath: Self.script("comment-lint.sh")), encoding: .utf8)
        let defaults = try #require(lint.split(separator: "\n").first { $0.contains("|| set -- ") })
        for path in ["Packages/PebbleKit/Sources", "Packages/PebbleKit/Tests", "Tools/GuardKit", "App", "AppUITests", "scripts",
                     "project.yml", "Makefile"] {
            #expect(defaults.contains(" \(path)"), "\(path)")
        }
        #expect(lint.contains("-name '*.txt'"))
        #expect(try Self.run(["sh", Self.script("comment-lint.sh")], in: Self.root) == 0)
    }

    /// `make verify` runs the lint, its self-test and the mutation check,
    /// the Release check by one rule (verify builds `build-release-simulator`,
    /// whose first step is the check, pinned in `everyReleaseBuildRunsTheCheck`),
    /// and the tests that only a Release build can run. Verify is verify-ci
    /// and the mutation check, so what CI's Verify job runs can't drift
    /// from it.
    @Test func verifyRunsTheCommentLintAndTheMutationCheck() throws {
        let makefile = try String(contentsOf: Self.root.appendingPathComponent("Makefile"), encoding: .utf8)
        let lines = makefile.split(separator: "\n")
        let verify = try #require(lines.first { $0.hasPrefix("verify:") })
        #expect(verify == "verify: verify-ci mutation-check")
        let ci = try #require(lines.first { $0.hasPrefix("verify-ci:") })
        let steps = ci.split(separator: " ")
        #expect(steps.contains("comment-lint"))
        #expect(!steps.contains("mutation-check"))
        #expect(steps.contains("build-release-simulator"))
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
        #expect(probe.contains("if CloudEndpoint.url(from: raw) != nil || CloudEndpoint.url(infoDictionary: [CloudEndpoint.infoKey: raw]) != nil {"))
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
        for part in ["scripts", "App", "AppUITests", ".github", "docs", "Tools/GuardKit", "Packages/PebbleKit/Sources/Fixture"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(part),
                                                    withIntermediateDirectories: true)
        }
        for file in ["Makefile", "project.yml", ".gitignore", "README.md", "AGENTS.md"] {
            try Data().write(to: root.appendingPathComponent(file))
        }
        // The check reads every entry through the manifest check first.
        for script in ["mutation-check.sh", "mutation-manifest-check.sh"] {
            try FileManager.default.copyItem(atPath: Self.script(script),
                                             toPath: root.appendingPathComponent("scripts/\(script)").path)
        }
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
        case "$package" in
          */Tools/GuardKit) echo "Test run with 0 tests"; exit 0 ;;
        esac
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
        // Caught up front too, by the manifest check, before anything is built.
        #expect(noFile.text.contains("mutation-manifest-check: scripts/manifest.txt:1: no file Packages/PebbleKit/Sources/Fixture/Nowhere.swift"),
                "\(noFile.text)")
        #expect(!noFile.text.contains("PROBLEM"))
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
