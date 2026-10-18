import Foundation
import SourceScan
import Testing

/// The package's tests build for iOS too, so a test that reaches for AppKit
/// must sit behind a Mac-only `#if`.
enum PlatformGate {
    /// AppKit names that don't exist on iOS.
    static let appKitOnly = #"\bNS(?:Window|HostingView|HostingController|View|Image|App|Application|Screen|Color|Font|Event)\b"#

    /// True when the `#if` condition holds only on the Mac: every `||` arm
    /// is `os(macOS)` or `canImport(AppKit)`, and nothing is turned with
    /// `!`. So `!os(macOS)` and `os(macOS) || os(iOS)` are not Mac-only.
    static func isMacOnly(_ condition: String) -> Bool {
        var rest = condition.trimmingCharacters(in: .whitespaces)
        for directive in ["#elseif", "#if"] where rest.hasPrefix(directive) {
            rest = String(rest.dropFirst(directive.count))
            break
        }
        guard !rest.contains("!") else { return false }
        // Spaces and grouping parentheses don't change an arm.
        let arms = rest.replacingOccurrences(of: " ", with: "").components(separatedBy: "||")
        return arms.allSatisfy { arm in
            var arm = Substring(arm)
            while arm.hasPrefix("(") { arm = arm.dropFirst() }
            while arm.hasSuffix(")"), arm.filter({ $0 == ")" }).count > arm.filter({ $0 == "(" }).count {
                arm = arm.dropLast()
            }
            return ["os(macOS)", "canImport(AppKit)"].contains(String(arm))
        }
    }

    /// Each line of `text` that names AppKit outside a Mac-only branch.
    /// Comments and string literals are skipped. An `#else` after a Mac-only
    /// `#if` is not Mac-only, and the `#else` of `os(iOS)` isn't either,
    /// since it covers every other platform.
    static func ungated(in text: String, file: String) -> [String] {
        let source = SwiftSource(text)
        let lines = String(source.code).components(separatedBy: "\n")
        let regex = try! NSRegularExpression(pattern: appKitOnly)
        // One entry per open `#if`: whether the branch we are in is Mac-only.
        var branches: [Bool] = []
        var problems: [String] = []
        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#if ") {
                branches.append(isMacOnly(trimmed))
                continue
            }
            if trimmed.hasPrefix("#elseif "), !branches.isEmpty {
                branches[branches.count - 1] = isMacOnly(trimmed)
                continue
            }
            if trimmed.hasPrefix("#else"), !branches.isEmpty {
                branches[branches.count - 1] = false
                continue
            }
            if trimmed.hasPrefix("#endif") {
                _ = branches.popLast()
                continue
            }
            let range = NSRange(line.startIndex..., in: line)
            if !branches.contains(true), let match = regex.firstMatch(in: line, range: range) {
                let name = (line as NSString).substring(with: match.range)
                problems.append("\(file):\(index + 1): \(name) is AppKit only; put it behind #if os(macOS)")
            }
        }
        return problems
    }
}

struct PlatformGateTests {
    /// PERMANENT GUARD. No test names AppKit outside `#if os(macOS)`, so the
    /// tests still build for iOS.
    @Test func everyAppKitNameInTheTestsIsBehindAMacGate() throws {
        let root = SwiftSource.repositoryRoot(from: #filePath)
        let files = try SwiftSource.files(under: root.appendingPathComponent("Packages/PebbleKit/Tests"))
        #expect(files.count > 20)
        for file in files {
            for problem in PlatformGate.ungated(in: file.text, file: file.name) {
                Issue.record(Comment(rawValue: problem))
            }
        }
    }

    @Test func theGateCatchesAnUngatedWindow() {
        let wrong = [
            "let window = NSWindow(contentRect: .zero, styleMask: [], backing: .buffered, defer: false)",
            "#if canImport(SwiftUI)\nlet host = NSHostingView(rootView: Text(\"\"))\n#endif",
            "#if os(macOS)\nlet a = 1\n#else\nlet host = NSHostingView(rootView: Text(\"\"))\n#endif",
            "#if os(iOS)\nlet a = 1\n#else\nlet host = NSHostingView(rootView: Text(\"\"))\n#endif",
            "#if os(iOS)\nlet a = 1\n#endif\nlet host = NSHostingView(rootView: Text(\"\"))",
            // Naming the Mac isn't enough: turned around, or one arm of many.
            "#if !os(macOS)\nlet window = NSWindow()\n#endif",
            "#if os(macOS) || os(iOS)\nlet window = NSWindow()\n#endif",
            "#if canImport(AppKit) || canImport(UIKit)\nlet image = NSImage()\n#endif",
            "#if os(iOS)\nlet a = 1\n#elseif !canImport(AppKit)\nlet image = NSImage()\n#endif",
        ]
        for text in wrong {
            #expect(!PlatformGate.ungated(in: text, file: "Wrong.swift").isEmpty, "missed: \(text)")
        }
        let right = [
            "#if os(macOS)\nlet window = NSWindow()\n#endif",
            "#if canImport(SwiftUI)\n#if os(macOS)\nlet host = NSHostingView(rootView: Text(\"\"))\n#endif\n#endif",
            "#if os(iOS)\nlet a = 1\n#elseif os(macOS)\nlet host = NSHostingView(rootView: Text(\"\"))\n#endif",
            "#if canImport(AppKit)\nlet image = NSImage()\n#endif",
            "#if os(macOS) || canImport(AppKit)\nlet image = NSImage()\n#endif",
            "#if (os(macOS))\nlet image = NSImage()\n#endif",
            "// NSWindow, in a comment",
            "let note = \"NSHostingView, in words\"",
            "let range = NSRange(location: 0, length: 1)",
            "let regex = try NSRegularExpression(pattern: \"a\")",
        ]
        for text in right {
            #expect(PlatformGate.ungated(in: text, file: "Right.swift").isEmpty, "flagged: \(text)")
        }
    }
}
