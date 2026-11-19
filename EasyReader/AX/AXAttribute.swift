import ApplicationServices

/// An attribute name typed by its value; keys live in constrained extensions so `element.attribute(.frame)` infers `CGRect`.
struct AXAttribute<Value>: Hashable, CustomStringConvertible {
    let name: String

    init(_ name: String) {
        self.name = name
    }

    var description: String { name }
}

struct AXParameterizedAttribute<Parameter, Value> {
    let name: String

    init(_ name: String) {
        self.name = name
    }
}

struct AXRole: RawRepresentable, Hashable {
    let rawValue: String

    init(rawValue: String) {
        self.rawValue = rawValue
    }

    init(_ rawValue: String) {
        self.init(rawValue: rawValue)
    }

    static let application = AXRole(kAXApplicationRole)
    static let window = AXRole(kAXWindowRole)
    static let scrollArea = AXRole(kAXScrollAreaRole)
    static let textArea = AXRole(kAXTextAreaRole)
    static let webArea = AXRole("AXWebArea")
    static let staticText = AXRole(kAXStaticTextRole)
    static let listMarker = AXRole("AXListMarker")
    static let list = AXRole(kAXListRole)
    static let row = AXRole(kAXRowRole)
    static let group = AXRole(kAXGroupRole)
    static let heading = AXRole("AXHeading")
}

struct AXAction {
    let name: String

    static let scrollToVisible = AXAction(name: "AXScrollToVisible")
}

struct AXNotification: Hashable {
    let name: String

    static let uiElementDestroyed = AXNotification(name: kAXUIElementDestroyedNotification)
}

// MARK: Attributes

extension AXAttribute where Value == AXRole {
    static var role: Self { Self(kAXRoleAttribute) }
}

extension AXAttribute where Value == String {
    static var title: Self { Self(kAXTitleAttribute) }
    /// Text of text areas and leaves.
    static var value: Self { Self(kAXValueAttribute) }
    static var selectedText: Self { Self(kAXSelectedTextAttribute) }
    static var subrole: Self { Self(kAXSubroleAttribute) }
    static var identifier: Self { Self(kAXIdentifierAttribute) }
}

extension AXAttribute where Value == CGFloat {
    /// Position of a scroll bar (0...1).
    static var value: Self { Self(kAXValueAttribute) }
}

extension AXAttribute where Value == Bool {
    static var focused: Self { Self(kAXFocusedAttribute) }
    /// App-wide (Chromium): build the full AX tree, as for VoiceOver.
    static var enhancedUserInterface: Self { Self("AXEnhancedUserInterface") }
    /// App-wide (Electron): build the full AX tree.
    static var manualAccessibility: Self { Self("AXManualAccessibility") }
}

extension AXAttribute where Value == CFRange {
    static var selectedTextRange: Self { Self(kAXSelectedTextRangeAttribute) }
}

extension AXAttribute where Value == CGRect {
    static var frame: Self { Self("AXFrame") }
}

extension AXAttribute where Value == AXElement {
    static var parent: Self { Self(kAXParentAttribute) }
    static var window: Self { Self(kAXWindowAttribute) }
    static var mainWindow: Self { Self(kAXMainWindowAttribute) }
    static var focusedUIElement: Self { Self(kAXFocusedUIElementAttribute) }
    static var verticalScrollBar: Self { Self(kAXVerticalScrollBarAttribute) }
    static var horizontalScrollBar: Self { Self(kAXHorizontalScrollBarAttribute) }
}

extension AXAttribute where Value == [AXElement] {
    static var children: Self { Self(kAXChildrenAttribute) }
    static var childrenInNavigationOrder: Self { Self("AXChildrenInNavigationOrder") }
    static var windows: Self { Self(kAXWindowsAttribute) }
    static var visibleChildren: Self { Self(kAXVisibleChildrenAttribute) }
}

extension AXAttribute where Value == AXTextMarker {
    static var startTextMarker: Self { Self("AXStartTextMarker") }
    static var endTextMarker: Self { Self("AXEndTextMarker") }
}

extension AXAttribute where Value == AXTextMarkerRange {
    static var selectedTextMarkerRange: Self { Self("AXSelectedTextMarkerRange") }
}

