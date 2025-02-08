//
//  UIElement+Extensions.swift
//  EasyReader
//
//  Created by Ewalk on 2025-01-20.
//

import ApplicationServices
import AXSwift

extension UIElement {
    func readableElement() throws -> ReadableElement? {
        guard let role: String = try attribute(.role) else { return nil }
        guard let readableType = ReadableElement[.init(role)] else { return nil }
        return readableType.init(self)
    }
}

extension UIElement: @retroactive Hashable {
    public func hash(into hasher: inout Hasher) {
        hasher.combine(element)
    }
}

//NOTE: overrides base implementation (because it's broken)
extension UIElement {
    func parameterizedAttribute<T, U>(_ attribute: Attribute, param: U) throws -> T? {
        let suffix = "Parameterized"
        var attributeValue = attribute.rawValue
        if attributeValue.hasSuffix(suffix) {
            attributeValue = String(attributeValue.dropLast(suffix.count))
        }
        return try parameterizedAttribute(attributeValue, param: param)
    }

    func parameterizedAttribute<T, U>(_ attribute: String, param: U) throws -> T? {
        var value: AnyObject?
        let error = AXUIElementCopyParameterizedAttributeValue(element, attribute as CFString, packAXValue(param), &value)
        if error == .noValue || error == .attributeUnsupported {
            return nil
        }
        guard error == .success else {
            throw error
        }
        return (unpackAXValue(value!) as! T)
    }

    private func packAXValue(_ value: Any) -> AnyObject {
        switch value {
            case let v as UIElement: return v.element
            case var v as CGPoint: return AXValueCreate(.cgPoint, &v)!
            case var v as CGSize: return AXValueCreate(.cgSize, &v)!
            case var v as CGRect: return AXValueCreate(.cgRect, &v)!
            case var v as CFRange: return AXValueCreate(.cfRange, &v)!
            default: return value as AnyObject
        }
    }

    private func unpackAXValue(_ value: AnyObject) -> Any {
        switch CFGetTypeID(value) {
            case AXUIElementGetTypeID():
                return UIElement(value as! AXUIElement)
            case AXValueGetTypeID():
                let axValue = value as! AXValue
                let type = AXValueGetType(axValue)
                switch type {
                    case .cgPoint:
                        var result: CGPoint = .zero
                        let success = AXValueGetValue(axValue, type, &result)
                        assert(success)
                        return result
                    case .cgSize:
                        var result: CGSize = .zero
                        let success = AXValueGetValue(axValue, type, &result)
                        assert(success)
                        return result
                    case .cgRect:
                        var result: CGRect = .zero
                        let success = AXValueGetValue(axValue, type, &result)
                        assert(success)
                        return result
                    case .cfRange:
                        var result: CFRange = CFRange()
                        let success = AXValueGetValue(axValue, type, &result)
                        assert(success)
                        return result
                    case .axError:
                        var result: AXError = .success
                        let success = AXValueGetValue(axValue, type, &result)
                        assert(success)
                        return result
                    case .illegal:
                        return value
                    @unknown default:
                        return value
                }
            default:
                return value
        }
    }
}
