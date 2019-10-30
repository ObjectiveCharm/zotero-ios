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
        case dataLoading, deletion, collectionAssignment
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

        fileprivate(set) var results: Results<RItem>? {
            didSet {
                self.resultsDidChange?()
            }
        }
        var error: Error?
        var sortType: ItemsSortType {
            willSet {
                self.results = self.results?.sorted(by: newValue.descriptors)
            }
        }
        var selectedItems: Set<String> = []
        var showingCreation: Bool = false
        var resultsDidChange: (() -> Void)?
    }

    @Published var state: State
    private let dbStorage: DbStorage
    private let fileStorage: FileStorage

    init(type: State.ItemType, library: Library, dbStorage: DbStorage, fileStorage: FileStorage) {
        self.dbStorage = dbStorage
        self.fileStorage = fileStorage

        do {
            let sortType = ItemsSortType(field: .title, ascending: true)
            let items = try dbStorage.createCoordinator()
                                     .perform(request: ItemsStore.request(for: type, libraryId: library.identifier))
                                     .sorted(by: sortType.descriptors)

            self.state = State(type: type,
                               library: library,
                               results: items,
                               sortType: sortType)
        } catch let error {
            DDLogError("ItemStore: can't load items - \(error)")
            self.state = State(type: type,
                               library: library,
                               error: .dataLoading,
                               sortType: ItemsSortType(field: .title, ascending: true))
        }
    }

    func addAttachments(from urls: [URL]) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let `self` = self else { return }

            let attachments = urls.map({ Files.file(from: $0) })
                                  .map({
                                    ItemDetailStore.State.Attachment(key: KeyGenerator.newKey,
                                                                     title: $0.name,
                                                                     type: .file(file: $0, filename: $0.name, isLocal: true),
                                                                     libraryId: self.state.library.identifier)
                                  })

            do {
                try self.fileStorage.copyAttachmentFilesIfNeeded(for: attachments)

                for attachment in attachments {
                    let request = CreateAttachmentDbRequest(attachment: attachment, libraryId: self.state.library.identifier)
                    _ = try self.dbStorage.createCoordinator().perform(request: request)
                }
            } catch let error {
                // TODO: - Show error
            }
        }
    }

    func saveNewNote(with text: String) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let `self` = self else { return }
            do {
                let note = ItemDetailStore.State.Note(key: KeyGenerator.newKey, text: text)
                let request = CreateNoteDbRequest(note: note, libraryId: self.state.library.identifier)
                _ = try self.dbStorage.createCoordinator().perform(request: request)
            } catch let error {
                // TODO: - Show error
            }
        }
    }

    func saveChanges(for note: ItemDetailStore.State.Note) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let `self` = self else { return }
            do {
                let request = StoreNoteDbRequest(note: note, libraryId: self.state.library.identifier)
                try self.dbStorage.createCoordinator().perform(request: request)
            } catch let error {
                // TODO: - show error
            }
        }
    }

    @objc func removeSelectedItemsFromCollection() {
        guard let collectionKey = self.state.type.collectionKey else { return }
        do {
            let request = DeleteItemsFromCollectionDbRequest(collectionKey: collectionKey,
                                                            itemKeys: self.state.selectedItems,
                                                            libraryId: self.state.library.identifier)
            try self.dbStorage.createCoordinator().perform(request: request)
        } catch let error {
            DDLogError("ItemsStore: can't delete items from collection - \(error)")
            self.state.error = .collectionAssignment
        }
    }

    func assignSelectedItems(to collectionKeys: Set<String>) {
        do {
            let request = AssignItemsToCollectionsDbRequest(collectionKeys: collectionKeys,
                                                            itemKeys: self.state.selectedItems,
                                                            libraryId: self.state.library.identifier)
            try self.dbStorage.createCoordinator().perform(request: request)
        } catch let error {
            DDLogError("ItemsStore: can't assign collections to items - \(error)")
            self.state.error = .collectionAssignment
        }
    }

    @objc func trashSelectedItems() {
        self.setTrashedToSelectedItems(trashed: true)
    }

    @objc func restoreSelectedItems() {
        self.setTrashedToSelectedItems(trashed: false)
    }

    @objc func deleteSelectedItems() {
        do {
            let request = DeleteObjectsDbRequest<RItem>(keys: Array(self.state.selectedItems),
                                                        libraryId: self.state.library.identifier)
            try self.dbStorage.createCoordinator().perform(request: request)
        } catch let error {
            DDLogError("ItemsStore: can't delete items - \(error)")
            self.state.error = .deletion
        }
    }

    private func setTrashedToSelectedItems(trashed: Bool) {
        do {
            let request = MarkItemsAsTrashedDbRequest(keys: Array(self.state.selectedItems),
                                                      libraryId: self.state.library.identifier,
                                                      trashed: trashed)
            try self.dbStorage.createCoordinator().perform(request: request)
        } catch let error {
            DDLogError("ItemsStore: can't trash items - \(error)")
            self.state.error = .deletion
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
}
