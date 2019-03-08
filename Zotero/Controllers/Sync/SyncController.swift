//
//  SyncController.swift
//  Zotero
//
//  Created by Michal Rentka on 05/02/2019.
//  Copyright © 2019 Corporation for Digital Scholarship. All rights reserved.
//

import Foundation

import Alamofire
import CocoaLumberjack
import RealmSwift
import RxCocoa
import RxSwift

enum SyncError: Error {
    case cancelled
    // Abort (fatal) errors
    case noInternetConnection
    case apiError
    case dbError
    case versionMismatch
    case groupSyncFailed(Error)
    case allLibrariesFetchFailed(Error)
}

final class SyncController {
    private enum SyncType {
        case normal     // Fetches updates since last versions
        case initial    // Ignores local versions, fetches everything since the beginning
        case retry      // Is a retry after previous broken sync
    }

    enum LibrarySyncType {
        case all                // Syncs all libraries
        case specific([Int])    // Syncs only specific libraries
    }

    enum Library: Equatable {
        case user(Int)
        case group(Int)
    }

    enum Object: Equatable, CaseIterable {
        case group, collection, search, item, trash
    }

    struct Batch {
        static let maxCount = 50
        let library: Library
        let object: Object
        let keys: [Any]
        let version: Int
    }

    enum Action: Equatable {
        case syncVersions(Library, Object, Int?)     // Fetch versions from API, update DB based on response
        case createLibraryActions                    // Load all libraries, spawn actions for each
        case syncBatchToDb(Batch)                    // Fetch data and store to db
        case storeVersion(Int, Library, Object)      // Store new version for given library-object
        case syncDeletions(Library, Int)             // Synchronize deletions of objects in library
        case syncSettings(Library, Int?)             // Synchronize settings for library
        case storeSettingsVersion(Int, Library)      // Store new version for settings in library
    }

    private static let timeoutPeriod: Double = 15.0

    private let userId: Int
    private let accessQueue: DispatchQueue
    private let handler: SyncActionHandler
    private let progressHandler: SyncProgressHandler

    private var queue: [Action]
    private var processingAction: Action?
    private var type: SyncType
    private var libraryType: LibrarySyncType
    /// Version returned by last object sync, used to check for version mismatches between object syncs
    private var lastReturnedVersion: Int?
    /// Array of non-fatal errors that happened during current sync
    private var nonFatalErrors: [Error]
    /// Flag that marks failure(s) during current sync, we'll retry after timeout when current sync finishes
    private var needsResync: Bool
    private var disposeBag: DisposeBag

    private var isSyncing: Bool {
        return self.processingAction != nil || !self.queue.isEmpty || self.needsResync
    }

    var progressObservable: BehaviorRelay<SyncProgress?> {
        return self.progressHandler.observable
    }

    init(userId: Int, handler: SyncActionHandler) {
        self.userId = userId
        self.accessQueue = DispatchQueue(label: "org.zotero.SyncAccessQueue", qos: .utility, attributes: .concurrent)
        self.handler = handler
        self.progressHandler = SyncProgressHandler()
        self.disposeBag = DisposeBag()
        self.queue = []
        self.nonFatalErrors = []
        self.needsResync = false
        self.type = .normal
        self.libraryType = .all
    }

    // MARK: - Sync management

    func start(for libraries: LibrarySyncType, isInitial: Bool = false) {
        DDLogInfo("--- Sync: starting ---")
        self.start(type: (isInitial ? .initial : .normal), libraries: libraries)
    }

    func cancelSync() {
        DDLogInfo("--- Sync: cancelled ---")

        self.performOnAccessQueue(flags: .barrier) { [weak self] in
            guard let `self` = self, self.isSyncing else { return }
            self.disposeBag = DisposeBag()
            self.cleaup()
            self.report(fatalError: SyncError.cancelled)
        }
    }

    private func start(type: SyncType, libraries: LibrarySyncType) {
        self.performOnAccessQueue(flags: .barrier) { [weak self] in
            guard let `self` = self, !self.isSyncing else { return }
            self.type = type
            self.libraryType = libraries
            self.progressHandler.reportNewSync()
            self.queue.append(contentsOf: self.createInitialActions(for: libraries))
            self.processNextAction()
        }
    }

    private func createInitialActions(for libraries: LibrarySyncType) -> [SyncController.Action] {
        switch libraries {
        case .all:
            return [.syncVersions(.user(self.userId), .group, nil)]
        case .specific(let identifiers):
            let isMyLibraryOnly = identifiers.count == 1 && identifiers.first == RLibrary.myLibraryId
            if isMyLibraryOnly {
                return [.createLibraryActions]
            }
            return [.syncVersions(.user(self.userId), .group, nil)]
        }
    }

