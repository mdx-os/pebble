import Foundation
import SourceScan
import Testing

/// The package's tests build for iOS too, so a test that reaches for AppKit
/// must sit behind a Mac-only `#if`.
enum PlatformGate {
    /// Foundation names that exist on iOS too. Every other `NS` name is
    /// taken for AppKit, so a new AppKit type is caught without anyone
    /// adding it to a list; a Foundation name the tests come to need is
    /// added here.
    static let safeOnIOS: Set<String> = [
        "NSArray", "NSAttributedString", "NSCache", "NSCondition", "NSData", "NSDate", "NSDictionary",
        "NSError", "NSLocale", "NSLock", "NSMakeRange", "NSMutableAttributedString", "NSMutableString",
        "NSNotFound", "NSNull", "NSNumber", "NSObject", "NSPredicate", "NSRange", "NSRecursiveLock",
        "NSRegularExpression", "NSSet", "NSString", "NSTemporaryDirectory", "NSTextCheckingResult",
        "NSURL", "NSUUID",
    ]

    /// Any `NS` name, such as `NSWindow` or `NSViewController`.
    static let nsName = #"\bNS[A-Z]\w*"#

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
        let regex = try! NSRegularExpression(pattern: nsName)
        // One entry per open `#if`: whether the branch we are in is Mac-only.
        var branches: [Bool] = []
        var problems: [String] = []
        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // A directive, with a space after it or none, as in `#if(os(macOS))`.
            func opens(_ directive: String) -> Bool {
                trimmed.range(of: "^" + directive + #"(?![\w])"#, options: .regularExpression) != nil
            }
            if opens("#if") {
                branches.append(isMacOnly(trimmed))
                continue
            }
            if opens("#elseif"), !branches.isEmpty {
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
            guard !branches.contains(true) else { continue }
            let range = NSRange(line.startIndex..., in: line)
            for match in regex.matches(in: line, range: range) {
                let name = (line as NSString).substring(with: match.range)
                if safeOnIOS.contains(name) { continue }
                problems.append("\(file):\(index + 1): \(name) is AppKit only; put it behind #if os(macOS), "
                    + "or add it to PlatformGate.safeOnIOS if it is Foundation and exists on iOS")
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
            // Any AppKit name, not only the ones someone thought to list.
            "let controller = NSViewController()",
            "NSPasteboard.general.clearContents()",
            "let range = NSRange(location: 0, length: 1); let board = NSPasteboard.general",
            // Mac Catalyst runs UIKit, not AppKit, so it is no Mac gate.
            "#if targetEnvironment(macCatalyst)\nlet window = NSWindow()\n#endif",
            "#if os(macOS) || targetEnvironment(macCatalyst)\nlet window = NSWindow()\n#endif",
            // With no space after the directive, the branch is still read.
            "#if(os(iOS))\nlet a = 1\n#else\nlet window = NSWindow()\n#endif",
            "#if os(macOS)\nlet a = 1\n#elseif(os(iOS))\nlet window = NSWindow()\n#endif",
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
            "#if(os(macOS))\nlet image = NSImage()\n#endif",
            "#if os(iOS)\nlet a = 1\n#elseif(os(macOS))\nlet image = NSImage()\n#endif",
            "// NSWindow, in a comment",
            "let note = \"NSHostingView, in words\"",
            "let range = NSRange(location: 0, length: 1)",
            "let regex = try NSRegularExpression(pattern: \"a\")",
            "let lock = NSLock(); let text = NSString(string: \"a\")",
        ]
        for text in right {
            #expect(PlatformGate.ungated(in: text, file: "Right.swift").isEmpty, "flagged: \(text)")
        }
    }
}
