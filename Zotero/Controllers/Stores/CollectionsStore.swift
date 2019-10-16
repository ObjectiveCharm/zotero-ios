//
//  CollectionsStore.swift
//  Zotero
//
//  Created by Michal Rentka on 10/02/2019.
//  Copyright © 2019 Corporation for Digital Scholarship. All rights reserved.
//

import Combine
import Foundation

import CocoaLumberjack
import RealmSwift
import RxSwift

class CollectionsStore: ObservableObject {
    enum Error: Swift.Error, Equatable {
        case dataLoading
        case collectionNotFound
        case deletion
    }
    
    struct State {
        enum EditingType: Identifiable {
            case add
            case addSubcollection(Collection)
            case edit(Collection)

            var id: String {
                switch self {
                case .add:
                    return "add"
                case .addSubcollection(let collection):
                    return "addsub" + collection.key
                case .edit(let collection):
                    return "edit" + collection.key
                }
            }
        }

        let library: Library

        var selectedCollection: Collection
        fileprivate(set) var collections: [Collection]
        fileprivate(set) var error: Error?
        fileprivate var collectionToken: NotificationToken?
        fileprivate var searchToken: NotificationToken?

        var editingType: EditingType?
    }
    
    @Published var state: State {
        didSet {
            if self.state.selectedCollection.id != oldValue.selectedCollection.id {
                NotificationCenter.default.post(name: .splitViewDetailChanged,
                                                object: (self.state.selectedCollection, self.state.library))
            }
        }
    }

    private let dbStorage: DbStorage

    init(library: Library, dbStorage: DbStorage) {
        self.dbStorage = dbStorage

        do {
            let collectionsRequest = ReadCollectionsDbRequest(libraryId: library.identifier)
            let collections = try dbStorage.createCoordinator().perform(request: collectionsRequest)
            let searchesRequest = ReadSearchesDbRequest(libraryId: library.identifier)
            let searches = try dbStorage.createCoordinator().perform(request: searchesRequest)

            var allCollections: [Collection] = [Collection(custom: .all),
                                                Collection(custom: .publications),
                                                Collection(custom: .trash)]
            allCollections.insert(contentsOf: CollectionTreeBuilder.collections(from: collections) +
                                              CollectionTreeBuilder.collections(from: searches),
                                  at: 1)

            self.state = State(library: library,
                               selectedCollection: allCollections[0],
                               collections: allCollections)

            let collectionToken = collections.observe({ [weak self] changes in
                guard let `self` = self else { return }
                switch changes {
                case .update(let objects, _, _, _):
                    self.update(collections: CollectionTreeBuilder.collections(from: objects))
                case .initial: break
                case .error: break
                }
            })

            let searchToken = searches.observe({ [weak self] changes in
                guard let `self` = self else { return }
                switch changes {
                case .update(let objects, _, _, _):
                    self.update(collections: CollectionTreeBuilder.collections(from: objects))
                case .initial: break
                case .error: break
                }
            })

            self.state.collectionToken = collectionToken
            self.state.searchToken = searchToken
        } catch let error {
            DDLogError("CollectionsStore: can't load collections: \(error)")
            self.state = State(library: library,
                               selectedCollection: Collection(custom: .all),
                               collections: [],
                               error: .dataLoading)
        }
    }
    
//    private func editCollection(at index: Int) {
//        let data = self.state.value.collectionCellData[index]
//        do {
//            let request = ReadCollectionDbRequest(libraryId: self.state.value.libraryId, key: data.key)
//            let collection = try self.dbStorage.createCoordinator().perform(request: request)
//            self.updater.updateState { state in
//                state.collectionToEdit = collection
//                state.changes.insert(.editing)
//            }
//        } catch let error {
//            DDLogError("CollectionsStore: can't load collection - \(error)")
//            self.updater.updateState { state in
//                state.error = .collectionNotFound
//            }
//        }
//    }
//

    func didAppear() {
        NotificationCenter.default.post(name: .splitViewDetailChanged,
                                        object: (self.state.selectedCollection, self.state.library))
    }

    func deleteCollection(with key: String) {
        let libraryId = self.state.library.identifier
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.delete(object: RCollection.self, keys: [key], libraryId: libraryId)
        }
    }

    func deleteSearch(with key: String) {
        let libraryId = self.state.library.identifier
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.delete(object: RSearch.self, keys: [key], libraryId: libraryId)
        }
    }

    private func delete<Obj: DeletableObject>(object: Obj.Type, keys: [String], libraryId: LibraryIdentifier) {
        do {
            let request = MarkObjectsAsDeletedDbRequest<Obj>(keys: keys, libraryId: libraryId)
            try self.dbStorage.createCoordinator().perform(request: request)
        } catch let error {
            DDLogError("CollectionsStore: can't delete object - \(error)")
            DispatchQueue.main.async { [weak self] in
                self?.state.error = .deletion
            }
        }
    }

    /// Updates existing collections of the same type. If no collection of given type exists yet, collections are inserted
    /// into appropriate position based on CollectionType.
    /// - parameter collections: collections to be inserted/updated
    private func update(collections: [Collection]) {
        guard !collections.isEmpty, let type = collections.first?.type else { return }

        if self.replaceCollections(of: type, with: collections) { return }

        switch type {
        case .collection:
            // Insert new "collection" collections after "all" collection
            self.state.collections.insert(contentsOf: collections, at: 1)
        case .search:
            // Insert new "search" collections before "publications" collection, after "collection" collections
            self.state.collections.insert(contentsOf: collections, at: self.state.collections.count - 2)
        case .custom: return // don't update custom collections
        }
    }

    /// Replaces existing collections of the same type with new collections
    /// - parameter type: type of collections
    /// - parameter collections: new collections to replace existing ones
    /// - returns: False if there are no collections to replace, true otherwise
    private func replaceCollections(of type: Collection.CollectionType, with collections: [Collection]) -> Bool {
        var startIndex = -1
        var endIndex = -1

        for data in self.state.collections.enumerated() {
            if startIndex == -1 {
                if data.element.type == type {
                    startIndex = data.offset
                }
            } else if endIndex == -1 {
                if data.element.type != type {
                    endIndex = data.offset
                }
            }
        }

        if startIndex == -1 { return false } // no object of given type found

        if endIndex == -1 { // last cell was of the same type, so endIndex is at the end
            endIndex = self.state.collections.count
        }

        // Replace old collections of this type with new collections
        self.state.collections.remove(atOffsets: IndexSet(integersIn: startIndex..<endIndex))
        self.state.collections.insert(contentsOf: collections, at: startIndex)

        return true
    }
}
