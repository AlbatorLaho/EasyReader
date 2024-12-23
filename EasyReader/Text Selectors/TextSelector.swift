//
//  TextSelector.swift
//  EasyReader
//
//  Created by Ewalk on 24/11/4.
//

import Foundation

enum SelectUnit {
    case sentence
    case paragraph
}

enum SelectDirection {
    case backward
    case forward
}

protocol TextSelector {
    init(unit: SelectUnit);

    func select(_ direction: SelectDirection, from selection: Selection, in string: String) -> Selection;
}
