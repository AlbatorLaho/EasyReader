//
//  WebAreaReadableElement.swift
//  EasyReader
//
//  Created by Ewalk on 24/12/14.
//

import Cocoa
import AXSwift

//extension ReadableElement.Role {
//    static let webArea: Self = "AXWebArea"
//}
//
//final class WebAreaReadableElement: ReadableElement {
//    var fullTextValues: [String] = []
//    override var fullText: String? {
//        fullTextValues.joined(separator: "\n")
//    }
////    override var selectedText: String? {}
////    override var selection: Selection? {
////        get {}
////        set {}
////    }
//        
////    override var fullText: String? { try? handle.attribute(.value) }
//    override var selectedText: String? { try? handle.attribute(.selectedText) }
//    override var selection: Selection? {
//        get {
//            guard let range: CFRange = try? handle.attribute(.selectedTextRange) else { return nil }
//            return Selection(range)
//        }
//        set {
//            guard let newSelection = newValue else { return }
//            try? handle.setAttribute(.selectedTextRange, value: CFRange(newSelection))
//        }
//    }
//    
//    static func recursiveChildren(_ element: UIElement, depth: Int) -> [UIElement] {
//        guard let children: [UIElement] = try? element.arrayAttribute(.children) else { return [] }
//        var mainElements: [UIElement] = []
//        for child in children {
//            for _ in 0..<depth { print(">", terminator: "") }
//            print("\(try? child.attribute(.role) as Any?) : \(try? child.attribute(.roleDescription) as Any?) : \(try? child.attribute(.subrole) as Any?)")
//            
//            switch try? child.attribute(.subrole) as String? {
//                case "AXLandmarkMain", "AXDocumentArticle":
//                    mainElements.append(child)
//                case "AXLandmarkBanner", "AXLandmarkNavigation", "AXLandmarkContentInfo":
//                    break
//                default:
//                    let elements = recursiveChildren(child, depth: depth + 1)
//                    mainElements.append(contentsOf: elements)
//            }
//        }
//        return mainElements
//    }
//
//    static func getAllText(_ element: UIElement, depth: Int) -> [String] {
//        guard let children: [UIElement] = try? element.arrayAttribute(.children) else { return [] }
//        var allText: [String] = []
//        for child in children {
//            for _ in 0..<depth { print(">", terminator: "") }
//            print("\(try? child.attribute(.role) as Any?) : \(try? child.attribute(.roleDescription) as Any?) : \(try? child.attribute(.subrole) as Any?)")
//            
//            switch try? child.role() {
//                case .staticText:
//                    if let staticTextValue: String = try? child.attribute(.value) {
//                        allText.append(staticTextValue)
//                    }
//                    for _ in 0..<depth { print(">", terminator: "") }
//                    print("StaticText: \(try? child.attribute(.value) as Any?)")
//                default:
//                    let text = getAllText(child, depth: depth + 1)
//                    allText.append(contentsOf: text)
//            }
//        }
//        return allText
//    }
//    
//    required init(_ element: UIElement) {
//        super.init(element)
//        
//        let children: [UIElement]? = try? handle.arrayAttribute(.children)
//        print("children: \(children?.count)")
////        print(children?.map({
////            let role: String? = try? $0.attribute(.role)
////            print(role as Any)
////            print(try? $0.attribute(.selectedText) as Any?)
////            print(try? $0.attribute(.selectedTextRange) as Any?)
////            print(try? $0.attribute("AXDOMIdentifier") as Any?)
////            print(try? $0.attribute("AXDOMClassList") as Any?)
////            print(try? $0.attribute("AXBlockQuoteLevel") as Any?)
////            print(try? $0.attribute("AXStartTextMarker") as Any?)
////            print(try? $0.attribute("AXEndTextMarker") as Any?)
////            print(try? $0.attribute("AXSelectedTextMarkerRange") as Any?)
////            return $0
////        }) as Any)
//        print("WebArea: >>>")
//        let mainElements = Self.recursiveChildren(element, depth: 0)
//        print("<<<getting text>>>")
//        for mainElement in mainElements {
//            print(mainElement)
//            let allText = Self.getAllText(mainElement, depth: 0)
//            print(allText)
//            fullTextValues.append(contentsOf: allText)
//        }
//        print("WebArea: <<<")
//        selection = Selection()
//    }
//}
