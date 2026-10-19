import Foundation

/// Manifest and source inventory validation shared by the CLI and tests.
public enum PrivacyAudit {
    /// Apple's five category lists, checked 2026-10-18:
    /// https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacyaccessedapitypes/nsprivacyaccessedapitype
    public static let allowedReasons: [String: Set<String>] = [
        "NSPrivacyAccessedAPICategoryFileTimestamp": ["DDA9.1", "C617.1", "3B52.1", "0A2A.1"],
        "NSPrivacyAccessedAPICategorySystemBootTime": ["35F9.1", "8FFB.1", "3D61.1"],
        "NSPrivacyAccessedAPICategoryDiskSpace": ["85F4.1", "E174.1", "7D9E.1", "B728.1"],
        "NSPrivacyAccessedAPICategoryActiveKeyboards": ["3EC4.1", "54BD.1"],
        "NSPrivacyAccessedAPICategoryUserDefaults": ["CA92.1", "1C8F.1", "C56D.1", "AC6B.1"],
    ]
    public static func validReason(_ code: String, category: String) -> Bool {
        allowedReasons[category]?.contains(code) == true
    }
    public static func readableSource(_ path: String) -> Bool {
        URL(fileURLWithPath: path).pathExtension == "swift"
    }

    public struct Result {
        public var errors: [String] = []
        public var networkFiles: [String] = []
    }
    public static func check(files: [String], manifest: [String: Any], reviewedReads: [String]) throws -> Result {
        var result = Result()
        var declared: Set<String> = []
        if manifest["NSPrivacyTracking"] as? Bool != false
            || (manifest["NSPrivacyTrackingDomains"] as? [String])?.isEmpty != true
            || (manifest["NSPrivacyCollectedDataTypes"] as? [Any])?.isEmpty != true {
            result.errors.append("the manifest now claims tracking or collection; review docs/RELEASE.md")
        }
        if let entries = manifest["NSPrivacyAccessedAPITypes"] as? [[String: Any]] {
            for entry in entries {
                guard let category = entry["NSPrivacyAccessedAPIType"] as? String,
                      let reasons = entry["NSPrivacyAccessedAPITypeReasons"] as? [String], !reasons.isEmpty,
                      reasons.allSatisfy({ validReason($0, category: category) }),
                      declared.insert(category).inserted else {
                    result.errors.append("invalid required-reason declaration: unknown category, invalid reason code, empty reasons or duplicate category")
                    continue
                }
            }
        } else {
            result.errors.append("invalid required-reason declaration: expected an array")
        }
        if let tests = try? String(contentsOfFile: PrivacyRules.gateTests, encoding: .utf8) {
            result.errors += PrivacyRules.findings(in: SyntaxSource(tests), file: PrivacyRules.gateTests)
                .filter { $0.rule == "privacy.gateTests" }.map { $0.report(in: PrivacyRules.gateTests) }
        } else {
            result.errors.append("\(PrivacyRules.gateTests) is gone; it holds the consent gate tests")
        }
        var used: Set<String> = []
        var remainingReads = reviewedReads
        for file in files.sorted() {
            guard readableSource(file) else {
                result.errors.append("cannot read compiled source \(file); add a parser and fixtures before shipping this source type")
                continue
            }
            let source = SyntaxSource(try String(contentsOfFile: file, encoding: .utf8))
            if source.tree.hasError { result.errors.append("\(file): Swift parse failed; cannot audit source") }
            if PrivacyRules.hasNetwork(source) { result.networkFiles.append(file) }
            for hit in PrivacyRules.findings(in: source, file: file) {
                if hit.rule == "privacy.requiredReason" {
                    used.insert(hit.message)
                    if !declared.contains(hit.message) {
                        result.errors.append("\(file):\(hit.line): required-reason API (\(hit.message)) with no entry in the manifest")
                    }
                } else if hit.rule == "privacy.urlRead" {
                    let key = "\(file): \(hit.message)"
                    if let index = remainingReads.firstIndex(of: key) {
                        remainingReads.remove(at: index)
                    } else {
                        result.errors.append("\(file):\(hit.line): a read by contents of a URL that no one has checked: \(key)")
                    }
                } else {
                    result.errors.append(hit.report(in: file))
                }
            }
        }
        for category in declared.subtracting(used).sorted() {
            result.errors.append("manifest declares \(category), but no code uses it. Remove the entry.")
        }
        for read in remainingReads { result.errors.append("reviewed URL read no longer matches any code: \(read)") }
        for file in [PrivacyRules.cloud, PrivacyRules.gate] where !files.contains(file) {
            result.errors.append("\(file) is named here but the app no longer ships it")
        }
        return result
    }
}
