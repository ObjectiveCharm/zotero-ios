//
//  RPageIndex.swift
//  Zotero
//
//  Created by Michal Rentka on 18.02.2021.
//  Copyright © 2021 Corporation for Digital Scholarship. All rights reserved.
//

import Foundation

import RealmSwift

struct RPageIndexChanges: OptionSet {
    typealias RawValue = Int16

    let rawValue: Int16

    init(rawValue: Int16) {
        self.rawValue = rawValue
    }
}

extension RPageIndexChanges {
    static let index = RPageIndexChanges(rawValue: 1 << 0)
}

final class RPageIndex: Object {
    @Persisted(indexed: true) var key: String
    @Persisted var index: Int
    @Persisted var changed: Bool
    @Persisted var customLibraryKey: Int?
    @Persisted var groupKey: Int?

    // MARK: - Sync data
    /// Indicates local version of object
    @Persisted(indexed: true) var version: Int
    /// State which indicates whether object is synced with backend data, see ObjectSyncState for more info
    @Persisted var rawSyncState: Int
    /// Date when last sync attempt was performed on this object
    @Persisted var lastSyncDate: Date
    /// Number of retries for sync of this object
    @Persisted var syncRetries: Int
    /// Raw value for OptionSet of changes for this object, indicates which local changes need to be synced to backend
    @Persisted var rawChangedFields: Int16
    /// Raw value for `UpdatableChangeType`, indicates whether current update of item has been made by user or sync process.
    @Persisted var rawChangeType: Int

    // MARK: - Sync properties

    var changedFields: RPageIndexChanges {
        get {
            return RPageIndexChanges(rawValue: self.rawChangedFields)
        }

        set {
            self.rawChangedFields = newValue.rawValue
        }
    }
}
