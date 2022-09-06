//
//  DebuggingActionHandler.swift
//  Zotero
//
//  Created by Michal Rentka on 11.10.2021.
//  Copyright © 2021 Corporation for Digital Scholarship. All rights reserved.
//

import Foundation

import CocoaLumberjackSwift
import RxSwift

struct DebuggingActionHandler: ViewModelActionHandler {
    typealias Action = DebuggingAction
    typealias State = DebuggingState

    private unowned let debugLogging: DebugLogging
    private unowned let coordinatorDelegate: DebuggingSettingsSettingsCoordinatorDelegate

    init(debugLogging: DebugLogging, coordinatorDelegate: DebuggingSettingsSettingsCoordinatorDelegate) {
        self.debugLogging = debugLogging
        self.coordinatorDelegate = coordinatorDelegate
    }

    func process(action: DebuggingAction, in viewModel: ViewModel<DebuggingActionHandler>) {
        switch action {
        case .startImmediateLogging:
            self.debugLogging.start(type: .immediate)
            self.update(viewModel: viewModel) { state in
                state.isLogging = true
            }

        case .startLoggingOnNextLaunch:
            self.debugLogging.start(type: .nextLaunch)

        case .stopLogging:
            self.debugLogging.stop()
            self.update(viewModel: viewModel) { state in
                state.isLogging = false
            }

        case .exportDb:
            self.coordinatorDelegate.exportDb()
        }
    }
}
