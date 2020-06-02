//
//  MarkForResyncDbAction.swift
//  Zotero
//
//  Created by Michal Rentka on 08/02/2019.
//  Copyright © 2019 Corporation for Digital Scholarship. All rights reserved.
//

import Foundation

import RealmSwift

struct MarkForResyncDbAction<Obj: SyncableObject&Updatable>: DbRequest {
    let libraryId: LibraryIdentifier
    let keys: [String]

    var needsWrite: Bool { return true }

    init(libraryId: LibraryIdentifier, keys: [Any]) throws {
        guard let typedKeys = keys as? [String] else { throw DbError.primaryKeyWrongType }
        self.libraryId = libraryId
        self.keys = typedKeys
    }

    func process(in database: Realm) throws {
        let syncDate = Date()
        var toCreate: [String] = self.keys
        let objects = database.objects(Obj.self).filter(.keys(self.keys, in: self.libraryId))
        objects.forEach { object in
            if object.syncState == .synced {
                object.syncState = .outdated
            }
            object.syncRetries += 1
            object.lastSyncDate = syncDate
            object.changeType = .sync
            if let index = toCreate.firstIndex(of: object.key) {
                toCreate.remove(at: index)
            }
        }

        let (isNew, libraryObject) = try database.autocreatedLibraryObject(forPrimaryKey: self.libraryId)
        if isNew {
            switch libraryObject {
            case .group(let group):
                group.syncState = .dirty
            case .custom: break
            }
        }

        toCreate.forEach { key in
            let object = Obj()
            object.key = key
            object.syncState = .dirty
            object.syncRetries = 1
            object.lastSyncDate = syncDate
            object.libraryObject = libraryObject
            database.add(object)
        }
    }
}

struct MarkGroupForResyncDbAction: DbRequest {
    let identifier: Int

    var needsWrite: Bool { return true }

    func process(in database: Realm) throws {
        if let library = database.object(ofType: RGroup.self, forPrimaryKey: self.identifier) {
            if library.syncState == .synced {
                library.syncState = .outdated
            }
        } else {
            let library = RGroup()
            library.identifier = identifier
            library.syncState = .dirty
            database.add(library)
        }
    }
}
