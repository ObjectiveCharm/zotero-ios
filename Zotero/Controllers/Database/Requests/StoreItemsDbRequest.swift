//
//  StoreItemsDbRequest.swift
//  Zotero
//
//  Created by Michal Rentka on 08/02/2019.
//  Copyright © 2019 Corporation for Digital Scholarship. All rights reserved.
//

import Foundation

import CocoaLumberjack
import RealmSwift

struct StoreItemsDbRequest: DbRequest {
    let response: [ItemResponse]
    let trash: Bool

    var needsWrite: Bool { return true }

    func process(in database: Realm) throws {
        for data in self.response {
            try self.store(data: data, to: database)
        }
    }

    private func store(data: ItemResponse, to database: Realm) throws {
        let item: RItem
        if let existing = database.objects(RItem.self)
                                  .filter("key = %@ AND library.identifier = %d", data.key,
                                                                                  data.library.libraryId).first {
            item = existing
        } else {
            item = RItem()
            database.add(item)
        }

        item.key = data.key
        item.rawType = data.type.rawValue
        item.creatorSummary = data.creatorSummary ?? ""
        item.parsedDate = data.parsedDate ?? ""
        item.version = data.version
        item.trash = data.isTrash
        item.dateModified = data.dateModified
        item.dateAdded = data.dateAdded
        item.needsSync = false

        self.syncFields(data: data, item: item, database: database)
        try self.syncLibrary(data: data, item: item, database: database)
        self.syncParent(data: data, item: item, database: database)
        self.syncCollections(data: data, item: item, database: database)
        try self.syncTags(data: data, item: item, database: database)
        self.syncCreators(data: data, item: item, database: database)
        self.syncRelations(data: data, item: item, database: database)
    }

    private func syncFields(data: ItemResponse, item: RItem, database: Realm) {
        let titleKeys = RItem.titleKeys
        let allFieldKeys = Array(data.fields.keys)
        let toRemove = item.fields.filter("NOT key IN %@", allFieldKeys)
        database.delete(toRemove)
        allFieldKeys.forEach { key in
            let value = data.fields[key] ?? ""
            if let existing = item.fields.filter("key = %@", key).first {
                existing.value = value
            } else {
                let field = RItemField()
                field.key = key
                field.value = value
                field.item = item
                database.add(field)
            }
            if titleKeys.contains(key) {
                var title = value
                if key == "note" {
                    title = StoreItemsDbRequest.stripHtml(from: title) ?? title
                }
                item.title = title
            }
        }
    }

    private func syncLibrary(data: ItemResponse, item: RItem, database: Realm) throws {
        let libraryData = try database.autocreatedObject(ofType: RLibrary.self, forPrimaryKey: data.library.libraryId)
        if libraryData.0 {
            libraryData.1.needsSync = true
        }
        item.library = libraryData.1
    }

    private func syncParent(data: ItemResponse, item: RItem, database: Realm) {
        item.parent = nil
        if let key = data.parentKey {
            let parent: RItem
            if let existing = database.objects(RItem.self)
                                      .filter("library.identifier = %d AND key = %@", data.library.libraryId,
                                                                                      key).first {
                parent = existing
            } else {
                parent = RItem()
                parent.key = key
                parent.needsSync = true
                parent.library = item.library
                database.add(parent)
            }
            item.parent = parent
        }
    }

    private func syncCollections(data: ItemResponse, item: RItem, database: Realm) {
        item.collections.removeAll()
        if !data.collectionKeys.isEmpty {
            var remainingCollections = data.collectionKeys
            let existingCollections = database.objects(RCollection.self)
                                              .filter("library.identifier = %d AND key IN %@", data.library.libraryId,
                                                                                               data.collectionKeys)

            for collection in existingCollections {
                item.collections.append(collection)
                remainingCollections.remove(collection.key)
            }

            for key in remainingCollections {
                let collection = RCollection()
                collection.key = key
                collection.needsSync = true
                collection.library = item.library
                database.add(collection)
                item.collections.append(collection)
            }
        }
    }

