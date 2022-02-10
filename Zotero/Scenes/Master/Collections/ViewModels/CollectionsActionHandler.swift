//
//  CollectionsActionHandler.swift
//  Zotero
//
//  Created by Michal Rentka on 24/02/2020.
//  Copyright © 2020 Corporation for Digital Scholarship. All rights reserved.
//

import Foundation

import CocoaLumberjackSwift
import RealmSwift

struct CollectionsActionHandler: ViewModelActionHandler {
    typealias Action = CollectionsAction
    typealias State = CollectionsState

    private let queue: DispatchQueue
    private let dbStorage: DbStorage

    init(dbStorage: DbStorage) {
        self.queue = DispatchQueue.global(qos: .userInitiated)
        self.dbStorage = dbStorage
    }

    func process(action: CollectionsAction, in viewModel: ViewModel<CollectionsActionHandler>) {
        switch action {
        case .startEditing(let type):
            self.startEditing(type: type, in: viewModel)

        case .assignKeysToCollection(let fromKeys, let toKey):
            self.assignItems(keys: fromKeys, to: toKey, in: viewModel)

        case .deleteCollection(let key):
            self.delete(object: RCollection.self, keys: [key], in: viewModel)

        case .deleteSearch(let key):
            self.delete(object: RSearch.self, keys: [key], in: viewModel)

        case .select(let collectionId):
            self.update(viewModel: viewModel) { state in
                state.selectedCollectionId = collectionId
                state.changes.insert(.selection)
            }

        case .loadData:
            self.loadData(in: viewModel)

        case .toggleCollapsed(let collection):
            self.toggleCollapsed(for: collection, in: viewModel)

        case .emptyTrash:
            self.emptyTrash(in: viewModel)

        case .expandAll(let selectedCollectionIsRoot):
            self.set(allCollapsed: false, selectedCollectionIsRoot: selectedCollectionIsRoot, in: viewModel)

        case .collapseAll(let selectedCollectionIsRoot):
            self.set(allCollapsed: true, selectedCollectionIsRoot: selectedCollectionIsRoot, in: viewModel)

        case .loadItemKeysForBibliography(let collection):
            self.loadItemKeysForBibliography(collection: collection, in: viewModel)
        }
    }

    private func emptyTrash(in viewModel: ViewModel<CollectionsActionHandler>) {
        let libraryId = viewModel.state.libraryId

        self.queue.async {
            do {
                try self.dbStorage.createCoordinator().perform(request: EmptyTrashDbRequest(libraryId: libraryId))
            } catch let error {
                DDLogError("CollectionsActionHandler: can't empty trash - \(error)")
            }
        }
    }

    private func loadItemKeysForBibliography(collection: Collection, in viewModel: ViewModel<CollectionsActionHandler>) {
        guard let key = collection.identifier.key else { return }

        do {
            let items = try self.dbStorage.createCoordinator().perform(request: ReadItemsDbRequest(type: .collection(key, collection.name), libraryId: viewModel.state.libraryId))
            let keys = Set(items.map({ $0.key }))
            self.update(viewModel: viewModel) { state in
                state.itemKeysForBibliography = .success(keys)
            }
        } catch let error {
            DDLogError("CollectionsActionHandler: can't load bibliography items - \(error)")
            self.update(viewModel: viewModel) { state in
                state.itemKeysForBibliography = .failure(error)
            }
        }
    }

    private func set(allCollapsed: Bool, selectedCollectionIsRoot: Bool, in viewModel: ViewModel<CollectionsActionHandler>) {
        var changedCollections: Set<CollectionIdentifier> = []

        self.update(viewModel: viewModel) { state in
            changedCollections = state.collectionTree.setAll(collapsed: allCollapsed)
            state.changes = .collapsedState

            if allCollapsed && !state.collectionTree.isRoot(identifier: state.selectedCollectionId) {
                state.selectedCollectionId = .custom(.all)
                state.changes.insert(.selection)
            }
        }

        let libraryId = viewModel.state.libraryId

        self.queue.async {
            do {
                let request = SetCollectionsCollapsedDbRequest(identifiers: changedCollections, collapsed: allCollapsed, libraryId: libraryId)
                try self.dbStorage.createCoordinator().perform(request: request)
            } catch let error {
                DDLogError("CollectionsActionHandler: can't change collapsed all - \(error)")
            }
        }
    }

