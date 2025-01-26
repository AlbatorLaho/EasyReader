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

    override func scroll(to selection: Selection, options: ScrollOptions) {
        guard let selectionBounds: CGRect = try? handle.parameterizedAttribute(.boundsForRangeParameterized, param: CFRange(selection)),
              let contentFrame: CGRect = try? handle.attribute(.frame),
              let scrollAreaFrame: CGRect = try? scrollArea?.attribute(.frame)
        else { return }

        let viewableFrame = scrollAreaFrame.insetBy(dx: 0, dy: CGFloat(options.padding))
        guard !viewableFrame.contains(selectionBounds), selectionBounds.size != .zero else { return }

        if let horizontalScrollBar: UIElement = try? scrollArea?.attribute(.horizontalScrollBar) {
            let value = selectionBounds.origin.x - contentFrame.origin.x
            let max = contentFrame.width - viewableFrame.width
            let scrollValue = max.isNormal ? value / max : 0
            if options.smooth {
                lerpScroll(for: horizontalScrollBar, to: scrollValue, options: options)
            } else {
                try? horizontalScrollBar.setAttribute(.value, value: scrollValue)
            }
        }
        if let verticalScrollBar: UIElement = try? scrollArea?.attribute(.verticalScrollBar) {
            let value = selectionBounds.origin.y - contentFrame.origin.y
            let max = contentFrame.height - viewableFrame.height
            let scrollValue = max.isNormal ? value / max : 0
            if options.smooth {
                lerpScroll(for: verticalScrollBar, to: scrollValue, options: options)
            } else {
                try? verticalScrollBar.setAttribute(.value, value: scrollValue)
            }
        }
    }

    private func lerpScroll(for scrollBar: UIElement, to target: CGFloat, options: ScrollOptions) {
        guard let current: CGFloat = try? scrollBar.attribute(.value) else {
            try? scrollBar.setAttribute(.value, value: target)
            return
        }

        let frameInterval = 1.0 / options.updateRate
        let totalFrames = Int(options.duration / frameInterval)
        let step = (target - current) / CGFloat(totalFrames)
        var currentFrame = 0

        Timer.scheduledTimer(withTimeInterval: frameInterval, repeats: true) { timer in
            let value: CGFloat
            if currentFrame >= totalFrames {
                timer.invalidate()
                value = target
            } else {
                value = current + (step * CGFloat(currentFrame))
            }
            try? scrollBar.setAttribute(.value, value: value)
            currentFrame += 1
        }
    }
}