    private func syncTags(data: ItemResponse, item: RItem, database: Realm) throws {
        var existingIndices: Set<Int> = []
        item.tags.forEach { tag in
            if let index = data.tags.index(where: { $0.tag == tag.name }) {
                existingIndices.insert(index)
            } else {
                if let index = tag.items.index(of: item) {
                    tag.items.remove(at: index)
                }
            }
        }

        for object in data.tags.enumerated() {
            guard !existingIndices.contains(object.offset) else { continue }
            let tag: RTag
            if let existing = database.objects(RTag.self).filter("library.identifier = %d" +
                                                                 " AND name = %@", data.library.libraryId,
                                                                                   object.element.tag).first {
                tag = existing
            } else {
                tag = RTag()
                tag.name = object.element.tag
                tag.library = item.library
                database.add(tag)
            }
            tag.items.append(item)
        }
    }

    private func syncCreators(data: ItemResponse, item: RItem, database: Realm) {
        var existingIndices: Set<Int> = []
        item.creators.forEach { creator in
            let responseIndex = data.creators.index(where: { response in
                return response.creatorType == creator.rawType &&
                       (response.firstName ?? "") == creator.firstName &&
                       (response.lastName ?? "") == creator.lastName &&
                       (response.name ?? "") == creator.name
            })

            if let index = responseIndex {
                existingIndices.insert(index)
            } else {
                if let index = creator.items.index(of: item) {
                    creator.items.remove(at: index)
                }
            }
        }

        for object in data.creators.enumerated() {
            guard !existingIndices.contains(object.offset) else { continue }

            let firstName = object.element.firstName ?? ""
            let lastName = object.element.lastName ?? ""
            let name = object.element.name ?? ""

            let creator: RCreator
            if let existing = database.objects(RCreator.self)
                                      .filter("rawType = %@ AND firstName = %@ " +
                                              "AND lastName = %@ AND name = %@", object.element.creatorType, firstName,
                                                                                 lastName, name).first {
                creator = existing
            } else {
                creator = RCreator()
                creator.rawType = object.element.creatorType
                creator.firstName = firstName
                creator.lastName = lastName
                creator.name = name
                database.add(creator)
            }
            creator.items.append(item)
        }
    }

    private func syncRelations(data: ItemResponse, item: RItem, database: Realm) {
        let allKeys = Array(data.relations.keys)
        let toRemove = item.relations.filter("NOT type IN %@", allKeys)
        database.delete(toRemove)

        allKeys.forEach { key in
            let relation: RRelation
            if let existing = item.relations.filter("type = %@", key).first {
                relation = existing
            } else {
                relation = RRelation()
                relation.type = key
                relation.item = item
                database.add(relation)
            }
            relation.urlString = data.relations[key] ?? ""
        }
    }

    private static let stripCharacters = CharacterSet(charactersIn: "\t\r\n")

    private static func stripHtml(from string: String) -> String? {
        guard !string.isEmpty else { return nil }
        guard let data = string.data(using: .utf8) else {
            DDLogError("StoreItemsDbRequest: could not create data from string: \(string)")
            return nil
        }

        do {
            let attributed = try NSAttributedString(data: data,
                                                    options: [.documentType : NSAttributedString.DocumentType.html],
                                                    documentAttributes: nil)
            var stripped = attributed.string.trimmingCharacters(in: CharacterSet.whitespaces)
                                            .components(separatedBy: StoreItemsDbRequest.stripCharacters).joined()
            if stripped.count > 200 {
                let endIndex = stripped.index(stripped.startIndex, offsetBy: 200)
                stripped = String(stripped[stripped.startIndex..<endIndex])
            }
            return stripped
        } catch let error {
            DDLogError("StoreItemsDbRequest: can't strip HTML tags: \(error)")
            DDLogError("Original string: \(string)")
        }

        return nil
    }
}
