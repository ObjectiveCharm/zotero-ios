//
//  AttachmentFileCleanupController.swift
//  Zotero
//
//  Created by Michal Rentka on 12/06/2020.
//  Copyright © 2020 Corporation for Digital Scholarship. All rights reserved.
//

import Foundation

import CocoaLumberjackSwift
import RxSwift

/// This controller listens to notification center for .attachmentDeleted notification and removes attachment files if needed.
final class AttachmentFileCleanupController {
    enum DeletionType {
        case individual(attachment: Attachment, parentKey: String?)
        case allForItems(Set<String>, LibraryIdentifier)
        case library(LibraryIdentifier)
        case all

        var notification: AttachmentFileDeletedNotification {
            switch self {
            case .all: return .all
            case .library(let id): return .library(id)
            case .allForItems(let keys, let libraryId): return .allForItems(keys: keys, libraryId: libraryId)
            case .individual(let attachment, let parentKey): return .individual(key: attachment.key, parentKey: parentKey, libraryId: attachment.libraryId)
            }
        }
    }

    private unowned let fileStorage: FileStorage
    private unowned let dbStorage: DbStorage
    private let queue: DispatchQueue
    private let scheduler: SerialDispatchQueueScheduler
    private let disposeBag: DisposeBag

    init(fileStorage: FileStorage, dbStorage: DbStorage) {
        let queue = DispatchQueue(label: "org.zotero.FileCleanupQueue", qos: .userInitiated)
        self.fileStorage = fileStorage
        self.dbStorage = dbStorage
        self.scheduler = SerialDispatchQueueScheduler(queue: queue, internalSerialQueueName: "org.zotero.FileCleanupScheduler")
        self.queue = queue
        self.disposeBag = DisposeBag()

        NotificationCenter.default.rx
                                  .notification(.attachmentDeleted)
                                  .observe(on: self.scheduler)
                                  .subscribe(onNext: { [weak self] notification in
                                      if let file = notification.object as? File {
                                          self?.delete(file: file)
                                      }
                                  })
                                  .disposed(by: self.disposeBag)
    }

    private func delete(file: File) {
        // Don't need to check for errors, the attachment doesn't have to have the file downloaded locally, so this will throw for all attachments
        // without local files. If the file was not removed properly it can always be seen and done in settings.
        try? self.fileStorage.remove(file)
    }

    func delete(_ type: DeletionType, completed: ((Bool) -> Void)?) {
        self.queue.async {
            let deleted = self.delete(type)

            guard deleted || completed != nil else { return }
            
            DispatchQueue.main.async {
                if deleted {
                    NotificationCenter.default.post(name: .attachmentFileDeleted, object: type.notification)
                }
                completed?(deleted)
            }
        }
    }

    private func delete(_ type: DeletionType) -> Bool {
        switch type {
        case .all:
            return self.deleteAll()

        case .allForItems(let keys, let libraryId):
            return self.deleteAttachments(for: keys, libraryId: libraryId)

        case .library(let libraryId):
            return self.delete(in: libraryId)

        case .individual(let attachment, _):
            return self.delete(attachment: attachment)
        }
    }

    private func deleteAll() -> Bool {
        do {
            let coordinator = try self.dbStorage.createCoordinator()
            let groups = try coordinator.perform(request: ReadAllGroupsDbRequest())
            let libraryIds: [LibraryIdentifier] = [.custom(.myLibrary)] + groups.map({ .group($0.identifier) })
            var forUpload: [LibraryIdentifier: [String]] = [:]
            for item in try coordinator.perform(request: ReadAllItemsForUploadDbRequest()) {
                guard let libraryId = item.libraryId else { continue }

                if var keys = forUpload[libraryId] {
                    keys.append(item.key)
                    forUpload[libraryId] = keys
                } else {
                    forUpload[libraryId] = [item.key]
                }
            }

            self.delete(downloadsIn: libraryIds, forUpload: forUpload)
            // Annotations are not guaranteed to exist and they can be removed even if the parent PDF was not deleted due to upload state.
            // These are generated on device, so they'll just be recreated.
            try? self.fileStorage.remove(Files.annotationPreviews)
            // When removing all local files clear cache as well.
            try? self.fileStorage.remove(Files.cache)

            // TODO: - exclude those for upload
            try? self.dbStorage.createCoordinator().perform(request: MarkAllFilesAsNotDownloadedDbRequest())

            return true
        } catch let error {
            DDLogError("AttachmentFileCleanupController: can't remove download directory - \(error)")
            return false
        }
    }

