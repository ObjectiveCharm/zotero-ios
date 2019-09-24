//
//  ItemsStore.swift
//  Zotero
//
//  Created by Michal Rentka on 11/02/2019.
//  Copyright © 2019 Corporation for Digital Scholarship. All rights reserved.
//

import Combine
import Foundation

import CocoaLumberjack
import RealmSwift
import RxSwift

class ItemsStore: ObservableObject {
    enum Error: Swift.Error, Equatable {
        case dataLoading, deletion
    }

    struct State {
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

            var isTrash: Bool {
                switch self {
                case .trash:
                    return true
                default:
                    return false
                }
            }
        }

        let type: ItemType
        let library: Library

        fileprivate(set) var sections: [String]?
        fileprivate var results: Results<RItem>?
        fileprivate(set) var error: Error?
        fileprivate var itemsToken: NotificationToken?

        func items(for section: String) -> Results<RItem>? {
            if section == "-" {
                return self.results?.filter("title == ''")
            } else {
                return self.results?.filter("title BEGINSWITH[c] %@", section)
            }
        }
    }

    private(set) var state: State {
        willSet {
            self.objectWillChange.send()
        }
    }
    // SWIFTUI BUG: should be defined by default, but bugged in current version
    let objectWillChange: ObservableObjectPublisher
    let dbStorage: DbStorage

    init(type: State.ItemType, library: Library, dbStorage: DbStorage) {
        self.objectWillChange = ObservableObjectPublisher()
        self.dbStorage = dbStorage

        do {
            let items = try dbStorage.createCoordinator().perform(request: ItemsStore.request(for: type, libraryId: library.identifier))

            self.state = State(type: type,
                               library: library,
                               sections: ItemsStore.sections(from: items),
                               results: items)

            let token = items.observe { [weak self] changes in
                switch changes {
                case .error: break
                case .initial: break
                case .update(let results, _, _, _):
                    self?.state.results = results
                    self?.state.sections = ItemsStore.sections(from: results)
                }
            }
            self.state.itemsToken = token
        } catch let error {
            DDLogError("ItemStore: can't load items - \(error)")
            self.state = State(type: type,
                               library: library,
                               error: .dataLoading)
        }
    }

    private class func request(for type: State.ItemType, libraryId: LibraryIdentifier) -> ReadItemsDbRequest {
        let request: ReadItemsDbRequest
        switch type {
        case .all:
            request = ReadItemsDbRequest(libraryId: libraryId,
                                         collectionKey: nil, parentKey: "", trash: false)
        case .trash:
            request = ReadItemsDbRequest(libraryId: libraryId,
                                         collectionKey: nil, parentKey: nil, trash: true)
        case .publications, .search:
            // TODO: - implement publications and search fetching
            request = ReadItemsDbRequest(libraryId: .group(-1),
                                         collectionKey: nil, parentKey: nil, trash: true)
        case .collection(let key, _):
            request = ReadItemsDbRequest(libraryId: libraryId,
                                         collectionKey: key, parentKey: "", trash: false)
        }
        return request
    }

    private class func sections(from results: Results<RItem>) -> [String] {
        return Set(results.map({ $0.title.first.flatMap(String.init)?.uppercased() ?? "-" })).sorted()
    }
}
