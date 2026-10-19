import Foundation

/// What a value holds, read through its stored properties, for the guards
/// that prove something keeps none of a person's words.
///
/// Every property is walked, a superclass's too, and each object once, so
/// a cycle ends. A `String`, `Substring`, `Character`, a non-empty
/// `[Character]`, `NSString` or `Data` counts as text, the last read as
/// UTF-8. Storage that reflection can't see, such as inside a lock, a
/// buffer or a closure's captures, is not found, so a guard should also
/// show the probe reached what it checks.
public struct StoredWords {
    /// Every piece of text found.
    public private(set) var texts: [String] = []
    /// Every UUID found, so a guard can show it reached real storage.
    public private(set) var ids: [UUID] = []
    /// The name of every type walked through, such as "ProposedAction",
    /// so a guard can fail on a kind of value, not only on its words.
    public private(set) var types: Set<String> = []

    private var visited = Set<ObjectIdentifier>()

    public init(in value: Any) {
        walk(value, depth: 0)
    }

    /// True when any text found holds `words`.
    public func contains(_ words: String) -> Bool {
        texts.contains { $0.contains(words) }
    }

    /// True when a value of a type with this name was walked through.
    public func holds(_ typeName: String) -> Bool {
        types.contains { $0 == typeName || $0.hasPrefix(typeName + "<") }
    }

    private mutating func walk(_ value: Any, depth: Int) {
        guard depth < 64 else { return }
        types.insert(String(describing: type(of: value)))
        if let text = value as? String { texts.append(text); return }
        if let text = value as? Substring { texts.append(String(text)); return }
        if let text = value as? Character { texts.append(String(text)); return }
        // An empty array of any type casts to `[Character]`, so only a
        // non-empty one is text.
        if let text = value as? [Character], !text.isEmpty { texts.append(String(text)); return }
        if let data = value as? Data { texts.append(String(decoding: data, as: UTF8.self)); return }
        if let id = value as? UUID { ids.append(id); return }
        let mirror = Mirror(reflecting: value)
        if mirror.displayStyle == .class {
            let object = value as AnyObject
            guard visited.insert(ObjectIdentifier(object)).inserted else { return }
            if let text = object as? NSString { texts.append(text as String); return }
        }
        var current: Mirror? = mirror
        while let each = current {
            for child in each.children { walk(child.value, depth: depth + 1) }
            current = each.superclassMirror
        }
    }
}
