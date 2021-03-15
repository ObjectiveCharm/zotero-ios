//
//  EditCollectionDbRequest.swift
//  Zotero
//
//  Created by Michal Rentka on 18/03/2019.
//  Copyright © 2019 Corporation for Digital Scholarship. All rights reserved.
//

import Foundation

import RealmSwift

struct EditCollectionDbRequest: DbRequest {
    let libraryId: LibraryIdentifier
    let key: String
    let name: String
    let parentKey: String?

    var needsWrite: Bool { return true }
    var ignoreNotificationTokens: [NotificationToken]? { return nil }

    func process(in database: Realm) throws {
        guard let collection = database.objects(RCollection.self).filter(.key(self.key, in: self.libraryId)).first else { return }

        var changes: RCollectionChanges = []

        if collection.name != self.name {
            collection.name = self.name
            changes.insert(.name)
        }

        if collection.parent?.key != self.parentKey {
            if let key = self.parentKey {
                collection.parent = database.objects(RCollection.self).filter(.key(key, in: self.libraryId)).first
            } else {
                collection.parent = nil
            }
            changes.insert(.parent)
        }

        collection.changedFields = changes
        collection.changeType = .user
    }
}
