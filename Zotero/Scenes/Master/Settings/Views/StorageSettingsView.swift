//
//  StorageSettingsView.swift
//  Zotero
//
//  Created by Michal Rentka on 04/06/2020.
//  Copyright © 2020 Corporation for Digital Scholarship. All rights reserved.
//

import SwiftUI

struct StorageSettingsView: View {
    @EnvironmentObject var viewModel: ViewModel<SettingsActionHandler>

    var body: some View {
        Group {
            if self.viewModel.state.libraries.isEmpty {
                StorageSettingsEmptyView()
            } else {
                StorageSettingsListView()
            }
        }
        .onAppear {
            self.viewModel.process(action: .loadStorageData)
        }
    }
}

struct StorageSettingsView_Previews: PreviewProvider {
    static var previews: some View {
        let controllers = Controllers()
        let state = SettingsState(isSyncing: false,
                                  isLogging: controllers.debugLogging.isEnabled,
                                  isUpdatingTranslators: controllers.translatorsAndStylesController.isLoading.value,
                                  lastTranslatorUpdate: controllers.translatorsAndStylesController.lastUpdate,
                                  websocketConnectionState: .disconnected)
        let handler = SettingsActionHandler(dbStorage: controllers.userControllers!.dbStorage,
                                            bundledDataStorage: controllers.bundledDataStorage,
                                            fileStorage: controllers.fileStorage,
                                            sessionController: controllers.sessionController,
                                            webSocketController: controllers.userControllers!.webSocketController,
                                            syncScheduler: controllers.userControllers!.syncScheduler,
                                            debugLogging: controllers.debugLogging,
                                            translatorsAndStylesController: controllers.translatorsAndStylesController,
                                            fileCleanupController: controllers.userControllers!.fileCleanupController)
        return StorageSettingsView().environmentObject(ViewModel(initialState: state, handler: handler))
    }
}
