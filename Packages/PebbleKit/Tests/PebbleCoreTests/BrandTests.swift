import PebbleCore
import Testing

struct BrandTests {
    @Test func readsNameFromInfoDictionary() {
        let brand = Brand(infoDictionary: [Brand.infoKey: "Nova"])
        #expect(brand == Brand(name: "Nova"))
    }

    @Test func trimsWhitespace() {
        #expect(Brand(infoDictionary: [Brand.infoKey: "  Nova \n"])?.name == "Nova")
    }

    @Test(arguments: [
        [:],
        [Brand.infoKey: ""],
        [Brand.infoKey: "   "],
        [Brand.infoKey: "$(BRAND_NAME)"],
        [Brand.infoKey: 42],
    ] as [[String: any Sendable]])
    func rejectsMissingOrUnexpandedNames(info: [String: any Sendable]) {
        #expect(Brand(infoDictionary: info) == nil)
    }
}