    private func finish() {
        self.performOnAccessQueue(flags: .barrier) { [weak self] in
            guard let `self` = self else { return }

            let errors = self.nonFatalErrors

            DDLogInfo("--- Sync: finished ---")
            if !errors.isEmpty {
                DDLogInfo("Errors: \(errors)")
            }

            self.reportFinish?(.success((self.allActions, errors)))
            self.reportFinish = nil

            self.reportFinish(nonFatalErrors: errors)
            self.enqueueResyncIfNeeded()
            self.cleaup()
        }
    }

    private func abort(error: Error) {
        DDLogInfo("--- Sync: aborted ---")
        DDLogInfo("Error: \(error)")

        self.reportFinish?(.failure(error))
        self.reportFinish = nil

        self.performOnAccessQueue(flags: .barrier) { [weak self] in
            guard let `self` = self else { return }
            self.report(fatalError: error)
            self.cleaup()
            self.needsResync = true
            self.enqueueResync()
        }
    }

    private func enqueueResyncIfNeeded() {
        guard self.needsResync else { return }
        self.enqueueResync()
    }

    private func enqueueResync() {
        Single<Int>.timer(SyncController.timeoutPeriod, scheduler: MainScheduler.instance)
                   .subscribe(onSuccess: { [weak self] _ in
                       guard let `self` = self else { return }
                       self.start(type: .retry, libraries: self.libraryType)
                   })
                   .disposed(by: self.disposeBag)
    }

    private func setNeedsResync() {
        // Don't retry more than once
        guard self.type != .retry else { return }
        self.needsResync = true
    }

    private func cleaup() {
        self.processingAction = nil
        self.queue = []
        self.nonFatalErrors = []
        self.needsResync = false
        self.type = .normal
        self.lastReturnedVersion = nil
    }

    // MARK: - Error handling

    private func report(fatalError: Error) {
        self.progressHandler.reportAbort(with: fatalError)
    }

    private func reportFinish(nonFatalErrors errors: [Error]) {
        self.progressHandler.reportFinish(with: errors)
    }

    // MARK: - Queue management

    private func enqueue(actions: [Action], at index: Int? = nil) {
        if let index = index {
            self.queue.insert(contentsOf: actions, at: index)
        } else {
            self.queue.append(contentsOf: actions)
        }
        self.processNextAction()
    }

    private func removeAllActions(for library: Library) {
        while !self.queue.isEmpty {
            guard self.queue[0].library == library else { break }
            self.queue.removeFirst()
        }
    }

    private func processNextAction() {
        guard !self.queue.isEmpty else {
            self.processingAction = nil
            self.finish()
            return
        }

        let action = self.queue.removeFirst()

        if self.reportFinish != nil {
            self.allActions.append(action)
        }

        // Library is changing, reset "lastReturnedVersion"
        if self.lastReturnedVersion != nil && action.library != self.processingAction?.library {
            self.lastReturnedVersion = nil
        }

        self.processingAction = action
        self.process(action: action)
    }

    // MARK: - Action processing

    private func process(action: Action) {
        DDLogInfo("--- Sync: action ---")
        DDLogInfo("\(action)")
        switch action {
        case .createLibraryActions:
            self.processCreateLibraryActions()
        case .syncVersions(let library, let objectType, let version):
            if objectType == .group {
                self.progressHandler.reportGroupSync()
            } else {
                self.progressHandler.reportVersionsSync(for: library, object: objectType)
            }
            self.processSyncVersions(library: library, object: objectType, since: version)
        case .syncBatchToDb(let batch):
            self.processBatchSync(for: batch)
        case .storeVersion(let version, let library, let object):
            self.processStoreVersion(library: library, type: .object(object), version: version)
        case .syncDeletions(let library, let version):
            self.progressHandler.reportDeletions(for: library)
            self.processDeletionsSync(library: library, since: version)
        case .syncSettings(let library, let version):
            self.processSettingsSync(for: library, since: version)
        case .storeSettingsVersion(let version, let library):
            self.processStoreVersion(library: library, type: .settings, version: version)
        }
    }

