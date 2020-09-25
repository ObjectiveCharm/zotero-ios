//
//  MarkGroupForResyncSyncAction.swift
//  Zotero
//
//  Created by Michal Rentka on 02/06/2020.
//  Copyright © 2020 Corporation for Digital Scholarship. All rights reserved.
//

import Foundation

import CocoaLumberjack
import RxSwift

struct MarkGroupForResyncSyncAction: SyncAction {
    typealias Result = ()

    let identifier: Int

    unowned let dbStorage: DbStorage

    var result: Single<()> {
        return Single.create { subscriber -> Disposable in
            do {
                try self.dbStorage.createCoordinator().perform(request: MarkGroupForResyncDbAction(identifier: self.identifier))
                subscriber(.success(()))
            } catch let error {
                subscriber(.error(error))
            }
            return Disposables.create()
        }
    }
}
