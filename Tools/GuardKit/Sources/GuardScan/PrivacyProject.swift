/// What project.yml builds into the app: the package products it links and
/// the source folders it compiles, read from `xcodegen dump --type json`,
/// which has already merged includes and templates. Every target that
/// ships is read, and each target one depends on. A form this doesn't know
/// fails, so nothing reaches the app unread.
public enum PrivacyProject {
    /// The one package the check can describe, and where it lives.
    public static let package = "PebbleKit"
    public static let packagePath = "Packages/PebbleKit"
    static let shippedTypes: Set<String> = ["application"]
    static let testTypes: Set<String> = ["bundle.ui-testing", "bundle.unit-test"]
    /// Dependency keys that change how something is linked, never what.
    static let linkKeys: Set<String> = ["embed", "link", "weak", "codeSign", "platformFilter", "platformFilters", "destinationFilters"]

    public struct Linked: Equatable, Sendable {
        public var products: [String] = []
        public var roots: [String] = []
    }

    public struct Unreadable: Error, CustomStringConvertible, Equatable {
        public let description: String
        init(_ what: String) {
            description = "project.yml: \(what), which this check cannot read. Review it, then teach PrivacyProject to read it."
        }
    }

    public static func linked(spec: [String: Any]) throws -> Linked {
        guard let targets = spec["targets"] as? [String: Any], !targets.isEmpty else { throw Unreadable("no targets") }
        let packages = spec["packages"] as? [String: Any] ?? [:]
        var todo: [String] = []
        for (name, value) in targets.sorted(by: { $0.key > $1.key }) {
            guard let target = value as? [String: Any], let type = target["type"] as? String else {
                throw Unreadable("target \(name) has no type")
            }
            if shippedTypes.contains(type) {
                todo.append(name)
            } else if !testTypes.contains(type) {
                throw Unreadable("target \(name) is a \(type)")
            }
        }
        guard !todo.isEmpty else { throw Unreadable("no application target") }
        var linked = Linked()
        var seen: Set<String> = []
        while let name = todo.popLast() {
            guard seen.insert(name).inserted else { continue }
            guard let target = targets[name] as? [String: Any] else {
                throw Unreadable("a dependency names target \(name), which isn't there")
            }
            for root in try sources(of: target, name) where !linked.roots.contains(root) {
                linked.roots.append(root)
            }
            for product in try dependencies(of: target, name, packages: packages, then: &todo) where !linked.products.contains(product) {
                linked.products.append(product)
            }
        }
        return linked
    }

    /// `sources: App`, `- App/Sources` and `- path: App/Sources` alike.
    static func sources(of target: [String: Any], _ name: String) throws -> [String] {
        guard let value = target["sources"] else { return [] }
        let items = value as? [Any] ?? [value]
        return try items.map { item in
            if let path = item as? String { return path }
            if let entry = item as? [String: Any], Set(entry.keys) == ["path"], let path = entry["path"] as? String { return path }
            throw Unreadable("target \(name) has a source written as \(item)")
        }
    }

    /// The products of each `package:` entry, from `products: [...]`, a
    /// block list, `product:` or the package's own name. A `target:` entry
    /// is read as well, and anything else fails.
    static func dependencies(of target: [String: Any], _ name: String, packages: [String: Any], then todo: inout [String]) throws -> [String] {
        guard let value = target["dependencies"] else { return [] }
        guard let items = value as? [Any] else { throw Unreadable("target \(name)'s dependencies are not a list") }
        var products: [String] = []
        for item in items {
            guard let entry = item as? [String: Any] else { throw Unreadable("target \(name) has a dependency written as \(item)") }
            let kinds = Set(entry.keys).subtracting(linkKeys)
            if let other = entry["target"] as? String, kinds == ["target"] {
                todo.append(other)
            } else if let package = entry["package"] as? String, kinds.isSubset(of: ["package", "product", "products"]) {
                guard package == Self.package, (packages[package] as? [String: Any])?["path"] as? String == packagePath else {
                    throw Unreadable("target \(name) links package \(package)")
                }
                switch (entry["product"], entry["products"]) {
                case (nil, nil): products.append(package)
                case (let single as String, nil): products.append(single)
                case (nil, let many as [String]) where !many.isEmpty: products += many
                default: throw Unreadable("target \(name) names \(package)'s products as \(entry)")
                }
            } else {
                throw Unreadable("target \(name) has a dependency on \(entry.keys.sorted().joined(separator: ", "))")
            }
        }
        return products
    }
}
