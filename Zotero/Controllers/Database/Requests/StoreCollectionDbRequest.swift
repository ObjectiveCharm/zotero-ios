//
//  StoreCollectionDbRequest.swift
//  Zotero
//
//  Created by Michal Rentka on 18/03/2019.
//  Copyright © 2019 Corporation for Digital Scholarship. All rights reserved.
//

import Foundation

import RealmSwift

struct StoreCollectionDbRequest: DbRequest {
    let libraryId: LibraryIdentifier
    let key: String
    let name: String
    let parentKey: String?

    var needsWrite: Bool {
        return true
    }

    func process(in database: Realm) throws {
        let predicate = Predicates.keyInLibrary(key: self.key, libraryId: self.libraryId)
        guard let collection = database.objects(RCollection.self).filter(predicate).first else { return }

        var changes: RCollectionChanges = []

        if collection.name != self.name {
            collection.name = self.name
            changes.insert(.name)
        }

        if collection.parent?.key != self.parentKey {
            if let key = self.parentKey {
                let predicate = Predicates.keyInLibrary(key: key, libraryId: self.libraryId)
                collection.parent = database.objects(RCollection.self).filter(predicate).first
            } else {
                collection.parent = nil
            }
            changes.insert(.parent)
        }

        if collection.rawChangedFields != changes.rawValue {
            collection.changedFields = changes
        }
    }
}
