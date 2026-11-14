import ApplicationServices

/// Reads return `nil` for a missing attribute or value and throw `AXFailure` otherwise (also for a value of the wrong type).
struct AXElement: Hashable, CustomStringConvertible {
    let raw: AXUIElement

    init(_ raw: AXUIElement) {
        self.raw = raw
    }

    static func application(pid: pid_t) -> AXElement {
        AXElement(AXUIElementCreateApplication(pid))
    }

    /// With `prompt`, asks the user (only while untrusted).
    static func isProcessTrusted(prompt: Bool = false) -> Bool {
        AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": prompt] as CFDictionary)
    }

    func pid() throws -> pid_t {
        var pid: pid_t = 0
        let error = AXUIElementGetPid(raw, &pid)
        guard error == .success else { throw AXFailure.error(error, "pid") }
        return pid
    }

    // MARK: Attributes

    func attribute<Value: AXDecodable>(_ attribute: AXAttribute<Value>) throws -> Value? {
        var value: AnyObject?
        let error = AXUIElementCopyAttributeValue(raw, attribute.name as CFString, &value)
        return try Self.decode(value, error: error, attribute: attribute.name)
    }

    func attribute<Parameter: AXEncodable, Value: AXDecodable>(
        _ attribute: AXParameterizedAttribute<Parameter, Value>, for parameter: Parameter
    ) throws -> Value? {
        var value: AnyObject?
        let error = AXUIElementCopyParameterizedAttributeValue(raw, attribute.name as CFString, parameter.axValue, &value)
        return try Self.decode(value, error: error, attribute: attribute.name)
    }

    /// Unlike reads, throws when the attribute isn't supported.
    func set<Value: AXEncodable>(_ attribute: AXAttribute<Value>, to value: Value) throws {
        let error = AXUIElementSetAttributeValue(raw, attribute.name as CFString, value.axValue)
        guard error == .success else { throw AXFailure.error(error, "set \(attribute.name)") }
    }

    func isSettable<Value>(_ attribute: AXAttribute<Value>) -> Bool {
        var settable = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(raw, attribute.name as CFString, &settable) == .success && settable.boolValue
    }

    func perform(_ action: AXAction) throws {
        let error = AXUIElementPerformAction(raw, action.name as CFString)
        guard error == .success else { throw AXFailure.error(error, action.name) }
    }

    var attributeNames: [String] {
        var names: CFArray?
        guard AXUIElementCopyAttributeNames(raw, &names) == .success else { return [] }
        return names as? [String] ?? []
    }

    var parameterizedAttributeNames: [String] {
        var names: CFArray?
        guard AXUIElementCopyParameterizedAttributeNames(raw, &names) == .success else { return [] }
        return names as? [String] ?? []
    }

    private static func decode<Value: AXDecodable>(_ value: AnyObject?, error: AXError, attribute: String) throws -> Value? {
        if error == .noValue || error == .attributeUnsupported || error == .parameterizedAttributeUnsupported { return nil }
        guard error == .success else { throw AXFailure.error(error, attribute) }
        guard let value else { return nil }
        guard let decoded = Value(axValue: value) else {
            throw AXFailure.typeMismatch(attribute, expected: "\(Value.self)", found: CFCopyTypeIDDescription(CFGetTypeID(value)) as String)
        }
        return decoded
    }

    // MARK: Hierarchy

    func role() throws -> AXRole? {
        try attribute(.role)
    }

    func parent() throws -> AXElement? {
        try attribute(.parent)
    }

    /// How far ancestor walks go, so a parent cycle can't hang.
    static let maxDepth = 100

    func parent(with role: AXRole) throws -> AXElement? {
        var current = self
        for _ in 0..<Self.maxDepth {
            guard let parent = try current.parent() else { return nil }
            if try parent.role() == role { return parent }
            current = parent
        }
        return nil
    }

    // MARK: Hashable

    static func == (lhs: AXElement, rhs: AXElement) -> Bool {
        CFEqual(lhs.raw, rhs.raw)
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(CFHash(raw))
    }

    var description: String {
        "AXElement(\((try? role())?.rawValue ?? "unknown role"))"
    }
}

enum AXFailure: Error, CustomStringConvertible {
    case error(AXError, String)
    case typeMismatch(String, expected: String, found: String)

    var description: String {
        switch self {
            case .error(let error, let operation): "\(operation): AXError \(error.rawValue)"
            case .typeMismatch(let attribute, let expected, let found): "\(attribute): expected \(expected), found \(found)"
        }
    }
}
