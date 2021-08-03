//
//  SettingsActionHandler.swift
//  Zotero
//
//  Created by Michal Rentka on 15/10/2019.
//  Copyright © 2019 Corporation for Digital Scholarship. All rights reserved.
//

import Combine
import Foundation

import CocoaLumberjackSwift
import RxSwift

struct SettingsActionHandler: ViewModelActionHandler {
    typealias Action = SettingsAction
    typealias State = SettingsState

    private unowned let dbStorage: DbStorage
    private unowned let bundledDataStorage: DbStorage
    private unowned let fileStorage: FileStorage
    private unowned let sessionController: SessionController
    private unowned let syncScheduler: SynchronizationScheduler
    private unowned let debugLogging: DebugLogging
    private unowned let translatorsController: TranslatorsController
    private unowned let webSocketController: WebSocketController
    private unowned let fileCleanupController: AttachmentFileCleanupController
    private let disposeBag: DisposeBag

    init(dbStorage: DbStorage, bundledDataStorage: DbStorage, fileStorage: FileStorage, sessionController: SessionController, webSocketController: WebSocketController,
         syncScheduler: SynchronizationScheduler, debugLogging: DebugLogging, translatorsController: TranslatorsController, fileCleanupController: AttachmentFileCleanupController) {
        self.dbStorage = dbStorage
        self.bundledDataStorage = bundledDataStorage
        self.fileStorage = fileStorage
        self.sessionController = sessionController
        self.webSocketController = webSocketController
        self.syncScheduler = syncScheduler
        self.debugLogging = debugLogging
        self.translatorsController = translatorsController
        self.fileCleanupController = fileCleanupController
        self.disposeBag = DisposeBag()
    }

    func process(action: SettingsAction, in viewModel: ViewModel<SettingsActionHandler>) {
        switch action {
        case .setAskForSyncPermission(let value):
            self.update(viewModel: viewModel) { state in
                state.askForSyncPermission = value
            }

        case .setShowSubcollectionItems(let value):
            self.update(viewModel: viewModel) { state in
                state.showSubcollectionItems = value
            }

        case .startSync:
            self.syncScheduler.request(syncType: .ignoreIndividualDelays)

        case .cancelSync:
            self.syncScheduler.cancelSync()

        case .setLogoutAlertVisible(let visible):
            self.update(viewModel: viewModel) { state in
                state.logoutAlertVisible = visible
            }

        case .logout:
            self.update(viewModel: viewModel) { state in
                state.logoutAlertVisible = false
            }
            self.sessionController.reset()

        case .startObserving:
            self.observeTranslatorUpdate(in: viewModel)
            self.observeSyncChanges(in: viewModel)
            self.observeWebSocketConnection(in: viewModel)
            self.observeDebugLogging(in: viewModel)

        case .startImmediateLogging:
            self.debugLogging.start(type: .immediate)

        case .startLoggingOnNextLaunch:
            self.debugLogging.start(type: .nextLaunch)

        case .stopLogging:
            self.debugLogging.stop()

        case .updateTranslators:
            self.translatorsController.updateFromRepo(type: .manual)

        case .resetTranslators:
            self.translatorsController.resetToBundle()

        case .loadStorageData:
            self.loadStorageData(in: viewModel)

        case .deleteAllDownloads:
            self.removeAllDownloads(in: viewModel)

        case .deleteDownloadsInLibrary(let libraryId):
            self.removeDownloads(for: libraryId, in: viewModel)

        case .showDeleteAllQuestion(let show):
            self.update(viewModel: viewModel) { state in
                state.showDeleteAllQuestion = show
            }

        case .showDeleteLibraryQuestion(let library):
            self.update(viewModel: viewModel) { state in
                state.showDeleteLibraryQuestion = library
            }

        case .connectToWebSocket:
            guard let apiKey = self.sessionController.sessionData?.apiToken else { return }
            self.webSocketController.connect(apiKey: apiKey)

        case .disconnectFromWebSocket:
            guard let apiKey = self.sessionController.sessionData?.apiToken else { return }
            self.webSocketController.disconnect(apiKey: apiKey)

        case .setIncludeTags(let value):
            self.update(viewModel: viewModel) { state in
                state.includeTags = value
            }

        case .setIncludeAttachment(let value):
            self.update(viewModel: viewModel) { state in
                state.includeAttachment = value
            }
        }
    }

