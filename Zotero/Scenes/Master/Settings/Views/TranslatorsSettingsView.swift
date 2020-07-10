//
//  TranslatorsSettingsView.swift
//  Zotero
//
//  Created by Michal Rentka on 02/04/2020.
//  Copyright © 2020 Corporation for Digital Scholarship. All rights reserved.
//

import SwiftUI

struct TranslatorsSettingsView: View {
    @EnvironmentObject var viewModel: ViewModel<SettingsActionHandler>

    private static var formatter = createFormatter()

    private static func createFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }

    var body: some View {
        Form {
            Section {
                if self.viewModel.state.isUpdatingTranslators {
                    Text(L10n.Settings.translatorsUpdating)
                } else {
                    Button(action: {
                        self.viewModel.process(action: .updateTranslators)
                    }) {
                        VStack(alignment: .leading) {
                            Text(L10n.Settings.translatorsUpdate)
                            Text("\(L10n.lastUpdated): " + TranslatorsSettingsView.formatter.string(from: self.viewModel.state.lastTranslatorUpdate))
                                .font(.footnote)
                                .foregroundColor(.gray)
                        }
                    }

                    Button(action: {
                        self.viewModel.process(action: .resetTranslators)
                    }) {
                        Text(L10n.Settings.resetToBundled).foregroundColor(Asset.Colors.zoteroBlue.swiftUiColor)
                    }
                }
            }
        }
    }
}

struct TranslatorsSettingsView_Previews: PreviewProvider {
    static var previews: some View {
        let controllers = Controllers()
        let state = SettingsState(isSyncing: false,
                                  isLogging: controllers.debugLogging.isEnabled,
                                  isUpdatingTranslators: controllers.translatorsController.isLoading.value,
                                  lastTranslatorUpdate: controllers.translatorsController.lastUpdate)
        let handler = SettingsActionHandler(dbStorage: controllers.userControllers!.dbStorage,
                                            fileStorage: controllers.fileStorage,
                                            sessionController: controllers.sessionController,
                                            syncScheduler: controllers.userControllers!.syncScheduler,
                                            debugLogging: controllers.debugLogging,
                                            translatorsController: controllers.translatorsController)
        return TranslatorsSettingsView().environmentObject(ViewModel(initialState: state, handler: handler))
    }
}
