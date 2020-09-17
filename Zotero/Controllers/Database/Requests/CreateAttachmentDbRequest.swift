//
//  CreateAttachmentDbRequest.swift
//  Zotero
//
//  Created by Michal Rentka on 07/08/2019.
//  Copyright © 2019 Corporation for Digital Scholarship. All rights reserved.
//

import Foundation

import RealmSwift

struct CreateAttachmentDbRequest: DbResponseRequest {
    typealias Response = RItem

    let attachment: Attachment
    let localizedType: String
    let collections: Set<String>
    let linkMode: LinkMode

    var needsWrite: Bool { return true }

    func process(in database: Realm) throws -> RItem {
        let attachmentKeys = FieldKeys.Item.Attachment.fieldKeys

        // Basic info

        let item = RItem()
        item.key = self.attachment.key
        item.rawType = ItemTypes.attachment
        item.localizedType = self.localizedType
        item.syncState = .synced
        item.set(title: self.attachment.title)
        // We need to submit tags on creation even if they are empty, so we need to mark them as changed
        item.changedFields = [.type, .fields, .tags]
        item.changeType = .user
        item.attachmentNeedsSync = true
        item.dateAdded = Date()
        item.dateModified = Date()

        // Library

        switch self.attachment.libraryId {
        case .custom(let type):
            let library = database.object(ofType: RCustomLibrary.self, forPrimaryKey: type.rawValue)
            item.customLibrary = library
        case .group(let identifier):
            let group = database.object(ofType: RGroup.self, forPrimaryKey: identifier)
            item.group = group
        }

        database.add(item)

        // Fields

        for fieldKey in attachmentKeys {
            let field = RItemField()
            field.key = fieldKey
            field.baseKey = nil

            switch self.attachment.contentType {
            case .file(let file, let filename, _):
                switch fieldKey {
                case FieldKeys.Item.title:
                    field.value = self.attachment.title
                case FieldKeys.Item.Attachment.filename:
                    field.value = filename
                case FieldKeys.Item.Attachment.contentType:
                    field.value = file.mimeType
                case FieldKeys.Item.Attachment.linkMode:
                    field.value = self.linkMode.rawValue
                case FieldKeys.Item.Attachment.md5:
                    field.value = md5(from: file.createUrl()) ?? ""
                case FieldKeys.Item.Attachment.mtime:
                    let modificationTime = Int(round(Date().timeIntervalSince1970 * 1000))
                    field.value = "\(modificationTime)"
                default:
                    continue
                }

            case .url(let url):
                switch fieldKey {
                case FieldKeys.Item.Attachment.url:
                    field.value = url.absoluteString
                case FieldKeys.Item.Attachment.linkMode:
                    field.value = "linked_url"
                default:
                    continue
                }
            }

            field.changed = true
            field.item = item
            database.add(field)
        }

        // Collections

        let libraryObject = item.libraryObject

        self.collections.forEach { key in
            let collection = RCollection()
            collection.key = key
            collection.syncState = .dirty
            collection.libraryObject = libraryObject
            database.add(collection)
            item.collections.append(collection)
        }

        if !self.collections.isEmpty {
            item.changedFields.insert(.collections)
        }

        return item
    }
}
