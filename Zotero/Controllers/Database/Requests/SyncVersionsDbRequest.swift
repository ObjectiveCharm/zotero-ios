//
//  SyncVersionsDbRequest.swift
//  Zotero
//
//  Created by Michal Rentka on 05/02/2019.
//  Copyright © 2019 Corporation for Digital Scholarship. All rights reserved.
//

import Foundation

import RealmSwift

extension RCollection: SyncableObject {
    func removeChildren(in database: Realm) {
        self.items.forEach { item in
            item.removeChildren(in: database)
        }
        database.delete(self.items)
        self.children.forEach { child in
            child.removeChildren(in: database)
        }
        database.delete(self.children)
    }
}

extension RItem: SyncableObject {
    func removeChildren(in database: Realm) {
        self.children.forEach { child in
            child.removeChildren(in: database)
        }
        database.delete(self.children)
    }
}

extension RSearch: SyncableObject {
    func removeChildren(in database: Realm) {}
}

struct SyncVersionsDbRequest<Obj: Syncable>: DbResponseRequest {
    typealias Response = [String]

    let versions: [String: Int]
    let libraryId: Int
    let isTrash: Bool?
    let syncAll: Bool

    var needsWrite: Bool { return true }

    func process(in database: Realm) throws -> [String] {
        let allKeys = Array(self.versions.keys)

        if self.syncAll { return allKeys }

        var toUpdate: [String] = allKeys
        var objects = database.objects(Obj.self)
        if let trash = self.isTrash {
            objects = objects.filter("trash = %d", trash)
        }
        objects.forEach { object in
            if object.needsSync {
                if !toUpdate.contains(object.key) {
                    toUpdate.append(object.key)
                }
            } else {
                if let version = self.versions[object.key], version == object.version,
                   let index = toUpdate.index(of: object.key) {
                    toUpdate.remove(at: index)
                }
            }
        }
        return toUpdate
    }
}


struct SyncGroupVersionsDbRequest: DbResponseRequest {
    typealias Response = [Int]

    let versions: [Int: Int]
    let syncAll: Bool

    var needsWrite: Bool { return true }

    func process(in database: Realm) throws -> [Int] {
        let allKeys = Array(self.versions.keys)

        let toRemove = database.objects(RLibrary.self)
                               .filter("identifier != %d AND (NOT identifier IN %@)", RLibrary.myLibraryId, allKeys)
        toRemove.forEach { library in
            library.collections.forEach { collection in
                collection.removeChildren(in: database)
            }
            database.delete(library.collections)
            library.items.forEach { item in
                item.removeChildren(in: database)
            }
            database.delete(library.items)
        }
        database.delete(toRemove)

        if self.syncAll { return allKeys }

        var toUpdate: [Int] = allKeys
        for library in database.objects(RLibrary.self) {
            guard library.identifier != RLibrary.myLibraryId else { continue }
            if library.needsSync {
                if !toUpdate.contains(library.identifier) {
                    toUpdate.append(library.identifier)
                }
            } else {
                if let version = self.versions[library.identifier], version == library.version,
                   let index = toUpdate.index(of: library.identifier) {
                    toUpdate.remove(at: index)
                }
            }
        }
        return toUpdate
    }
}
