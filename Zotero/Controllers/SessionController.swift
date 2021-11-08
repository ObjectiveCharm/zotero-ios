//
//  SessionController.swift
//  Zotero
//
//  Created by Michal Rentka on 19/11/2019.
//  Copyright © 2019 Corporation for Digital Scholarship. All rights reserved.
//

import Foundation

typealias SessionData = (userId: Int, apiToken: String)

struct DebugSessionConstants {
    #if DEBUG
    static let userId: Int? = nil
    static let apiToken: String? = nil
    #else
    static let userId: Int? = nil
    static let apiToken: String? = nil
    #endif
}

final class SessionController: ObservableObject {
    @Published var sessionData: SessionData?
    var isLoggedIn: Bool {
        return self.sessionData != nil
    }

    private let defaults: Defaults
    private let secureStorage: SecureStorage

    init(secureStorage: SecureStorage, defaults: Defaults) {
        self.defaults = defaults
        self.secureStorage = secureStorage

        var apiToken = secureStorage.apiToken
        var userId = defaults.userId

        if (apiToken == nil || userId == 0),
           let debugUserId = DebugSessionConstants.userId,
           let debugApiToken = DebugSessionConstants.apiToken {
            apiToken = debugApiToken
            userId = debugUserId
            secureStorage.apiToken = debugApiToken
            defaults.userId = debugUserId
        }

        if let token = apiToken, userId > 0 {
            self.sessionData = (userId, token)
        } else {
            self.sessionData = nil
        }
    }

    func register(userId: Int, username: String, apiToken: String) {
        self.defaults.userId = userId
        self.defaults.username = username
        self.secureStorage.apiToken = apiToken
        self.sessionData = (userId, apiToken)
    }

    func reset() {
        self.defaults.reset()
        self.secureStorage.reset()
        self.sessionData = nil
    }
}