    private func removeAllDownloads(in viewModel: ViewModel<SettingsActionHandler>) {
        self.fileCleanupController.delete(.all) { [weak viewModel] deleted in
            guard deleted, let viewModel = viewModel else { return }
            self.update(viewModel: viewModel) { state in
                for (key, _) in state.storageData {
                    state.storageData[key] = DirectoryData(fileCount: 0, mbSize: 0)
                }
                state.totalStorageData = DirectoryData(fileCount: 0, mbSize: 0)
                state.showDeleteAllQuestion = false
            }
        }
    }

    private func removeDownloads(for libraryId: LibraryIdentifier, in viewModel: ViewModel<SettingsActionHandler>) {
        self.fileCleanupController.delete(.library(libraryId)) { [weak viewModel] deleted in
            guard deleted, let viewModel = viewModel else { return }

            let newTotal = self.fileStorage.directoryData(for: [Files.downloads, Files.annotationPreviews])

            self.update(viewModel: viewModel) { state in
                state.storageData[libraryId] = DirectoryData(fileCount: 0, mbSize: 0)
                state.totalStorageData = newTotal
                state.showDeleteLibraryQuestion = nil
            }
        }
    }

    private func loadStorageData(in viewModel: ViewModel<SettingsActionHandler>) {
        do {
            let coordinator = try self.dbStorage.createCoordinator()
            let libraries = Array((try coordinator.perform(request: ReadAllCustomLibrariesDbRequest())).map(Library.init)) +
                            (try coordinator.perform(request: ReadAllGroupsDbRequest())).map(Library.init)

            let (storageData, totalData) = self.storageData(for: libraries)

            self.update(viewModel: viewModel) { state in
                state.libraries = libraries
                state.storageData = storageData
                state.totalStorageData = totalData
            }
        } catch let error {
            DDLogError("SettingsActionHandler: can't load libraries - \(error)")
            // TODO: - Show error to user
        }
    }

    private func storageData(for libraries: [Library]) -> (libraryData: [LibraryIdentifier: DirectoryData], totalData: DirectoryData) {
        var storageData: [LibraryIdentifier: DirectoryData] = [:]
        for library in libraries {
            let libraryId = library.identifier
            let data = self.fileStorage.directoryData(for: [Files.downloads(for: libraryId), Files.annotationPreviews(for: libraryId)])
            storageData[library.identifier] = data
        }
        let totalData = self.fileStorage.directoryData(for: [Files.downloads, Files.annotationPreviews])
        return (storageData, totalData)
    }

    private func observeWebSocketConnection(in viewModel: ViewModel<SettingsActionHandler>) {
        self.webSocketController.connectionState
                                .observe(on: MainScheduler.instance)
                                .subscribe(onNext: { [weak viewModel] connectionState in
                                    guard let viewModel = viewModel else { return }
                                    self.update(viewModel: viewModel) { state in
                                        state.websocketConnectionState = connectionState
                                    }
                                })
                                .disposed(by: self.disposeBag)
    }

    private func observeTranslatorUpdate(in viewModel: ViewModel<SettingsActionHandler>) {
        self.translatorsController.isLoading
                                  .observe(on: MainScheduler.instance)
                                  .subscribe(onNext: { [weak viewModel] isLoading in
                                      guard let viewModel = viewModel else { return }
                                      self.update(viewModel: viewModel) { state in
                                          state.isUpdatingTranslators = isLoading
                                      }
                                  })
                                  .disposed(by: self.disposeBag)
    }

    private func observeSyncChanges(in viewModel: ViewModel<SettingsActionHandler>) {
        self.syncScheduler.syncController.progressObservable
                                         .observe(on: MainScheduler.instance)
                                         .subscribe(onNext: { [weak viewModel] progress in
                                             guard let viewModel = viewModel else { return }
                                             self.update(viewModel: viewModel) { state in
                                                switch progress {
                                                case .aborted, .finished:
                                                    state.isSyncing = false
                                                default:
                                                    state.isSyncing = true
                                                }
                                             }
                                         })
                                         .disposed(by: self.disposeBag)
    }

    private func observeDebugLogging(in viewModel: ViewModel<SettingsActionHandler>) {
        self.debugLogging.isEnabledPublisher
            .subscribe(onNext: { [weak viewModel] isEnabled in
                guard let viewModel = viewModel else { return }
                self.update(viewModel: viewModel) { state in
                    state.isLogging = isEnabled
                }
            })
            .disposed(by: self.disposeBag)
    }
}
