//
//  RTag.swift
//  Zotero
//
//  Created by Michal Rentka on 25/02/2019.
//  Copyright © 2019 Corporation for Digital Scholarship. All rights reserved.
//

import Foundation

import RealmSwift

struct RTagChanges: OptionSet {
    typealias RawValue = Int16

    let rawValue: Int16

    init(rawValue: Int16) {
        self.rawValue = rawValue
    }
}
extension RTagChanges {
    static let name = RTagChanges(rawValue: 1 << 1)
    static let color = RTagChanges(rawValue: 1 << 2)
    static let all: RTagChanges = [.name, .color]
}

class RTag: Object {
    @objc dynamic var name: String = ""
    @objc dynamic var color: String = ""
    @objc dynamic var library: RLibrary?
    /// Raw value for OptionSet of changes for this object
    @objc dynamic var rawChangedFields: Int16 = 0
    let items: List<RItem> = List()

    var changedFields: RTagChanges {
        get {
            return RTagChanges(rawValue: self.rawChangedFields)
        }

        set {
            self.rawChangedFields = newValue.rawValue
        }
    }

    var uiColor: UIColor? {
        guard !self.color.isEmpty else { return nil }
        return UIColor(hex: self.color)
    }

    override class func indexedProperties() -> [String] {
        return ["name"]
    }
}
