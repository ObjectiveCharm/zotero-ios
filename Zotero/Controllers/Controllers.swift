//
//  Controllers.swift
//  Zotero
//
//  Created by Michal Rentka on 03/02/2019.
//  Copyright © 2019 Corporation for Digital Scholarship. All rights reserved.
//

import Foundation

import CocoaLumberjack
import RxSwift

/// Global controllers which don't need user session
class Controllers {
    let apiClient: ApiClient
    let secureStorage: SecureStorage
    let dbStorage: DbStorage
    let fileStorage: FileStorage
    let schemaController: SchemaController
    let dragDropController: DragDropController
    let itemLocaleController: RItemLocaleController
    let crashReporter: CrashReporter

    var userControllers: UserControllers?

    init() {
        let fileStorage = FileStorageController()
        let secureStorage = KeychainSecureStorage()
        let authToken = ApiConstants.authToken ?? secureStorage.apiToken
        let apiClient = ZoteroApiClient(baseUrl: ApiConstants.baseUrlString,
                                        headers: ["Zotero-API-Version": ApiConstants.version.description])
        apiClient.set(authToken: authToken)
        let crashReporter = CrashReporter(apiClient: apiClient)
        let schemaController = SchemaController(apiClient: apiClient, userDefaults: UserDefaults.standard)

        do {
            let file = Files.dbFile
            DDLogInfo("DB file path: \(file.createUrl().absoluteString)")
            try fileStorage.createDictionaries(for: file)
            let dbStorage = RealmDbStorage(url: file.createUrl())

            if let userId = ApiConstants.userId {
                try Controllers.setupDebugDb(in: dbStorage, userId: userId)
            }

            self.dbStorage = dbStorage
            self.itemLocaleController = RItemLocaleController(schemaController: schemaController, dbStorage: dbStorage)
        } catch let error {
            fatalError("Controllers: Could not initialize My Library - \(error.localizedDescription)")
        }

        self.apiClient = apiClient
        self.secureStorage = secureStorage
        self.fileStorage = fileStorage
        self.schemaController = schemaController
        self.dragDropController = DragDropController()
        self.crashReporter = crashReporter

        // Not logged in, don't setup user controllers
        if authToken == nil { return }

        do {
            let userId: Int
            if let id = ApiConstants.userId {
                userId = id
            } else {
                userId = Defaults.shared.userId
            }
            self.userControllers = UserControllers(userId: userId, controllers: self)
        } catch let error {
            DDLogError("Controllers: User logged in, but could not load userId - \(error.localizedDescription)")
            secureStorage.apiToken = nil
        }
    }

    func sessionChanged(userId: Int?) {
        self.userControllers = userId.flatMap({ UserControllers(userId: $0, controllers: self) })
    }

    private class func setupDebugDb(in storage: DbStorage, userId: Int) throws {
        let coordinator = try storage.createCoordinator()
        var needsUser = false
        var needsWipe = false

        do {
            if Defaults.shared.userId == userId { return }

            // User found, but different
            needsUser = true
            needsWipe = true
        } catch {
            // User not found
            needsUser = true
        }

        if needsWipe {
            try coordinator.perform(request: DeleteAllDbRequest())
        }

        if needsUser {
            Defaults.shared.userId = userId
            Defaults.shared.username = "Tester"
            try coordinator.perform(request: InitializeCustomLibrariesDbRequest())
        }
    }
}

/// Global controllers for logged in user
class UserControllers {
    let syncScheduler: SynchronizationScheduler
    let changeObserver: ObjectChangeObserver
    private let disposeBag: DisposeBag

    init(userId: Int, controllers: Controllers) {
        self.disposeBag = DisposeBag()
        let syncHandler = SyncActionHandlerController(userId: userId, apiClient: controllers.apiClient,
                                                      dbStorage: controllers.dbStorage,
                                                      fileStorage: controllers.fileStorage,
                                                      schemaController: controllers.schemaController,
                                                      syncDelayIntervals: DelayIntervals.sync)
        let syncController = SyncController(userId: userId, handler: syncHandler,
                                            conflictDelays: DelayIntervals.conflict)
        self.syncScheduler = SyncScheduler(controller: syncController)
        self.changeObserver = RealmObjectChangeObserver(dbStorage: controllers.dbStorage)

        self.performInitialActions()
    }

    private func performInitialActions() {
        self.changeObserver.observable
                           .observeOn(MainScheduler.instance)
                           .subscribe(onNext: { [weak self] changedLibraries in
                               self?.syncScheduler.requestSync(for: changedLibraries)
                           })
                           .disposed(by: self.disposeBag)
    }
}
