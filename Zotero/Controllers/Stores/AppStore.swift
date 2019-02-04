//
//  AppStore.swift
//  Zotero
//
//  Created by Michal Rentka on 03/02/2019.
//  Copyright © 2019 Corporation for Digital Scholarship. All rights reserved.
//

import Foundation

enum AppAction {
    case change(AppState)
}

enum AppState {
    case onboarding, main
}

class AppStore: Store {
    typealias Action = AppAction
    typealias State = AppState

    let updater: StoreStateUpdater<AppState>
    let apiClient: ApiClient

    init(apiClient: ApiClient, secureStorage: SecureStorage) {
        self.apiClient = apiClient
        let state: AppState = secureStorage.apiToken == nil ? .onboarding : .main
        self.updater = StoreStateUpdater(initialState: state)
    }

    func handle(action: AppAction) {
        switch action {
        case .change(let new):
            self.updater.updateState { newState in
                newState = new
            }
        }
    }
}