// MARK: Parameterized attributes

extension AXParameterizedAttribute where Parameter == CFRange, Value == CGRect {
    static var boundsForRange: Self { Self(kAXBoundsForRangeParameterizedAttribute) }
}

extension AXParameterizedAttribute where Parameter == CFRange, Value == AXAttributedString {
    /// Runs carry `AXFont` (a dictionary with `AXFontSize`, …), `AXLanguage`, ….
    static var attributedStringForRange: Self { Self(kAXAttributedStringForRangeParameterizedAttribute) }
}

extension AXParameterizedAttribute where Parameter == CGPoint, Value == CFRange {
    /// The character at a screen point (top-left origin).
    static var rangeForPosition: Self { Self(kAXRangeForPositionParameterizedAttribute) }
}

extension AXParameterizedAttribute where Parameter == AXTextMarkerRange, Value == String {
    static var stringForTextMarkerRange: Self { Self("AXStringForTextMarkerRange") }
}

extension AXParameterizedAttribute where Parameter == AXTextMarkerRange, Value == AXAttributedString {
    /// Catalyst web views have only this one (no `AXStringForTextMarkerRange`).
    static var attributedStringForTextMarkerRange: Self { Self("AXAttributedStringForTextMarkerRange") }
}

extension AXParameterizedAttribute where Parameter == AXTextMarkerRange, Value == CGRect {
    static var boundsForTextMarkerRange: Self { Self("AXBoundsForTextMarkerRange") }
}

extension AXParameterizedAttribute where Parameter == [AXTextMarker], Value == AXTextMarkerRange {
    /// Chromium has only this (unordered) variant; WebKit also has the ordered one.
    static var textMarkerRangeForUnorderedTextMarkers: Self { Self("AXTextMarkerRangeForUnorderedTextMarkers") }
}

extension AXParameterizedAttribute where Parameter == AXTextMarker, Value == AXTextMarker {
    static var nextTextMarkerForTextMarker: Self { Self("AXNextTextMarkerForTextMarker") }
    static var previousTextMarkerForTextMarker: Self { Self("AXPreviousTextMarkerForTextMarker") }
    static var nextLineEndTextMarkerForTextMarker: Self { Self("AXNextLineEndTextMarkerForTextMarker") }
}

extension AXParameterizedAttribute where Parameter == AXTextMarker, Value == AXTextMarkerRange {
    static var paragraphTextMarkerRangeForTextMarker: Self { Self("AXParagraphTextMarkerRangeForTextMarker") }
}

extension AXParameterizedAttribute where Parameter == AXTextMarker, Value == AXElement {
    static var uiElementForTextMarker: Self { Self("AXUIElementForTextMarker") }
}

extension AXParameterizedAttribute where Parameter == AXTextMarker, Value == Int {
    static var indexForTextMarker: Self { Self("AXIndexForTextMarker") }
}

extension AXParameterizedAttribute where Parameter == Int, Value == AXTextMarker {
    static var textMarkerForIndex: Self { Self("AXTextMarkerForIndex") }
}

extension AXParameterizedAttribute where Parameter == CGRect, Value == AXTextMarker {
    /// Safari only (not `WKWebView`).
    static var startTextMarkerForBounds: Self { Self("AXStartTextMarkerForBounds") }
}

extension AXParameterizedAttribute where Parameter == CGPoint, Value == AXTextMarker {
    /// The text at a screen point (top-left origin), else the nearest.
    static var textMarkerForPosition: Self { Self("AXTextMarkerForPosition") }
}

extension AXParameterizedAttribute where Parameter == AXElement, Value == AXTextMarkerRange {
    static var textMarkerRangeForUIElement: Self { Self("AXTextMarkerRangeForUIElement") }
}

extension AXParameterizedAttribute where Parameter == AXSearchPredicate, Value == [AXSearchResult] {
    static var uiElementsForSearchPredicate: Self { Self("AXUIElementsForSearchPredicate") }
}

extension AXParameterizedAttribute where Parameter == AXTextOperation, Value == AXAnyValue {
    /// Chromium with chrome://flags/#enable-accessibility-text-operation.
    static var textOperation: Self { Self("AXTextOperation") }
}
