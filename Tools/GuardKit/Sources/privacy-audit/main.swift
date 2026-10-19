import Foundation
import GuardScan

// Run from the audited tree. The shell owns building and listing files;
// this executable reads project.yml's resolved spec, the manifest, the
// inventory and Swift source.
do {
    let arguments = CommandLine.arguments
    guard arguments.count == 3 else { throw AuditError.usage }
    // privacy-audit --project spec.json: one "product" or "root" line each.
    if arguments[1] == "--project" {
        let data = try Data(contentsOf: URL(fileURLWithPath: arguments[2]))
        guard let spec = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw AuditError.project }
        let linked = try PrivacyProject.linked(spec: spec)
        for product in linked.products { print("product \(product)") }
        for root in linked.roots { print("root \(root)") }
        exit(0)
    }
    let files = try String(contentsOfFile: arguments[1], encoding: .utf8).split(separator: "\n").map(String.init)
    let data = try Data(contentsOf: URL(fileURLWithPath: "App/Resources/PrivacyInfo.xcprivacy"))
    guard let manifest = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
        throw AuditError.manifest
    }
    let reads = try String(contentsOfFile: "scripts/privacy-file-reads.txt", encoding: .utf8)
        .split(separator: "\n").map(String.init).filter { !$0.hasPrefix("#") && !$0.isEmpty }
    let result = try PrivacyAudit.check(files: files, manifest: manifest, reviewedReads: reads)
    for error in result.errors { print("privacy-check: \(error)") }
    guard result.errors.isEmpty else { exit(1) }
    if arguments[2] == "--network-files" { for file in result.networkFiles { print(file) } }
} catch {
    print("privacy-check: \(error)")
    exit(1)
}
enum AuditError: Error { case usage, manifest, project }
