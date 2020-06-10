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

enum StoreItemsError: Error {
    case itemDeleted(ItemResponse)
    case itemChanged(ItemResponse)
}

struct StoreItemsDbRequest: DbResponseRequest {
    typealias Response = [StoreItemsError]

    let response: [ItemResponse]
    unowned let schemaController: SchemaController
    unowned let dateParser: DateParser
    let preferRemoteData: Bool

    var needsWrite: Bool { return true }

    func process(in database: Realm) throws -> [StoreItemsError] {
        var errors: [StoreItemsError] = []
        for data in self.response {
            do {
                try self.store(data: data, to: database, schemaController: self.schemaController)
            } catch let error as StoreItemsError {
                errors.append(error)
            } catch let error {
                throw error
            }
        }
        return errors
    }

    private func store(data: ItemResponse, to database: Realm, schemaController: SchemaController) throws {
        guard let libraryId = data.library.libraryId else { throw DbError.primaryKeyUnavailable }

        let item: RItem
        if let existing = database.objects(RItem.self).filter(.key(data.key, in: libraryId)).first {
            item = existing
        } else {
            item = RItem()
            database.add(item)
        }

        if !self.preferRemoteData {
            if item.deleted {
                throw StoreItemsError.itemDeleted(data)
            }

            if item.isChanged {
                throw StoreItemsError.itemChanged(data)
            }
        }

        item.key = data.key
        item.rawType = data.rawType
        item.localizedType = self.schemaController.localized(itemType: data.rawType) ?? ""
        item.version = data.version
        item.trash = data.isTrash
        item.dateModified = data.dateModified
        item.dateAdded = data.dateAdded
        item.syncState = .synced
        item.syncRetries = 0
        item.lastSyncDate = Date(timeIntervalSince1970: 0)
        item.changeType = .sync

        if self.preferRemoteData {
            item.deleted = false
            item.resetChanges()
        }

        self.syncFields(data: data, item: item, database: database, schemaController: schemaController)
        try self.syncLibrary(identifier: libraryId, libraryName: data.library.name, item: item, database: database)
        self.syncParent(key: data.parentKey, libraryId: libraryId, item: item, database: database)
        self.syncCollections(keys: data.collectionKeys, libraryId: libraryId, item: item, database: database)
        try self.syncTags(data.tags, libraryId: libraryId, item: item, database: database)
        self.syncCreators(data: data, item: item, database: database)
        self.syncRelations(data: data, item: item, database: database)
        self.syncLinks(data: data, item: item, database: database)

        // Item title depends on item type, creators and fields, so we update derived titles (displayTitle and sortTitle) after everything else synced
        item.updateDerivedTitles()
    }

    private func syncFields(data: ItemResponse, item: RItem, database: Realm, schemaController: SchemaController) {
        let allFieldKeys = Array(data.fields.keys)

        let toRemove = item.fields.filter("NOT key IN %@", allFieldKeys)
        database.delete(toRemove)

        var date: String?
        var publisher: String?
        var publicationTitle: String?

        allFieldKeys.forEach { key in
            let value = data.fields[key] ?? ""
            var field: RItemField

            if let existing = item.fields.filter("key = %@", key).first {
                existing.value = value
                field = existing
            } else {
                field = RItemField()
                field.key = key
                field.baseKey = self.schemaController.baseKey(for: data.rawType, field: key)
                field.value = value
                field.item = item
                database.add(field)
            }

            if (field.key == FieldKeys.title || field.baseKey == FieldKeys.title) ||
               (key == FieldKeys.note && item.rawType == ItemTypes.note) {
                var title = value
                if key == FieldKeys.note {
                    title = title.notePreview ?? title
                }
                item.baseTitle = title
            } else if key == FieldKeys.date {
                date = field.value
            } else if field.key == FieldKeys.publisher || field.baseKey == FieldKeys.publisher {
                publisher = field.value
            } else if field.key == FieldKeys.publicationTitle || field.baseKey == FieldKeys.publicationTitle {
                publicationTitle = field.value
            }
        }

        item.setDateFieldMetadata(date, parser: self.dateParser)
        item.set(publisher: publisher)
        item.set(publicationTitle: publicationTitle)
    }

