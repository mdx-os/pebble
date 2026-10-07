import PebbleCore
import PebbleModel
import PebbleUI
import SwiftUI

@main
struct PebbleApp: App {
    private let brand: Brand
    private let model: any ModelClient

    init() {
        guard let brand = Brand(infoDictionary: Bundle.main.infoDictionary) else {
            preconditionFailure("\(Brand.infoKey) is missing from Info.plist. Set BRAND_NAME in Config/Brand.xcconfig.")
        }
        self.brand = brand
        #if os(macOS)
        SnapshotMode.runIfRequested(brand: brand)
        #endif
        self.model = OnDeviceModel.client()
    }

    var body: some Scene {
        WindowGroup {
            ChatView(brand: brand, model: model, names: UserDefaultsAgentNameStore())
        }
    }
}
