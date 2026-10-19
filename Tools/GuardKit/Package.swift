// swift-tools-version: 6.2
import PackageDescription

// The source guards: the privacy promise, contrast, accent and platform
// gate rules, read through SwiftSyntax, with the suites that run them.
// A package of its own, so swift-syntax never enters the app's package
// graph: PebbleKit and the app project don't know this package exists,
// and `make graph-check` fails if swift-syntax ever reaches them.
// swift-syntax is pinned to an exact version, and only GuardScan uses it.
// It builds for the Mac only; the guards read source, they don't ship.
let package = Package(
    name: "GuardKit",
    platforms: [.macOS(.v26)],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-syntax.git", exact: "603.0.0"),
        .package(path: "../../Packages/PebbleKit"),
    ],
    targets: [
        .target(name: "GuardScan",
                dependencies: [
                    .product(name: "SwiftSyntax", package: "swift-syntax"),
                    .product(name: "SwiftParser", package: "swift-syntax"),
                    .product(name: "SwiftOperators", package: "swift-syntax"),
                    .product(name: "PromiseWords", package: "PebbleKit"),
                ]),
        .testTarget(name: "GuardTests",
                    dependencies: [
                        "GuardScan",
                        .product(name: "PebbleCore", package: "PebbleKit"),
                        .product(name: "PromiseWords", package: "PebbleKit"),
                        .product(name: "SourceScan", package: "PebbleKit"),
                    ]),
    ]
)
