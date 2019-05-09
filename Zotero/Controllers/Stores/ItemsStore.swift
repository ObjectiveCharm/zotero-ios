//
//  ItemsStore.swift
//  Zotero
//
//  Created by Michal Rentka on 11/02/2019.
//  Copyright © 2019 Corporation for Digital Scholarship. All rights reserved.
//

import Foundation

import CocoaLumberjack
import RealmSwift
import RxSwift

protocol ItemsDataSource {
    var sectionCount: Int { get }
    var sectionIndexTitles: [String] { get }
    func items(for section: Int) -> Results<RItem>?
}

class ItemsStore: Store {
    typealias Action = StoreAction
    typealias State = StoreState

    enum StoreAction {
        case load
        case delete(IndexPath)
    }

    enum StoreError: Error, Equatable {
        case dataLoading, deletion
    }

    struct StoreState {
        enum ItemType {
            case all, trash, publications
            case collection(String, String) // Key, Title
            case search(String, String) // Key, Title

            var collectionKey: String? {
                switch self {
                case .collection(let key, _):
                    return key
                default:
                    return nil
                }
            }
        }

        let libraryId: LibraryIdentifier
        let type: ItemType
        let title: String

        fileprivate(set) var dataSource: ItemsDataSource?
        fileprivate(set) var error: StoreError?
        fileprivate var version: Int
        fileprivate var itemsToken: NotificationToken?

        init(libraryId: LibraryIdentifier, type: ItemType) {
            self.libraryId = libraryId
            self.type = type
            switch type {
            case .collection(_, let title), .search(_, let title):
                self.title = title
            case .all:
                self.title = "All Items"
            case .trash:
                self.title = "Trash"
            case .publications:
                self.title = "My Publications"
            }
            self.version = 0
        }
    }

    let apiClient: ApiClient
    let fileStorage: FileStorage
    let dbStorage: DbStorage
    let schemaController: SchemaController

    var updater: StoreStateUpdater<StoreState>

    init(initialState: StoreState, apiClient: ApiClient, fileStorage: FileStorage,
         dbStorage: DbStorage, schemaController: SchemaController) {
        self.apiClient = apiClient
        self.fileStorage = fileStorage
        self.dbStorage = dbStorage
        self.schemaController = schemaController
        self.updater = StoreStateUpdater(initialState: initialState)
    }

    func handle(action: StoreAction) {
        switch action {
        case .load:
            self.loadData()
        case .delete(let indexPath):
            self.delete(at: indexPath)
        }
    }

    private func loadData() {
        do {
            let request: ReadItemsDbRequest
            switch self.state.value.type {
            case .all:
                request = ReadItemsDbRequest(libraryId: self.state.value.libraryId,
                                             collectionKey: nil, parentKey: nil, trash: false)
            case .trash:
                request = ReadItemsDbRequest(libraryId: self.state.value.libraryId,
                                             collectionKey: nil, parentKey: nil, trash: true)
            case .publications, .search:
                // TODO: - implement publications and search fetching
                request = ReadItemsDbRequest(libraryId: .group(-1),
                                             collectionKey: nil, parentKey: nil, trash: true)
            case .collection(let key, _):
                request = ReadItemsDbRequest(libraryId: self.state.value.libraryId,
                                             collectionKey: key, parentKey: nil, trash: false)
            }

            let items = try self.dbStorage.createCoordinator().perform(request: request)
            let dataSource = ItemResultsDataSource(results: items)

            let itemsToken = items.observe({ [weak self] changes in
                guard let `self` = self else { return }
                switch changes {
                case .update(let results, _, _, _):
                    let dataSource = ItemResultsDataSource(results: results)
                    self.updater.updateState(action: { newState in
                        newState.dataSource = dataSource
                        newState.version += 1
                    })
                case .initial: break
                case .error(let error):
                    DDLogError("ItemsStore: couldn't update data - \(error)")
                    self.updater.updateState { newState in
                        newState.error = .dataLoading
                    }
                }
            })

            self.updater.updateState { newState in
                newState.dataSource = dataSource
                newState.version += 1
                newState.itemsToken = itemsToken
            }
        } catch let error {
            DDLogError("ItemsStore: couldn't load data - \(error)")
            self.updater.updateState { newState in
                newState.error = .dataLoading
            }
        }
    }

    private func delete(at indexPath: IndexPath) {
        guard let item = self.state.value.dataSource?.items(for: indexPath.section)?[indexPath.row] else {
            DDLogError("ItemsStore: can't find item")
            self.updater.updateState { newState in
                newState.error = .deletion
            }
            return
        }

        do {
            try self.dbStorage.createCoordinator().perform(request: MarkObjectAsDeletedDbRequest(object: item))
        } catch let error {
            DDLogError("ItemsStore: can't delete object - \(error)")
            self.updater.updateState { newState in
                newState.error = .deletion
            }
        }
    }
}

extension ItemsStore.StoreState: Equatable {
    static func == (lhs: ItemsStore.StoreState, rhs: ItemsStore.StoreState) -> Bool {
        return lhs.error == rhs.error && lhs.version == rhs.version
    }
}

class ItemResultsDataSource {
    let sectionIndexTitles: [String]
    private let results: Results<RItem>
    private var sectionResults: [Int: Results<RItem>]

    init(results: Results<RItem>) {
        self.results = results
        self.sectionResults = [:]
        self.sectionIndexTitles = Set(results.map({ $0.title.first.flatMap(String.init)?.uppercased() ?? "-" })).sorted()
    }
}

extension ItemResultsDataSource: ItemsDataSource {
    var sectionCount: Int {
        return self.sectionIndexTitles.count
    }

    func items(for section: Int) -> Results<RItem>? {
        guard section < self.sectionCount else { return nil }

        if let results = self.sectionResults[section] {
            return results
        }

        let results: Results<RItem>
        let title = self.sectionIndexTitles[section]
        if title == "-" {
            results = self.results.filter("title == ''")
        } else {
            results = self.results.filter("title BEGINSWITH[c] %@", self.sectionIndexTitles[section])
        }
        self.sectionResults[section] = results
        return results
    }
}
