//
//  SettingsStore.swift
//  Zotero
//
//  Created by Michal Rentka on 15/10/2019.
//  Copyright © 2019 Corporation for Digital Scholarship. All rights reserved.
//

import Combine
import Foundation

class SettingsStore: ObservableObject {
    struct State {
        var askForSyncPermission: Bool {
            didSet {
                Defaults.shared.askForSyncPermission = self.askForSyncPermission
            }
        }

        init() {
            self.askForSyncPermission = Defaults.shared.askForSyncPermission
        }
    }

    @Published var state: State

    init() {
        self.state = State()
    }

    func logout() {
        NotificationCenter.default.post(name: .sessionChanged, object: nil)
    }
}
