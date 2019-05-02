//
//  RSearch.swift
//  Zotero
//
//  Created by Michal Rentka on 25/02/2019.
//  Copyright © 2019 Corporation for Digital Scholarship. All rights reserved.
//

import Foundation

import RealmSwift

struct RSearchChanges: OptionSet {
    typealias RawValue = Int16

    let rawValue: Int16

    init(rawValue: Int16) {
        self.rawValue = rawValue
    }
}

extension RSearchChanges {
    static let name = RSearchChanges(rawValue: 1 << 0)
    static let conditions = RSearchChanges(rawValue: 1 << 1)
    static let all: RSearchChanges = [.name, .conditions]
}

class RSearch: Object {
    @objc dynamic var key: String = ""
    @objc dynamic var name: String = ""
    @objc dynamic var version: Int = 0
    /// State which indicates whether object is synced with backend data, see ObjectSyncState for more info
    @objc dynamic var rawSyncState: Int = 0
    /// Raw value for OptionSet of changes for this object, indicates which local changes need to be synced to backend
    @objc dynamic var rawChangedFields: Int16 = 0
    @objc dynamic var dateModified: Date = Date(timeIntervalSince1970: 0)
    @objc dynamic var customLibrary: RCustomLibrary?
    @objc dynamic var group: RGroup?
    let conditions = LinkingObjects(fromType: RCondition.self, property: "search")

    var changedFields: RSearchChanges {
        get {
            return RSearchChanges(rawValue: self.rawChangedFields)
        }

        set {
            self.rawChangedFields = newValue.rawValue
        }
    }

    var syncState: ObjectSyncState {
        get {
            return ObjectSyncState(rawValue: self.rawSyncState) ?? .synced
        }

        set {
            self.rawSyncState = newValue.rawValue
        }
    }

    override class func indexedProperties() -> [String] {
        return ["version", "key"]
    }
}

class RCondition: Object {
    @objc dynamic var condition: String = ""
    @objc dynamic var `operator`: String = ""
    @objc dynamic var value: String = ""
    @objc dynamic var sortId: Int = 0
    @objc dynamic var search: RSearch?
}