    private func toggleCollapsed(for collection: Collection, in viewModel: ViewModel<CollectionsActionHandler>) {
        guard let collapsed = viewModel.state.collectionTree.isCollapsed(identifier: collection.identifier) else { return }

        let newCollapsed = !collapsed
        let libraryId = viewModel.state.library.identifier

        // Update local state
        self.update(viewModel: viewModel) { state in
            state.collectionTree.set(collapsed: newCollapsed, to: collection.identifier)
            state.changes = .collapsedState

            // If a collection is being collapsed and selected collection is a child of collapsed collection, select currently collapsed collection
            if state.selectedCollectionId != collection.identifier && newCollapsed && !state.collectionTree.isRoot(identifier: state.selectedCollectionId) &&
               state.collectionTree.identifier(state.selectedCollectionId, isChildOf: collection.identifier) {
                state.selectedCollectionId = collection.identifier
                state.changes.insert(.selection)
            }
        }

        // Store change to database
        self.queue.async {
            do {
                let request = SetCollectionCollapsedDbRequest(collapsed: !collapsed, identifier: collection.identifier, libraryId: libraryId)
                try self.dbStorage.createCoordinator().perform(request: request)
            } catch let error {
                DDLogError("CollectionsActionHandler: can't change collapsed - \(error)")
            }
        }
    }

    private func child(of collectionId: CollectionIdentifier, containsSelectedId selectedId: CollectionIdentifier, in childCollections: [CollectionIdentifier: [CollectionIdentifier]]) -> Bool {
        guard let children = childCollections[collectionId] else { return false }

        if children.contains(selectedId) {
            return true
        }

        for childId in children {
            if self.child(of: childId, containsSelectedId: selectedId, in: childCollections) {
                return true
            }
        }

        return false
    }

    private func loadData(in viewModel: ViewModel<CollectionsActionHandler>) {
        let libraryId = viewModel.state.libraryId

        do {
            let coordinator = try self.dbStorage.createCoordinator()
            let library = try coordinator.perform(request: ReadLibraryDbRequest(libraryId: libraryId))
            let collections = try coordinator.perform(request: ReadCollectionsDbRequest(libraryId: libraryId))
//            let searches = try coordinator.perform(request: ReadSearchesDbRequest(libraryId: libraryId))
            let allItems = try coordinator.perform(request: ReadItemsDbRequest(type: .all, libraryId: libraryId))
//            let publicationItemsCount = try coordinator.perform(request: ReadItemsDbRequest(type: .publications, libraryId: libraryId)).count
            let trashItems = try coordinator.perform(request: ReadItemsDbRequest(type: .trash, libraryId: libraryId))

            let collectionTree = CollectionTreeBuilder.collections(from: collections, libraryId: libraryId)
            collectionTree.insert(collection: Collection(custom: .all, itemCount: allItems.count), at: 0)
            collectionTree.append(collection: Collection(custom: .trash, itemCount: trashItems.count))

            let collectionsToken = collections.observe(keyPaths: RCollection.observableKeypathsForList, { [weak viewModel] changes in
                guard let viewModel = viewModel else { return }

                switch changes {
                case .update(let objects, _, _, _): self.update(collections: objects, viewModel: viewModel)
                case .initial: break
                case .error: break
                }
            })

//            let searchesToken = searches.observe({ [weak viewModel] changes in
//                guard let viewModel = viewModel else { return }
//                switch changes {
//                case .update(let objects, _, _, _):
//                    let collections = CollectionTreeBuilder.collections(from: objects)
//                    self.update(collections: collections, in: viewModel)
//                case .initial: break
//                case .error: break
//                }
//            })

            let itemsToken = allItems.observe({ [weak viewModel] changes in
                guard let viewModel = viewModel else { return }
                switch changes {
                case .update(let objects, _, _, _):
                    self.update(allItemsCount: objects.count, in: viewModel)
                case .initial: break
                case .error: break
                }
            })

            let trashToken = trashItems.observe({ [weak viewModel] changes in
                guard let viewModel = viewModel else { return }
                switch changes {
                case .update(let objects, _, _, _):
                    self.update(trashItemCount: objects.count, in: viewModel)
                case .initial: break
                case .error: break
                }
            })

            self.update(viewModel: viewModel) { state in
                state.collectionTree = collectionTree
                state.library = library
                state.collectionsToken = collectionsToken
//                state.searchesToken = searchesToken
                state.itemsToken = itemsToken
                state.trashToken = trashToken
            }
        } catch let error {
            DDLogError("CollectionsActionHandlers: can't load data - \(error)")
            self.update(viewModel: viewModel) { state in
                state.error = .dataLoading
            }
        }
    }