    private func processCreateLibraryActions() {
        let userId = self.userId
        let action: Single<[(Int, String, Versions)]>
        switch self.libraryType {
        case .all:
            action = self.handler.loadAllLibraryData()
        case .specific(let identifiers):
            action = self.handler.loadLibraryData(for: identifiers)
        }

        action.flatMap { libraryData -> Single<([(Library, Versions)], [Int: String])> in
                  var libraryNames: [Int: String] = [:]
                  var versionedLibraries: [(Library, Versions)] = []
                  for data in libraryData {
                      libraryNames[data.0] = data.1
                      if data.0 == RLibrary.myLibraryId {
                          versionedLibraries.append((.user(userId), data.2))
                      } else {
                          versionedLibraries.append((.group(data.0), data.2))
                      }
                  }
                  return Single.just((versionedLibraries, libraryNames))
              }
              .subscribe(onSuccess: { [weak self] data in
                  self?.performOnAccessQueue(flags: .barrier) { [weak self] in
                      self?.progressHandler.reportLibraryNames(data: data.1)
                  }
                  self?.finishCreateLibraryActions(with: .success(data.0))
              }, onError: { [weak self] error in
                  self?.finishCreateLibraryActions(with: .failure(error))
              })
              .disposed(by: self.disposeBag)
    }

    private func finishCreateLibraryActions(with result: Result<[(Library, Versions)]>) {
        switch result {
        case .failure(let error):
            self.abort(error: SyncError.allLibrariesFetchFailed(error))

        case .success(let libraryData):
            self.performOnAccessQueue(flags: .barrier) { [weak self] in
                guard let `self` = self else { return }

                var allActions: [Action] = []
                libraryData.forEach { data in
                    let actions: [Action] = [.syncSettings(data.0, data.1.settings),
                                             .syncVersions(data.0, .collection, data.1.collections),
                                             .syncVersions(data.0, .search, data.1.searches),
                                             .syncVersions(data.0, .item, data.1.items),
                                             .syncVersions(data.0, .trash, data.1.trash),
                                             .syncDeletions(data.0, data.1.deletions)]
                    allActions.append(contentsOf: actions)
                }
                self.enqueue(actions: allActions)
            }
        }
    }

    private func processSyncVersions(library: Library, object: Object, since version: Int?) {
        self.handler.synchronizeVersions(for: library, object: object, since: version,
                                         current: self.lastReturnedVersion, syncAll: (self.type == .initial))
                    .subscribe(onSuccess: { [weak self] data in
                        self?.finishSyncVersionsAction(for: library, object: object, result: .success((data.1, data.0)))
                    }, onError: { [weak self] error in
                        self?.finishSyncVersionsAction(for: library, object: object, result: .failure(error))
                    })
                    .disposed(by: self.disposeBag)
    }

    private func finishSyncVersionsAction(for library: Library, object: Object,
                                          result: Result<([Any], Int)>) {
        switch result {
        case .success(let data):
            self.progressHandler.reportObjectCount(for: object, count: data.0.count)
            self.createBatchedActions(from: data.0, currentVersion: data.1, library: library, object: object)

        case .failure(let error):
            if let abortError = self.errorRequiresAbort(error, library: library, object: object) {
                self.abort(error: abortError)
                return
            }

            if object == .group {
                self.abort(error: SyncError.groupSyncFailed(error))
                return
            }

            if self.handleVersionMismatchIfNeeded(for: error, library: library) { return }

            self.performOnAccessQueue(flags: .barrier) { [weak self] in
                guard let `self` = self else { return }
                self.nonFatalErrors.append(error)
                self.processNextAction()
            }
        }
    }

    private func createBatchedActions(from keys: [Any], currentVersion: Int,
                                      library: Library, object: Object) {
        let batches: [Batch]
        switch object {
        case .group:
            let batchData = self.createBatchGroups(for: keys, library: library, object: object,
                                                   version: currentVersion, libraryType: self.libraryType)
            batches = batchData.0
            // TODO: - report deleted groups?
        default:
            batches = self.createBatchObjects(for: keys, library: library, object: object, version: currentVersion)
        }

        var actions: [Action] = batches.map({ .syncBatchToDb($0) })
        if object == .group {
            actions.append(.createLibraryActions)
        } else if !actions.isEmpty {
            actions.append(.storeVersion(currentVersion, library, object))
        }

        self.performOnAccessQueue(flags: .barrier) { [weak self] in
            if object != .group {
                self?.lastReturnedVersion = currentVersion
            }
            self?.enqueue(actions: actions, at: 0)
        }
    }

    private func createBatchGroups(for keys: [Any], library: Library, object: Object,
                                   version: Int, libraryType: LibrarySyncType) -> ([Batch], [Int]) {
        var toSync: [Any] = []
        var missing: [Int] = []

        switch libraryType {
        case .all:
            toSync = keys

        case .specific(let identifiers):
            guard let intKeys = keys as? [Int] else { return ([], []) }

            identifiers.forEach { identifier in
                if intKeys.contains(identifier) {
                    toSync.append(identifier)
                } else {
                    missing.append(identifier)
                }
            }
        }

        let batches = toSync.map { Batch(library: library, object: object, keys: [$0], version: version) }
        return (batches, missing)
    }

