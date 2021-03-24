//
//  EmptyTrashDbRequest.swift
//  Zotero
//
//  Created by Michal Rentka on 24.03.2021.
//  Copyright © 2021 Corporation for Digital Scholarship. All rights reserved.
//

import Foundation

import RealmSwift

struct EmptyTrashDbRequest: DbRequest {
    let libraryId: LibraryIdentifier

    var needsWrite: Bool { return true }
    var ignoreNotificationTokens: [NotificationToken]? { return nil }

    func process(in database: Realm) throws {
        database.objects(RItem.self).filter(.items(for: .trash, libraryId: self.libraryId)).forEach {
            $0.deleted = true
            $0.changeType = .user
        }
    }
}
