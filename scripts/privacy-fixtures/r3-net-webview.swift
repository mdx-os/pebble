// into: Packages/PebbleKit/Sources/PebbleUI
// expect: network code outside the opt-in cloud client
import SwiftUI

struct FixtureWeb: View {
    let url: URL
    var body: some View { WebView(url: url) }
}