    private func createBatchObjects(for keys: [Any], library: Library,
                                    object: Object, version: Int) -> [Batch] {
        let maxBatchSize = Batch.maxCount
        var batchSize = 5
        var processed = 0
        var batches: [Batch] = []

        while processed < keys.count {
            let upperBound = min((keys.count - processed), batchSize) + processed
            let batchKeys = Array(keys[processed..<upperBound])

            batches.append(Batch(library: library, object: object, keys: batchKeys, version: version))

            processed += batchSize
            if batchSize < maxBatchSize {
                batchSize = min(batchSize * 2, maxBatchSize)
            }
        }

        return batches
    }

    private func processBatchSync(for batch: Batch) {
        self.handler.fetchAndStoreObjects(with: batch.keys, library: batch.library,
                                          object: batch.object, version: batch.version)
                    .subscribe(onSuccess: { [weak self] decodingData in
                        self?.finishBatchSyncAction(for: batch.library, object: batch.object,
                                                    allKeys: batch.keys, result: .success(decodingData))
                    }, onError: { [weak self] error in
                        self?.finishBatchSyncAction(for: batch.library, object: batch.object,
                                                    allKeys: batch.keys, result: .failure(error))
                    })
                    .disposed(by: self.disposeBag)
    }

    private func finishBatchSyncAction(for library: Library, object: Object, allKeys: [Any],
                                     result: Result<([String], [Error])>) {
        switch result {
        case .success(let decodingData):
            if object == .group {
                // Groups always sync 1-by-1, so if an error happens it's always reported as .failure, only successful
                // actions are reported here, so we can directly skip to next action
                self.performOnAccessQueue(flags: .barrier) { [weak self] in
                    self?.processNextAction()
                }
                return
            }

            // Decoding of other objects is performed in batches, out of the whole batch only some objects may fail,
            // so these failures are reported as success (because some succeeded) and failed ones are marked for resync

            if !decodingData.1.isEmpty {
                self.performOnAccessQueue(flags: .barrier) { [weak self] in
                    self?.nonFatalErrors.append(contentsOf: decodingData.1)
                }
            }

            let allStringKeys = (allKeys as? [String]) ?? []
            let failedKeys = allStringKeys.filter({ !decodingData.0.contains($0) })

            self.performOnAccessQueue(flags: .barrier) { [weak self] in
                self?.progressHandler.reportBatch(for: object, count: allKeys.count)
            }

            if failedKeys.isEmpty {
                self.performOnAccessQueue(flags: .barrier) { [weak self] in
                    self?.processNextAction()
                }
                return
            }

            self.markForResync(keys: Array(failedKeys), library: library, object: object)
        case .failure(let error):
            DDLogError("--- BATCH: \(error)")
            if let abortError = self.errorRequiresAbort(error) {
                self.abort(error: abortError)
                return
            }

            self.performOnAccessQueue(flags: .barrier) { [weak self] in
                self?.progressHandler.reportBatch(for: object, count: allKeys.count)
                self?.nonFatalErrors.append(error)
            }

            // We failed to sync the whole batch, mark all for resync and continue with sync
            self.markForResync(keys: allKeys, library: library, object: object)
        }
    }

    private func processStoreVersion(library: Library, type: UpdateVersionType, version: Int) {
        self.handler.storeVersion(version, for: library, type: type)
                    .subscribe(onCompleted: { [weak self] in
                        self?.finishProcessingStoreVersionAction(error:  nil)
                    }, onError: { [weak self] error in
                        self?.finishProcessingStoreVersionAction(error: error)
                    })
                    .disposed(by: self.disposeBag)
    }

    private func finishProcessingStoreVersionAction(error: Error?) {
        guard let error = error else {
            self.performOnAccessQueue(flags: .barrier) { [weak self] in
                self?.processNextAction()
            }
            return
        }

        if let abortError = self.errorRequiresAbort(error) {
            self.abort(error: abortError)
            return
        }

        // If we only failed to store correct versions we can continue as usual, we'll just try to fetch from
        // older version on next sync and most objects will be up to date
        self.performOnAccessQueue(flags: .barrier) { [weak self] in
            self?.nonFatalErrors.append(error)
            self?.processNextAction()
        }
    }

