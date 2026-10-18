import Foundation

/// What a value holds, read through its stored properties, for the guards
/// that prove something keeps none of a person's words.
///
/// Every property is walked, a superclass's too, and each object once, so
/// a cycle ends. A `String`, `Substring`, `Character`, `[Character]`,
/// `NSString` or `Data` counts as text, the last read as UTF-8. Storage
/// that reflection can't see, such as inside a lock or a buffer, is not
/// found, so a guard should also show the probe reached what it checks.
public struct StoredWords {
    /// Every piece of text found.
    public private(set) var texts: [String] = []
    /// Every UUID found, so a guard can show it reached real storage.
    public private(set) var ids: [UUID] = []

    private var visited = Set<ObjectIdentifier>()

    public init(in value: Any) {
        walk(value, depth: 0)
    }

    /// True when any text found holds `words`.
    public func contains(_ words: String) -> Bool {
        texts.contains { $0.contains(words) }
    }

    private mutating func walk(_ value: Any, depth: Int) {
        guard depth < 64 else { return }
        if let text = value as? String { texts.append(text); return }
        if let text = value as? Substring { texts.append(String(text)); return }
        if let text = value as? Character { texts.append(String(text)); return }
        if let text = value as? [Character] { texts.append(String(text)); return }
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
