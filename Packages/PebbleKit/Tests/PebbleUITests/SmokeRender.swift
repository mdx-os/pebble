#if canImport(SwiftUI)
import SwiftUI
import Testing

/// A smoke test's one check: the view draws without crashing. ImageRenderer
/// hands back a picture of whatever frame it was given, so its width proves
/// nothing more, and a test that calls this is named as a smoke test and
/// claims no more than that. What a screen shows is asserted on the pure
/// values behind it, and seen in `make screenshots`.
@MainActor
func smokeRender(_ view: some View, sourceLocation: SourceLocation = #_sourceLocation) throws {
    let renderer = ImageRenderer(content: view)
    _ = try #require(renderer.cgImage, "the view did not draw", sourceLocation: sourceLocation)
}
#endif