    private func markForResync(keys: [Any], library: Library, object: Object) {
        self.handler.markForResync(keys: keys, library: library, object: object)
                    .subscribe(onCompleted: { [weak self] in
                        self?.performOnAccessQueue(flags: .barrier) { [weak self] in
                            guard let `self` = self else { return }
                            self.setNeedsResync()
                            self.processNextAction()
                        }
                    }, onError: { [weak self] error in
                        self?.performOnAccessQueue(flags: .barrier) { [weak self] in
                            guard let `self` = self else { return }
                            self.nonFatalErrors.append(error)
                            self.removeAllActions(for: library)
                            self.processNextAction()
                        }
                    })
                    .disposed(by: self.disposeBag)
    }

    private func processDeletionsSync(library: Library, since sinceVersion: Int) {
        self.handler.synchronizeDeletions(for: library, since: sinceVersion, current: self.lastReturnedVersion)
                    .subscribe(onCompleted: { [weak self] in
                        self?.finishDeletionsSync(error: nil)
                    }, onError: { [weak self] error in
                        self?.finishDeletionsSync(error: error)
                    })
                    .disposed(by: self.disposeBag)
    }

    private func finishDeletionsSync(error: Error?) {
        guard let error = error else {
            self.performOnAccessQueue(flags: .barrier) { [weak self] in
                self?.processNextAction()
            }
            return
        }

        if let abortError = self.errorRequiresAbort(error) {
            self.abort(error: abortError)
            return
        }

        self.performOnAccessQueue(flags: .barrier) { [weak self] in
            self?.nonFatalErrors.append(error)
            self?.processNextAction()
        }
    }

    private func processSettingsSync(for library: Library, since version: Int?) {
        self.handler.synchronizeSettings(for: library, current: self.lastReturnedVersion, since: version)
                    .subscribe(onSuccess: { [weak self] data in
                        self?.performOnAccessQueue(flags: .barrier) { [weak self] in
                            if data.0 {
                                self?.enqueue(actions: [.storeSettingsVersion(data.1, library)], at: 0)
                            } else {
                                self?.processNextAction()
                            }
                        }
                    }, onError: { [weak self] error in
                        self?.performOnAccessQueue(flags: .barrier) { [weak self] in
                            self?.nonFatalErrors.append(error)
                            self?.processNextAction()
                        }
                    })
                    .disposed(by: self.disposeBag)
    }

    // MARK: - Helpers

    private func performOnAccessQueue(flags: DispatchWorkItemFlags = [], action: @escaping () -> Void) {
        self.accessQueue.async(flags: flags) {
            action()
        }
    }

    private func errorRequiresAbort(_ error: Error, library: Library? = nil,
                                    object: Object? = nil) -> Error? {
        let nsError = error as NSError

        // Check connection
        if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorNotConnectedToInternet {
            return SyncError.noInternetConnection
        }

        // Check other networking errors
        if let alamoError = error as? AFError {
            switch alamoError {
            case .responseValidationFailed(let reason):
                switch reason {
                case .unacceptableStatusCode(let code):
                    return (code >= 400 && code < 500) ? SyncError.apiError : nil
                case .dataFileNil, .dataFileReadFailed, .missingContentType, .unacceptableContentType:
                    return SyncError.apiError
                }
            case .multipartEncodingFailed, .parameterEncodingFailed, .invalidURL:
                return SyncError.apiError
            case .responseSerializationFailed:
                return nil
            }
        }

        // Check realm errors, every "core" error is bad. Can't create new Realm instance, can't continue with sync
        if error is Realm.Error {
            return SyncError.dbError
        }

        return nil
    }

    private func handleVersionMismatchIfNeeded(for error: Error, library: Library) -> Bool {
        guard error.isMismatchError else { return false }

        // If the backend received higher version in response than from previous responses,
        // there was a change on backend and we'll probably have conflicts, abort this library
        // and continue with sync
        self.performOnAccessQueue(flags: .barrier) { [weak self] in
            guard let `self` = self else { return }
            self.nonFatalErrors.append(error)
            self.removeAllActions(for: library)
            self.processNextAction()
        }
        return true
    }

    // MARK: - Testing

    var reportFinish: ((Result<([Action], [Error])>) -> Void)?
    private var allActions: [Action] = []

    func start(with queue: [Action], libraries: LibrarySyncType,
               finishedAction: @escaping (Result<([Action], [Error])>) -> Void) {
        self.queue = queue
        self.libraryType = libraries
        self.allActions = []
        self.reportFinish = finishedAction
        self.processNextAction()
    }
}

extension Error {
    var isMismatchError: Bool {
        return (self as? SyncActionHandlerError) == .versionMismatch
    }
}
