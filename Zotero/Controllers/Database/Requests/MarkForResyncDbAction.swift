//
//  MarkForResyncDbAction.swift
//  Zotero
//
//  Created by Michal Rentka on 08/02/2019.
//  Copyright © 2019 Corporation for Digital Scholarship. All rights reserved.
//

import Foundation

import RealmSwift

struct MarkForResyncDbAction<Obj: SyncableObject>: DbRequest {
    let libraryId: LibraryIdentifier
    let keys: [String]

    var needsWrite: Bool { return true }

    init(libraryId: LibraryIdentifier, keys: [Any]) throws {
        guard let typedKeys = keys as? [String] else { throw DbError.primaryKeyWrongType }
        self.libraryId = libraryId
        self.keys = typedKeys
    }

    func process(in database: Realm) throws {
        var toCreate: [String] = self.keys
        let objects = database.objects(Obj.self).filter(Predicates.keysInLibrary(keys: self.keys,
                                                                                 libraryId: self.libraryId))
        objects.forEach { object in
            if object.syncState == .synced {
                object.syncState = .outdated
            }
            if let index = toCreate.firstIndex(of: object.key) {
                toCreate.remove(at: index)
            }
        }

        let libraryData = try database.autocreatedLibraryObject(forPrimaryKey: self.libraryId)
        if libraryData.0 {
            switch libraryData.1 {
            case .group(let group):
                group.syncState = .dirty
            case .custom: break
            }
        }

        toCreate.forEach { key in
            let object = Obj()
            object.key = key
            object.syncState = .dirty
            object.libraryObject = libraryData.1
            database.add(object)
        }
    }
}

struct MarkGroupForResyncDbAction: DbRequest {
    let identifiers: [Int]

    var needsWrite: Bool { return true }

    init(identifiers: [Any]) throws {
        guard let typedIds = identifiers as? [Int] else { throw DbError.primaryKeyWrongType }
        self.identifiers = typedIds
    }

    func process(in database: Realm) throws {
        var toCreate: [Int] = self.identifiers
        let libraries = database.objects(RGroup.self).filter("identifier IN %@", self.identifiers)
        libraries.forEach { library in
            if let index = toCreate.firstIndex(of: library.identifier) {
                toCreate.remove(at: index)
            }
            if library.syncState == .synced {
                library.syncState = .outdated
            }
        }

        toCreate.forEach { identifier in
            let library = RGroup()
            library.identifier = identifier
            library.syncState = .dirty
            database.add(library)
        }
    }
}
