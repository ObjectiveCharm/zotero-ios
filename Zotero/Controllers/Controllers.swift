//
//  Controllers.swift
//  Zotero
//
//  Created by Michal Rentka on 03/02/2019.
//  Copyright © 2019 Corporation for Digital Scholarship. All rights reserved.
//

import Combine
import Foundation

import CocoaLumberjack
import RxSwift

/// Global controllers which don't need user session
class Controllers {
    let sessionController: SessionController
    let apiClient: ApiClient
    let secureStorage: SecureStorage
    let fileStorage: FileStorage
    let schemaController: SchemaController
    let dragDropController: DragDropController
    let crashReporter: CrashReporter

    var userControllers: UserControllers?
    private var sessionCancellable: AnyCancellable?

    init() {
        let configuration = URLSessionConfiguration.default
        configuration.httpAdditionalHeaders = ["Zotero-API-Version": ApiConstants.version.description]
        configuration.sharedContainerIdentifier = AppGroup.identifier

        let apiClient = ZoteroApiClient(baseUrl: ApiConstants.baseUrlString, configuration: configuration)
        let secureStorage = KeychainSecureStorage()
        let sessionController = SessionController(secureStorage: secureStorage)
        apiClient.set(authToken: sessionController.sessionData?.apiToken)
        let crashReporter = CrashReporter(apiClient: apiClient)
        let schemaController = SchemaController(apiClient: apiClient, userDefaults: UserDefaults.zotero)

        self.sessionController = sessionController
        self.apiClient = apiClient
        self.secureStorage = secureStorage
        self.fileStorage = FileStorageController()
        self.schemaController = schemaController
        self.dragDropController = DragDropController()
        self.crashReporter = crashReporter

        if let userId = sessionController.sessionData?.userId {
            self.userControllers = UserControllers(userId: userId, controllers: self)
        }

        self.sessionCancellable = sessionController.$sessionData
                                                   .receive(on: DispatchQueue.main)
                                                   .dropFirst()
                                                   .sink { [weak self] data in
                                                       self?.update(sessionData: data)
                                                   }

        // Controllers are initialized in application(:didFinishLaunchingWithOptions:). willEnterForegound is not called after launching the app for
        // the first time. But we want to run necessary services initially as well as when entering the foreground.
        self.willEnterForeground()
    }

    func willEnterForeground() {
        self.crashReporter.processPendingReports()
        self.userControllers?.itemLocaleController.loadLocale()
        // TODO: - run sync after schema loaded (possibly from remote source)
        self.schemaController.reloadSchemaIfNeeded()
        self.userControllers?.syncScheduler.requestFullSync()
        self.userControllers?.startObserving()
    }

    func didEnterBackground() {
        self.userControllers?.itemLocaleController.storeLocale()
        self.userControllers?.syncScheduler.cancelSync()
        self.userControllers?.stopObserving()
    }

    private func update(sessionData: SessionData?) {
        self.apiClient.set(authToken: sessionData?.apiToken)

        // Cancel ongoing sync in case of log out
        self.userControllers?.syncScheduler.cancelSync()
        self.userControllers = sessionData.flatMap { UserControllers(userId: $0.userId, controllers: self) }
        // Enqueue full sync after successful login (
        self.userControllers?.syncScheduler.requestFullSync()
    }
}

/// Global controllers for logged in user
class UserControllers {
    let syncScheduler: SynchronizationScheduler
    let changeObserver: ObjectChangeObserver
    let dbStorage: DbStorage
    let itemLocaleController: RItemLocaleController

    private var disposeBag: DisposeBag

    init(userId: Int, controllers: Controllers) {
        let dbStorage = UserControllers.createDbStorage(for: userId, controllers: controllers)

        let syncHandler = SyncActionHandlerController(userId: userId, apiClient: controllers.apiClient,
                                                      dbStorage: dbStorage,
                                                      fileStorage: controllers.fileStorage,
                                                      schemaController: controllers.schemaController,
                                                      syncDelayIntervals: DelayIntervals.sync)
        let syncController = SyncController(userId: userId, handler: syncHandler,
                                            conflictDelays: DelayIntervals.conflict)

        self.dbStorage = dbStorage
        self.syncScheduler = SyncScheduler(controller: syncController)
        self.changeObserver = RealmObjectChangeObserver(dbStorage: dbStorage)
        self.itemLocaleController = RItemLocaleController(schemaController: controllers.schemaController, dbStorage: dbStorage)
        self.disposeBag = DisposeBag()
    }

    deinit {
        // User logged out, clear database, cached files, etc.
        self.dbStorage.clear()
        // TODO: - remove cached files
    }

    func startObserving() {
        do {
            let coordinator = try self.dbStorage.createCoordinator()
            try coordinator.perform(request: InitializeCustomLibrariesDbRequest())
        } catch let error {
            // TODO: - handle the error a bit more graciously
            fatalError("UserControllers: can't create custom user library - \(error)")
        }

        self.changeObserver.observable
                           .observeOn(MainScheduler.instance)
                           .subscribe(onNext: { [weak self] changedLibraries in
                               self?.syncScheduler.requestSync(for: changedLibraries)
                           })
                           .disposed(by: self.disposeBag)
    }

    func stopObserving() {
        self.disposeBag = DisposeBag()
    }

    private class func createDbStorage(for userId: Int, controllers: Controllers) -> DbStorage {
        do {
            let file = Files.dbFile(for: userId)
            try controllers.fileStorage.createDictionaries(for: file)

            DDLogInfo("DB file path: \(file.createUrl().absoluteString)")

            return RealmDbStorage(url: file.createUrl())
        } catch let error {
            // TODO: - handle the error a bit more graciously
            fatalError("UserControllers: can't create DB file - \(error)")
        }
    }
}
