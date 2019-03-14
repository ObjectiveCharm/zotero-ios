//
//  SyncUpdateDataSource.swift
//  Zotero
//
//  Created by Michal Rentka on 08/03/2019.
//  Copyright © 2019 Corporation for Digital Scholarship. All rights reserved.
//

import Foundation

import RealmSwift

protocol SyncUpdateDataSource: class {
    func updates(for library: SyncController.Library, versions: Versions) throws -> [SyncController.WriteBatch]
}

final class UpdateDataSource: SyncUpdateDataSource {
    private let dbStorage: DbStorage

    init(dbStorage: DbStorage) {
        self.dbStorage = dbStorage
    }

    func updates(for library: SyncController.Library, versions: Versions) throws -> [SyncController.WriteBatch] {
        let coordinator = try self.dbStorage.createCoordinator()
        // Since we're sending items and trashed items together, let's send min of their versions in case trash
        // is not up to date with items (yet), but most of the time they should be the same anyway
        let itemVersion = min(versions.items, versions.trash)
        return (try self.updates(object: .collection, library: library,
                                 version: versions.collections, coordinator: coordinator)) +
               (try self.updates(object: .search, library: library,
                                 version: versions.searches, coordinator: coordinator)) +
               (try self.updates(object: .item, library: library,
                                 version: itemVersion, coordinator: coordinator))
    }

    private func updates(object: SyncController.Object, library: SyncController.Library, version: Int,
                         coordinator: DbCoordinator) throws -> [SyncController.WriteBatch] {
        let parameters: [[String: Any]]
        switch object {
        case .collection:
            let request = ReadChangedCollectionUpdateParametersDbRequest(libraryId: library.libraryId)
            parameters = try coordinator.perform(request: request)
        case .search:
            let request = ReadChangedSearchUpdateParametersDbRequest(libraryId: library.libraryId)
            parameters = try coordinator.perform(request: request)
        case .item, .trash:
            let request = ReadChangedItemUpdateParametersDbRequest(libraryId: library.libraryId)
            parameters = try coordinator.perform(request: request)
        case .group:
            fatalError("UpdateDataSource: Updating unsupported object type")
        }
        return parameters.chunked(into: SyncController.WriteBatch.maxCount)
                         .map({ SyncController.WriteBatch(library: library, object: object,
                                                          version: version, parameters: $0) })
    }
}
