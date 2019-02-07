//
//  Controllers.swift
//  Zotero
//
//  Created by Michal Rentka on 03/02/2019.
//  Copyright © 2019 Corporation for Digital Scholarship. All rights reserved.
//

import Foundation

import RxSwift

/// Global controllers which don't need user session
class Controllers {
    let apiClient: ApiClient
    let secureStorage: SecureStorage
    let dbStorage: DbStorage
    let fileStorage: FileStorage

    var userControllers: UserControllers?

    init() {
        let fileStorage = FileStorageController()
        let secureStorage = KeychainSecureStorage()
        let apiClient = ZoteroApiClient(baseUrl: ApiConstants.baseUrlString,
                                        headers: ["Zotero-API-Version": ApiConstants.version.description],
                                        fileStorage: fileStorage)
        apiClient.set(authToken: secureStorage.apiToken)

        let path = NSSearchPathForDirectoriesInDomains(.documentDirectory, .allDomainsMask, true).first ?? "/"
        var url = URL(fileURLWithPath: path)
        url.appendPathComponent("maindb")
        url.appendPathExtension("realm")
        let dbStorage = RealmDbStorage(url: url)

        do {
            try dbStorage.createCoordinator().perform(request: InitializeMyLibraryDbRequest())
        } catch let error {
            fatalError("Controllers: Could not initialize My Library - \(error.localizedDescription)")
        }

        self.apiClient = apiClient
        self.secureStorage = secureStorage
        self.dbStorage = dbStorage
        self.fileStorage = fileStorage

        // Not logged in, don't setup user controllers
        if secureStorage.apiToken == nil { return }

        do {
            let userId = try dbStorage.createCoordinator().perform(request: ReadUserDbRequest()).identifier
            self.userControllers = UserControllers(userId: userId, controllers: self)
        } catch let error {
            fatalError("Controllers: User logged in, but could not load userId - \(error.localizedDescription)")
        }
    }

    func sessionChanged(userId: Int?) {
        self.userControllers = userId.flatMap({ UserControllers(userId: $0, controllers: self) })
    }
}

/// Global controllers for logged in user
class UserControllers {
    let syncController: SyncController

    init(userId: Int, controllers: Controllers) {
        let syncHandler = SyncActionHandlerController(userId: userId, apiClient: controllers.apiClient,
                                                      dbStorage: controllers.dbStorage,
                                                      fileStorage: controllers.fileStorage)
        self.syncController = SyncController(userId: userId, handler: syncHandler)
    }
}