    private func syncLibrary(identifier: LibraryIdentifier, libraryName: String, item: RItem, database: Realm) throws {
        let (isNew, object) = try database.autocreatedLibraryObject(forPrimaryKey: identifier)
        if isNew {
            switch object {
            case .group(let object):
                object.name = libraryName
                object.syncState = .outdated
            case .custom: break
            }
        }
        item.libraryObject = object
    }

    private func syncParent(key: String?, libraryId: LibraryIdentifier, item: RItem, database: Realm) {
        item.parent = nil

        guard let key = key else { return }

        let parent: RItem

        if let existing = database.objects(RItem.self).filter(.key(key, in: libraryId)).first {
            parent = existing
        } else {
            parent = RItem()
            parent.key = key
            parent.syncState = .dirty
            parent.libraryObject = item.libraryObject
            database.add(parent)
        }

        item.parent = parent
        parent.updateMainAttachment()
    }

    private func syncCollections(keys: Set<String>, libraryId: LibraryIdentifier, item: RItem, database: Realm) {
        item.collections.removeAll()

        guard !keys.isEmpty else { return }

        var remainingCollections = keys
        let existingCollections = database.objects(RCollection.self).filter(.keys(keys, in: libraryId))

        for collection in existingCollections {
            item.collections.append(collection)
            remainingCollections.remove(collection.key)
        }

        for key in remainingCollections {
            let collection = RCollection()
            collection.key = key
            collection.syncState = .dirty
            collection.libraryObject = item.libraryObject
            database.add(collection)
            item.collections.append(collection)
        }
    }

    private func syncTags(_ tags: [TagResponse], libraryId: LibraryIdentifier, item: RItem, database: Realm) throws {
        var existingIndices: Set<Int> = []
        item.tags.forEach { tag in
            if let index = tags.firstIndex(where: { $0.tag == tag.name }) {
                existingIndices.insert(index)
            } else {
                if let index = tag.items.index(of: item) {
                    tag.items.remove(at: index)
                }
            }
        }

        for object in tags.enumerated() {
            guard !existingIndices.contains(object.offset) else { continue }
            let tag: RTag
            if let existing = database.objects(RTag.self).filter(.name(object.element.tag, in: libraryId)).first {
                tag = existing
            } else {
                tag = RTag()
                tag.name = object.element.tag
                tag.libraryObject = item.libraryObject
                database.add(tag)
            }
            tag.items.append(item)
        }
    }

    private func syncCreators(data: ItemResponse, item: RItem, database: Realm) {
        database.delete(item.creators)

        for object in data.creators.enumerated() {
            let firstName = object.element.firstName ?? ""
            let lastName = object.element.lastName ?? ""
            let name = object.element.name ?? ""

            let creator = RCreator()
            creator.rawType = object.element.creatorType
            creator.firstName = firstName
            creator.lastName = lastName
            creator.name = name
            creator.orderId = object.offset
            creator.primary = self.schemaController.creatorIsPrimary(creator.rawType, itemType: item.rawType)
            creator.item = item
            database.add(creator)
        }

        item.updateCreatorSummary()
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

    private func syncLinks(data: ItemResponse, item: RItem, database: Realm) {
        database.delete(item.links)

        guard let links = data.links else { return }

        if let link = links.`self` {
            self.syncLink(data: link, type: LinkType.`self`.rawValue, item: item, database: database)
        }
        if let link = links.up {
            self.syncLink(data: link, type: LinkType.up.rawValue, item: item, database: database)
        }
        if let link = links.alternate {
            self.syncLink(data: link, type: LinkType.alternate.rawValue, item: item, database: database)
        }
        if let link = links.enclosure {
            self.syncLink(data: link, type: LinkType.enclosure.rawValue, item: item, database: database)
        }
    }

    private func syncLink(data: LinkResponse, type: String, item: RItem, database: Realm) {
        let link = RLink()
        link.type = type
        link.contentType = data.type
        link.href = data.href
        link.title = data.title ?? ""
        link.length = data.length ?? 0
        link.item = item
        database.add(link)
    }
}
