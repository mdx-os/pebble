import PebbleCore
import PebbleUI
import SwiftUI

@main
struct PebbleApp: App {
    private let brand: Brand

    init() {
        guard let brand = Brand(infoDictionary: Bundle.main.infoDictionary) else {
            preconditionFailure("\(Brand.infoKey) is missing from Info.plist. Set BRAND_NAME in Config/Brand.xcconfig.")
        }
        self.brand = brand
        #if os(macOS)
        SnapshotMode.runIfRequested(brand: brand)
        #endif
    }

    var body: some Scene {
        WindowGroup {
            WelcomeView(brand: brand)
        }
    }
}
