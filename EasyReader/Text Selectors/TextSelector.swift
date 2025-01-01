//
//  TextSelector.swift
//  EasyReader
//
//  Created by Ewalk on 24/11/4.
//

import Foundation

protocol TextSelector {
    init(unit: Selection.Unit);

    func select(_ direction: Selection.Direction, from selection: Selection, in string: String) -> Selection;
}
