#if canImport(SwiftUI)
import PebbleCore
import PebbleUI
import SwiftUI
import Testing

struct WelcomeViewTests {
    let brand = Brand(name: "Nova")

    @Test func greetingUsesTheBrandName() {
        #expect(WelcomeCopy.greeting(for: brand) == "Hi, I'm Nova.")
    }

    @Test func initialIsTheFirstLetter() {
        #expect(WelcomeCopy.initial(for: Brand(name: "nova")) == "N")
    }

    @MainActor
    @Test(arguments: [
        CGSize(width: 393, height: 852),   // iPhone
        CGSize(width: 1032, height: 1376), // iPad
        CGSize(width: 1280, height: 800),  // Mac window
    ])
    func rendersAtEachDeviceSize(size: CGSize) throws {
        let renderer = ImageRenderer(content: WelcomeView(brand: brand).frame(width: size.width, height: size.height))
        let image = try #require(renderer.cgImage)
        #expect(image.width == Int(size.width * renderer.scale))
    }
}
#endif
