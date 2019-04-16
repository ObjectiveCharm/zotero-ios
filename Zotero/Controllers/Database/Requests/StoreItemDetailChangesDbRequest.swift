//
//  StoreItemDetailChangesDbRequest.swift
//  Zotero
//
//  Created by Michal Rentka on 25/03/2019.
//  Copyright © 2019 Corporation for Digital Scholarship. All rights reserved.
//

import Foundation

import CocoaLumberjack
import RealmSwift

struct StoreItemDetailChangesDbRequest: DbRequest {
    var needsWrite: Bool {
        return true
    }

    let libraryId: LibraryIdentifier
    let itemKey: String
    let title: String?
    let abstract: String?
    let fields: [ItemDetailStore.StoreState.Field]
    let notes: [ItemDetailStore.StoreState.Note]

    func process(in database: Realm) throws {
        let predicate = Predicates.keyInLibrary(key: self.itemKey, libraryId: self.libraryId)
        guard let item = database.objects(RItem.self).filter(predicate).first else { return }

        var fieldsDidChange = false

        for field in self.fields {
            guard field.changed,
                  let itemField = item.fields.filter(Predicates.key(field.type)).first else { continue }
            itemField.value = field.value
            itemField.changed = true
            fieldsDidChange = true
        }

        if let title = self.title {
            item.title = title
            if let titleField = item.fields.filter(Predicates.key(in: FieldKeys.titles)).first {
                titleField.value = title
                titleField.changed = true
            }
            fieldsDidChange = true
        }

        if let abstract = self.abstract,
           let abstractField = item.fields.filter(Predicates.key(FieldKeys.abstract)).first {
            abstractField.value = abstract
            abstractField.changed = true
            fieldsDidChange = true
        }

        if fieldsDidChange {
            item.changedFields.insert(.fields)
        }

        for note in self.notes {
            guard note.changed,
                  let childNote = item.children.filter(Predicates.key(note.key)).first,
                  let noteField = childNote.fields.filter(Predicates.key(FieldKeys.note)).first else { continue }
            childNote.changedFields.insert(.fields)
            childNote.title = note.title
            noteField.value = note.text
            noteField.changed = true
        }
    }
}
