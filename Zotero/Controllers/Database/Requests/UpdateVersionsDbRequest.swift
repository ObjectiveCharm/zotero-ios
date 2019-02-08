//
//  UpdateVersionsDbRequest.swift
//  Zotero
//
//  Created by Michal Rentka on 08/02/2019.
//  Copyright © 2019 Corporation for Digital Scholarship. All rights reserved.
//

import Foundation

import RealmSwift

struct UpdateVersionsDbRequest: DbRequest {
    let version: Int
    let object: SyncObjectType
    let libraryId: Int

    var needsWrite: Bool { return true }

    init(version: Int, object: SyncObjectType, group: SyncGroupType) {
        self.version = version
        self.object = object
        switch group {
        case .group(let groupId):
            self.libraryId = groupId
        case .user:
            self.libraryId = RLibrary.myLibraryId
        }
    }

    func process(in database: Realm) throws {
        guard let library = database.object(ofType: RLibrary.self, forPrimaryKey: self.libraryId) else {
            throw DbError.objectNotFound
        }

        let versions: RVersions = library.versions ?? RVersions()
        if library.versions == nil {
            database.add(versions)
            library.versions = versions
        }

        switch self.object {
        case .group:
            throw DbError.objectNotFound
        case .collection:
            versions.collections = self.version
        case .item:
            versions.items = self.version
        case .trash:
            versions.trash = self.version
        case .search:
            versions.searches = self.version
        }
    }
}
