import Foundation
import GuardScan
import SourceScan
import Testing

/// PERMANENT GUARD. What a connector reads, such as the person's calendar,
/// never leaves the app or outlives it: nothing in `PebbleConnectors`
/// opens a connection, keeps a file, writes the defaults or logs, and the
/// layer depends on none of this package's others, so it can't hand what
/// it reads to one that does. The rules are `ConnectorGate`, and what each
/// must catch is in `GuardWrongCaseTests`.
struct ConnectorGateTests {
    static let root = SwiftSource.repositoryRoot(from: #filePath)

    @Test func noConnectorHasAWayOut() throws {
        let files = try SwiftSource.files(
            under: Self.root.appendingPathComponent("Packages/PebbleKit/Sources/PebbleConnectors"))
        #expect(files.map(\.name).contains("Calendar.swift"), "the sweep sees the calendar connector")
        #expect(files.map(\.name).contains("EventKitCalendarStore.swift"), "and the store EventKit backs")
        for file in files {
            for problem in ConnectorGate.problems(in: SyntaxSource.shared(file.text), file: file.name) {
                Issue.record(Comment(rawValue: problem.report(in: "PebbleConnectors/" + file.name)))
            }
        }
    }

    /// The layer's target in `Package.swift` lists no dependencies, so it
    /// can't reach `PebbleCore`'s files or `PebbleModel`'s cloud model.
    @Test func theConnectorLayerDependsOnNothingOfOurs() throws {
        let manifest = try String(contentsOf: Self.root.appendingPathComponent("Packages/PebbleKit/Package.swift"),
                                  encoding: .utf8)
        let targets = ConnectorGate.dependencies(ofTarget: "PebbleConnectors", in: SyntaxSource(manifest))
        #expect(targets.count == 1, "one PebbleConnectors target")
        for dependencies in targets {
            #expect(dependencies.isEmpty, "PebbleConnectors depends on \(dependencies)")
        }
        // The reading itself, on a manifest that does list some.
        let wrong = SyntaxSource(#".target(name: "PebbleConnectors", dependencies: ["PebbleCore"]),"#)
        #expect(ConnectorGate.dependencies(ofTarget: "PebbleConnectors", in: wrong) == [[#""PebbleCore""#]])
    }
}
