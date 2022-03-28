//
//  LibrariesActionHandler.swift
//  Zotero
//
//  Created by Michal Rentka on 27/02/2020.
//  Copyright © 2020 Corporation for Digital Scholarship. All rights reserved.
//

import Foundation

import CocoaLumberjackSwift

struct LibrariesActionHandler: ViewModelActionHandler {
    typealias State = LibrariesState
    typealias Action = LibrariesAction

    private let dbStorage: DbStorage
    private let backgroundQueue: DispatchQueue

    init(dbStorage: DbStorage) {
        self.dbStorage = dbStorage
        self.backgroundQueue = DispatchQueue(label: "org.zotero.LibrariesActionHandler.backgroundQueue", qos: .userInteractive)
    }

    func process(action: LibrariesAction, in viewModel: ViewModel<LibrariesActionHandler>) {
        switch action {
        case .loadData:
            self.loadData(in: viewModel)

        case .setCustomLibraries(let results):
            self.update(viewModel: viewModel) { state in
                state.customLibraries = results
            }

        case .setGroupLibraries(let results):
            self.update(viewModel: viewModel) { state in
                state.groupLibraries = results
            }

        case .showDeleteGroupQuestion(let question):
            self.update(viewModel: viewModel) { state in
                state.deleteGroupQuestion = question
            }

        case .deleteGroup(let groupId):
            self.backgroundQueue.async {
                self.deleteGroup(id: groupId, dbStorage: self.dbStorage)
            }
        }
    }

    private func loadData(in viewModel: ViewModel<LibrariesActionHandler>) {
        do {
            let libraries = try self.dbStorage.perform(request: ReadAllCustomLibrariesDbRequest())
            let groups = try self.dbStorage.perform(request: ReadAllGroupsDbRequest())

            let groupsToken = groups.observe { [weak viewModel] changes in
                guard let viewModel = viewModel else { return }
                switch changes {
                case .update(_, let deletions, _, _):
                    self.update(viewModel: viewModel) { state in
                        state.changes = .groups
                        if !deletions.isEmpty {
                            state.changes.insert(.groupDeletion)
                        }
                    }
                case .initial: break
                case .error: break
                }
            }

            self.update(viewModel: viewModel) { state in
                state.groupLibraries = groups
                state.customLibraries = libraries
                state.groupsToken = groupsToken
            }
        } catch let error {
            DDLogError("LibrariesStore: can't load libraries - \(error)")
            self.update(viewModel: viewModel) { state in
                state.error = .cantLoadData
            }
        }
    }

    private func deleteGroup(id: Int, dbStorage: DbStorage) {
        do {
            try dbStorage.perform(request: DeleteGroupDbRequest(groupId: id))
        } catch let error {
            DDLogError("LibrariesActionHandler: can't delete group - \(error)")
        }
    }
}
