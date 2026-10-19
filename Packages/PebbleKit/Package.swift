// swift-tools-version: 6.2
import PackageDescription

// Layers, lowest first. A layer may import only the layers below it,
// and SwiftPM enforces that through the dependency lists here.
//   PebbleCore   plain types. No SwiftUI, no networking.
//   PebblePulse  public source watch: fetching and snapshots. Imports PebbleCore.
//   PebbleModel  model adapter. ModelClient, the on-device placeholder and
//                CloudModel (off by default). Imports PebbleCore. A later
//                MLX or Ollama adapter lives here.
//   PebbleBackground  gives the background runner time: BGTaskScheduler on
//                iPhone and iPad, NSBackgroundActivityScheduler on the Mac.
//                Imports PebbleCore. Scheduling decisions are pure
//                functions in `BackgroundPlan`; the runner, its store and
//                its switch live in PebbleCore's `Background.swift`.
//   PebbleConnectors  reads what the person keeps in other apps, read
//                only: the calendar and reminders through EventKit.
//                Imports none of ours, so nothing it reads can reach a
//                file, a log or the cloud model; `ConnectorGate` in
//                Tools/GuardKit holds it to that.
//   PebbleUI     SwiftUI views shared by Mac, iPhone and iPad.
//                Imports PebbleCore and PebbleModel.
// SourceScan is not a layer. It lives under Tests and only tests use it,
// to read Swift source and stored values for their guards.
// ReconTestSupport is the same kind of thing: the test engines, gates and
// waits that the core and UI tests share, kept in one copy.
// TestScratch is the same kind of helper: a folder of scratch files for
// each test, removed when it ends.
// PromiseWords is one too: the phrases that promise the device, and the
// lines allowed to say them with a written reason.
// SourceScan and PromiseWords are products only so Tools/GuardKit, the
// source guards' own package, can read them. The app never links them.
// This package depends on nothing outside it: swift-syntax lives only in
// Tools/GuardKit, and `make graph-check` fails if it ever comes in here.
let package = Package(
    name: "PebbleKit",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "PebbleCore", targets: ["PebbleCore"]),
        .library(name: "PebblePulse", targets: ["PebblePulse"]),
        .library(name: "PebbleModel", targets: ["PebbleModel"]),
        .library(name: "PebbleBackground", targets: ["PebbleBackground"]),
        .library(name: "PebbleConnectors", targets: ["PebbleConnectors"]),
        .library(name: "PebbleUI", targets: ["PebbleUI"]),
        .library(name: "SourceScan", targets: ["SourceScan"]),
        .library(name: "PromiseWords", targets: ["PromiseWords"]),
        .executable(name: "pulse", targets: ["pulse"]),
    ],
    targets: [
        .target(name: "PebbleCore"),
        .target(name: "PebblePulse", dependencies: ["PebbleCore"]),
        .target(name: "PebbleModel", dependencies: ["PebbleCore"]),
        .target(name: "PebbleBackground", dependencies: ["PebbleCore"]),
        .target(name: "PebbleConnectors"),
        .target(name: "PebbleUI", dependencies: ["PebbleCore", "PebbleModel"]),
        .executableTarget(name: "pulse", dependencies: ["PebbleCore", "PebblePulse"]),
        .target(name: "SourceScan", path: "Tests/SourceScan"),
        .target(name: "ReconTestSupport", dependencies: ["PebbleCore"], path: "Tests/ReconTestSupport"),
        .target(name: "TestScratch", path: "Tests/TestScratch"),
        .target(name: "PromiseWords", dependencies: ["PebbleCore"], path: "Tests/PromiseWords"),
        .testTarget(name: "PebbleCoreTests",
                    dependencies: ["PebbleCore", "SourceScan", "ReconTestSupport", "TestScratch", "PromiseWords"]),
        .testTarget(name: "PebblePulseTests", dependencies: ["PebblePulse", "PebbleCore"]),
        .testTarget(name: "PebbleModelTests", dependencies: ["PebbleModel", "PebbleCore", "SourceScan", "TestScratch"]),
        .testTarget(name: "PebbleBackgroundTests",
                    dependencies: ["PebbleBackground", "PebbleCore", "SourceScan", "TestScratch"]),
        .testTarget(name: "PebbleConnectorsTests", dependencies: ["PebbleConnectors", "PromiseWords"]),
        .testTarget(name: "PebbleUITests",
                    dependencies: ["PebbleUI", "PebbleModel", "PebbleCore", "PebbleBackground", "SourceScan",
                                   "ReconTestSupport", "TestScratch"]),
    ]
)
