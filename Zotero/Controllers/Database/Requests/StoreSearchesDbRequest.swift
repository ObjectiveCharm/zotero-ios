//
//  StoreSearchesDbRequest.swift
//  Zotero
//
//  Created by Michal Rentka on 25/02/2019.
//  Copyright © 2019 Corporation for Digital Scholarship. All rights reserved.
//

import Foundation

import RealmSwift

struct StoreSearchesDbRequest: DbRequest {
    let response: [SearchResponse]

    var needsWrite: Bool { return true }
    var ignoreNotificationTokens: [NotificationToken]? { return nil }

    func process(in database: Realm) throws {
        for data in self.response {
            try self.store(data: data, to: database)
        }
    }

    private func store(data: SearchResponse, to database: Realm) throws {
        guard let libraryId = data.library.libraryId else { throw DbError.primaryKeyUnavailable }
        let search: RSearch
        if let existing = database.objects(RSearch.self).filter(.key(data.key, in: libraryId)).first {
            search = existing
        } else {
            search = RSearch()
            database.add(search)
        }

        search.key = data.key
        search.name = data.data.name
        search.version = data.version
        search.syncState = .synced
        search.syncRetries = 0
        search.lastSyncDate = Date(timeIntervalSince1970: 0)
        search.libraryId = libraryId
        search.trash = data.data.isTrash

        // No CR for searches, if it was changed or deleted locally, just restore it
        search.deleted = false
        search.resetChanges()

        self.syncConditions(data: data, search: search, database: database)
    }

    private func syncConditions(data: SearchResponse, search: RSearch, database: Realm) {
        database.delete(search.conditions)

        for object in data.data.conditions.enumerated() {
            let condition = RCondition()
            condition.condition = object.element.condition
            condition.operator = object.element.operator
            condition.value = object.element.value
            condition.sortId = object.offset
            search.conditions.append(condition)
        }
    }
}