    private func assignItems(keys: [String], to collectionKey: String, in viewModel: ViewModel<CollectionsActionHandler>) {
        let libraryId = viewModel.state.library.identifier

        self.queue.async { [weak viewModel] in
            do {
                let request = AssignItemsToCollectionsDbRequest(collectionKeys: Set([collectionKey]), itemKeys: Set(keys), libraryId: libraryId)
                try self.dbStorage.createCoordinator().perform(request: request)
            } catch let error {
                DDLogError("CollectionsStore: can't assign collections to items - \(error)")

                guard let viewModel = viewModel else { return }

                inMainThread {
                    self.update(viewModel: viewModel) { state in
                        state.error = .collectionAssignment
                    }
                }
            }
        }
    }

    private func delete<Obj: DeletableObject&Updatable>(object: Obj.Type, keys: [String], in viewModel: ViewModel<CollectionsActionHandler>) {
        let libraryId = viewModel.state.library.identifier

        self.queue.async { [weak viewModel] in
            do {
                let request = MarkObjectsAsDeletedDbRequest<Obj>(keys: keys, libraryId: libraryId)
                try self.dbStorage.createCoordinator().perform(request: request)
            } catch let error {
                DDLogError("CollectionsStore: can't delete object - \(error)")

                guard let viewModel = viewModel else { return }

                inMainThread {
                    self.update(viewModel: viewModel) { state in
                        state.error = .deletion
                    }
                }
            }
        }
    }

    /// Loads data needed to show editing controller.
    /// - parameter type: Editing type.
    private func startEditing(type: CollectionsState.EditingType, in viewModel: ViewModel<CollectionsActionHandler>) {
        let key: String?
        let name: String
        var parent: Collection?

        switch type {
        case .add:
            key = nil
            name = ""
            parent = nil
        case .addSubcollection(let collection):
            key = nil
            name = ""
            parent = collection
        case .edit(let collection):
            key = collection.identifier.key
            name = collection.name

            if let parentKey = viewModel.state.collectionTree.parent(of: collection.identifier)?.key, let coordinator = try? self.dbStorage.createCoordinator() {
                let request = ReadCollectionDbRequest(libraryId: viewModel.state.library.identifier, key: parentKey)
                let rCollection = try? coordinator.perform(request: request)
                parent = rCollection.flatMap { Collection(object: $0, itemCount: 0) }
            }
        }

        self.update(viewModel: viewModel) { state in
            state.editingData = (key, name, parent)
        }
    }

    private func update(allItemsCount: Int, in viewModel: ViewModel<CollectionsActionHandler>) {
        self.update(viewModel: viewModel) { state in
            state.collectionTree.update(collection: Collection(custom: .all, itemCount: allItemsCount))
            state.changes = .allItemCount
        }
    }

    private func update(trashItemCount: Int, in viewModel: ViewModel<CollectionsActionHandler>) {
        self.update(viewModel: viewModel) { state in
            state.collectionTree.update(collection: Collection(custom: .trash, itemCount: trashItemCount))
            state.changes = .trashItemCount
        }
    }

    private func update(collections: Results<RCollection>, viewModel: ViewModel<CollectionsActionHandler>) {
        let tree = CollectionTreeBuilder.collections(from: collections, libraryId: viewModel.state.libraryId)

        self.update(viewModel: viewModel) { state in
            state.collectionTree.replace(identifiersMatching: { $0.isCollection }, with: tree)
            state.changes = .results

            // Check whether selection still exists
            if state.collectionTree.collection(for: state.selectedCollectionId) == nil {
                state.selectedCollectionId = .custom(.all)
                state.changes.insert(.selection)
            }
        }
    }
}
