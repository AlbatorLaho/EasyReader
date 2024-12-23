//
//  TextAreaReadableElement.swift
//  EasyReader
//
//  Created by Ewalk on 24/12/14.
//

import Cocoa
import AXSwift

extension ReadableElement.Role {
    static let textArea = Self(kAXTextAreaRole)
//    static let textArea: Self = "AXTextArea"
}

final class TextAreaReadableElement: ReadableElement {
    private let scrollArea: UIElement?

    override var fullText: String? { try? handle.attribute(.value) }
    override var selectedText: String? { try? handle.attribute(.selectedText) }
    override var selection: Selection? {
        get {
            guard let range: CFRange = try? handle.attribute(.selectedTextRange) else { return nil }
            return Selection(range)
        }
        set {
            guard let newSelection = newValue else { return }
            try? handle.setAttribute(.selectedTextRange, value: CFRange(newSelection))
        }
    }

    required init(_ element: UIElement) {
        scrollArea = try? element.parent(with: .scrollArea)
        super.init(element)
    }
    
    override func scroll(to selection: Selection) {
//        TODO: change something so we can just pass in CFRange instead of using AXValue.range
        guard let selectionBounds: CGRect = try? handle.parameterizedAttribute(kAXBoundsForRangeParameterizedAttribute, param: AXValue.range(CFRange(selection))),
              let contentFrame: CGRect = try? handle.attribute(.frame),
              let viewableFrame: CGRect = try? scrollArea?.attribute(.frame),
              !viewableFrame.contains(selectionBounds),
              selectionBounds.size != .zero
        else { return }
                
        if let horizontalScrollBar: UIElement = try? scrollArea?.attribute(.horizontalScrollBar) {
            let value = selectionBounds.origin.x - contentFrame.origin.x
            let max = contentFrame.width - viewableFrame.width
            let scroll = max.isNormal ? value / max : 0
            try? horizontalScrollBar.setAttribute(.value, value: scroll)
        }
        if let verticalScrollBar: UIElement = try? scrollArea?.attribute(.verticalScrollBar) {
            let value = selectionBounds.origin.y - contentFrame.origin.y
            let max = contentFrame.height - viewableFrame.height
            let scroll = max.isNormal ? value / max : 0
            try? verticalScrollBar.setAttribute(.value, value: scroll)
        }
    }
}
