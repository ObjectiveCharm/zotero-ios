//
//  SettingsListView.swift
//  Zotero
//
//  Created by Michal Rentka on 15/10/2019.
//  Copyright © 2019 Corporation for Digital Scholarship. All rights reserved.
//

import SwiftUI

struct SettingsListView: View {
    @EnvironmentObject var viewModel: ViewModel<SettingsActionHandler>
    
    weak var coordinatorDelegate: SettingsCoordinatorDelegate?

    var body: some View {
        Form {
            Section {
                Button(action: {
                    self.coordinatorDelegate?.showSync()
                }, label: {
                    SettingsListButtonRow(text: L10n.Settings.Sync.title, detailText: nil, enabled: true)
                })
            }

            Section {
                Button(action: {
                    self.coordinatorDelegate?.showGeneralSettings()
                }, label: {
                    SettingsListButtonRow(text: L10n.Settings.General.title, detailText: nil, enabled: true)
                })

                Button(action: {
                    self.coordinatorDelegate?.showExportSettings()
                }, label: {
                    SettingsListButtonRow(text: L10n.Settings.Export.title, detailText: nil, enabled: true)
                })

                Button(action: {
                    self.coordinatorDelegate?.showCitationSettings()
                }, label: {
                    SettingsListButtonRow(text: L10n.Settings.Cite.title, detailText: nil, enabled: true)
                })

                Button(action: {
                    self.coordinatorDelegate?.showSavingSettings()
                }, label: {
                    SettingsListButtonRow(text: L10n.Settings.Saving.title, detailText: nil, enabled: true)
                })

                Button(action: {
                    self.coordinatorDelegate?.showStorageSettings()
                }, label: {
                    SettingsListButtonRow(text: L10n.Settings.storage, detailText: nil, enabled: true)
                })

                Button(action: {
                    self.coordinatorDelegate?.showDebugging()
                }, label: {
                    SettingsListButtonRow(text: L10n.Settings.debug, detailText: nil, enabled: true)
                })
            }

            Section(footer: self.footer) {
                Button(action: {
                    self.coordinatorDelegate?.showSupport()
                }, label: {
                    Text(L10n.supportFeedback)
                        .foregroundColor(Color(self.textColor))
                })

                Button(action: {
                    self.coordinatorDelegate?.showPrivacyPolicy()
                }, label: {
                    Text(L10n.privacyPolicy)
                        .foregroundColor(Color(self.textColor))
                })
            }
        }
        .listStyle(GroupedListStyle())
        .navigationBarTitle(Text(L10n.Settings.title), displayMode: .inline)
        .navigationBarItems(leading: Button(action: { self.coordinatorDelegate?.dismiss() },
                                            label: { Text(L10n.close).padding(.vertical, 10).padding(.trailing, 10) }))
    }

    private var footer: some View {
        GeometryReader { proxy in
            VStack(alignment: .center) {
                Text(self.versionBuildString)
                    .font(.footnote)
                    .foregroundColor(Color(UIColor.systemGray))
                Text(L10n.Settings.tapToCopy)
                    .font(.footnote)
                    .foregroundColor(Color(UIColor.systemGray))
            }
            .frame(width: proxy.size.width, alignment: .center)
        }
        .onTapGesture {
            UIPasteboard.general.string = self.versionBuildString
        }
    }

    private var versionBuildString: String {
        guard let version = DeviceInfoProvider.versionString, let build = DeviceInfoProvider.buildString else { return "" }
        return L10n.Settings.versionAndBuild(version, build)
    }

    private var textColor: UIColor {
        return UIColor(dynamicProvider: { traitCollection -> UIColor in
            return traitCollection.userInterfaceStyle == .dark ? .white : .black
        })
    }
}

struct SettingsListView_Previews: PreviewProvider {
    static var previews: some View {
        SettingsListView()
    }
}
