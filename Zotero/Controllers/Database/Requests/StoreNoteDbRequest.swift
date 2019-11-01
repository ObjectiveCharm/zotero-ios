//
//  StoreNoteDbRequest.swift
//  Zotero
//
//  Created by Michal Rentka on 07/10/2019.
//  Copyright © 2019 Corporation for Digital Scholarship. All rights reserved.
//

import Foundation

import RealmSwift

struct StoreNoteDbRequest: DbRequest {
    let note: ItemDetailStore.State.Note
    let libraryId: LibraryIdentifier

    var needsWrite: Bool {
        return true
    }

    func process(in database: Realm) throws {
        guard let item = database.objects(RItem.self).filter(.key(self.note.key, in: self.libraryId)).first,
              let field = item.fields.filter(.key(FieldKeys.note)).first else {
            throw DbError.objectNotFound
        }

        guard field.value != self.note.text else { return }
        item.title = self.note.title
        item.changedFields.insert(.fields)
        field.value = self.note.text
        field.changed = true
    }
}
