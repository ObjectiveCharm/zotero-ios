//
//  MarkAttachmentsNotUploadedDbRequest.swift
//  Zotero
//
//  Created by Michal Rentka on 26.10.2021.
//  Copyright © 2021 Corporation for Digital Scholarship. All rights reserved.
//

import Foundation

import RealmSwift

struct MarkAttachmentsNotUploadedDbRequest: DbRequest {
    let keys: [String]
    let libraryId: LibraryIdentifier

    var needsWrite: Bool { return true }
    var ignoreNotificationTokens: [NotificationToken]? { return nil }

    func process(in database: Realm) throws {
        let attachments = database.objects(RItem.self).filter(.keys(self.keys, in: self.libraryId))
        for attachment in attachments {
            attachment.attachmentNeedsSync = true
            attachment.changeType = .sync
        }
    }
}