    private func delete(in libraryId: LibraryIdentifier) -> Bool {
        do {
            let coordinator = try self.dbStorage.createCoordinator()
            let forUpload = try coordinator.perform(request: ReadItemsForUploadDbRequest(libraryId: libraryId)).map({ $0.key })

            self.delete(downloadsIn: [libraryId], forUpload: [libraryId: Array(forUpload)])
            // Annotations are not guaranteed to exist and they can be removed even if the parent PDF was not deleted due to upload state.
            // These are generated on device, so they'll just be recreated.
            try? self.fileStorage.remove(Files.annotationPreviews(for: libraryId))

            // TODO: - exclude those for upload
            try? self.dbStorage.createCoordinator().perform(request: MarkLibraryFilesAsNotDownloadedDbRequest(libraryId: libraryId))

            return true
        } catch let error {
            DDLogError("AttachmentFileCleanupController: can't remove library downloads - \(error)")
            return false
        }
    }

    private func delete(downloadsIn libraries: [LibraryIdentifier], forUpload: [LibraryIdentifier: [String]]) {
        for libraryId in libraries {
            guard let keysForUpload = forUpload[libraryId], !keysForUpload.isEmpty else {
                // No items are queued for upload, just delete the whole directory. Ignore thrown error because some may not exist locally (user didn't download anything in given library yet).
                try? self.fileStorage.remove(Files.downloads(for: libraryId))
                continue
            }

            // If there are pending uploads, delete only directories with uploaded files. If no folders are stored locally just skip.
            guard let contents: [File] = try? self.fileStorage.contentsOfDirectory(at: Files.downloads(for: libraryId)) else { continue }

            let toDelete = contents.filter({ file in
                // Check whether it's item folder and whether upload is pending for given item.
                if file.relativeComponents.count == 3, let key = file.relativeComponents.last, key.count == KeyGenerator.length {
                    return !keysForUpload.contains(key)
                }
                // If it's something else, just delete it
                return true
            })

            for file in toDelete {
                do {
                    try self.fileStorage.remove(file)
                } catch let error {
                    DDLogError("AttachmentFileCleanupController: could not remove file \(file) - \(error)")
                }
            }
        }
    }

    private func delete(attachment: Attachment) -> Bool {
        do {
            // Don't delete linked files
            guard case .file(_, _, _, let linkType) = attachment.type, linkType != .linkedFile else { return false }

            let coordinator = try self.dbStorage.createCoordinator()
            let item = try coordinator.perform(request: ReadItemDbRequest(libraryId: attachment.libraryId, key: attachment.key))

            // Don't delete attachments that need to sync
            guard !item.attachmentNeedsSync else { return false }

            try self.removeFiles(for: attachment.key, libraryId: attachment.libraryId)
            try? self.dbStorage.createCoordinator().perform(request: MarkFileAsDownloadedDbRequest(key: attachment.key, libraryId: attachment.libraryId, downloaded: false))

            return true
        } catch let error {
            DDLogError("AttachmentFileCleanupController: can't remove attachment file - \(error)")
            return false
        }
    }

    private func deleteAttachments(for keys: Set<String>, libraryId: LibraryIdentifier) -> Bool {
        guard !keys.isEmpty else { return false }

        do {
            let coordinator = try self.dbStorage.createCoordinator()
            let items = try coordinator.perform(request: ReadItemsWithKeysDbRequest(keys: keys, libraryId: libraryId))
            var deletedKeys: Set<String> = []

            for item in items {
                // Either the selected item was attachment
                if item.rawType == ItemTypes.attachment {
                    // Don't delete attachments that need to sync
                    guard !item.attachmentNeedsSync else { continue }
                    // Some selected files might not exist, just continue deleting
                    do {
                        try self.removeFiles(for: item.key, libraryId: libraryId)
                        deletedKeys.insert(item.key)
                    } catch {}

                    continue
                }

                // Or the item was a parent item and it may have multiple attachments
                for child in item.children.filter(.item(type: ItemTypes.attachment)) {
                    // Don't delete attachments that need to sync
                    guard !child.attachmentNeedsSync else { continue }
                    // Some children files might not exist, just continue deleting
                    do {
                        try self.removeFiles(for: child.key, libraryId: libraryId)
                        deletedKeys.insert(child.key)
                    } catch {}
                }
            }

            try? self.dbStorage.createCoordinator().perform(request: MarkItemsFilesAsNotDownloadedDbRequest(keys: deletedKeys, libraryId: libraryId))

            return true
        } catch let error {
            DDLogError("AttachmentFileCleanupController: can't remove attachments for item - \(error)")
            return false
        }
    }

    private func removeFiles(for key: String, libraryId: LibraryIdentifier) throws {
        try self.fileStorage.remove(Files.attachmentDirectory(in: libraryId, key: key))
        // Annotations are not guaranteed to exist.
        try? self.fileStorage.remove(Files.annotationPreviews(for: key, libraryId: libraryId))
    }
}
