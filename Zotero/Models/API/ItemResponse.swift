//
//  ItemResponse.swift
//  Zotero
//
//  Created by Michal Rentka on 08/02/2019.
//  Copyright © 2019 Corporation for Digital Scholarship. All rights reserved.
//

import Foundation

import CocoaLumberjackSwift

struct ItemResponse {
    let rawType: String
    let key: String
    let library: LibraryResponse
    let parentKey: String?
    let collectionKeys: Set<String>
    let links: LinksResponse?
    let parsedDate: String?
    let isTrash: Bool
    let version: Int
    let dateModified: Date
    let dateAdded: Date
    let fields: [String: String]
    let tags: [TagResponse]
    let creators: [CreatorResponse]
    let relations: [String: String]
    let inPublications: Bool
    let createdBy: UserResponse?
    let lastModifiedBy: UserResponse?

    init(rawType: String, key: String, library: LibraryResponse, parentKey: String?, collectionKeys: Set<String>, links: LinksResponse?,
         parsedDate: String?, isTrash: Bool, version: Int, dateModified: Date, dateAdded: Date, fields: [String: String], tags: [TagResponse],
         creators: [CreatorResponse], relations: [String: String], createdBy: UserResponse?, lastModifiedBy: UserResponse?) {
        self.rawType = rawType
        self.key = key
        self.library = library
        self.parentKey = parentKey
        self.collectionKeys = collectionKeys
        self.links = links
        self.parsedDate = parsedDate
        self.isTrash = isTrash
        self.version = version
        self.dateModified = dateModified
        self.dateAdded = dateAdded
        self.fields = fields
        self.tags = tags
        self.creators = creators
        self.relations = relations
        self.inPublications = false
        self.createdBy = createdBy
        self.lastModifiedBy = lastModifiedBy
    }

    init(response: [String: Any], schemaController: SchemaController) throws {
        let data: [String: Any] = try response.apiGet(key: "data")
        let itemType: String = try data.apiGet(key: "itemType")

        if !schemaController.itemTypes.contains(itemType) {
            throw SchemaError.unknownItemType(itemType)
        }

        let key: String = try response.apiGet(key: "key")
        let library = try LibraryResponse(response: (try response.apiGet(key: "library")))
        let linksData = response["links"] as? [String: Any]
        let links = try linksData.flatMap { try LinksResponse(response: $0) }
        let meta = response["meta"] as? [String: Any]
        let parsedDate = meta?["parsedDate"] as? String
        let createdByData = meta?["createdByUser"] as? [String: Any]
        let createdBy = try createdByData.flatMap { try UserResponse(response: $0) }
        let lastModifiedByData = meta?["lastModifiedByUser"] as? [String: Any]
        let lastModifiedBy = try lastModifiedByData.flatMap { try UserResponse(response: $0) }
        let version: Int = try response.apiGet(key: "version")

        switch itemType {
        case ItemTypes.annotation:
            try self.init(key: key, library: library, links: links, parsedDate: parsedDate, createdBy: createdBy, lastModifiedBy: lastModifiedBy,
                          version: version, annotationData: data, schemaController: schemaController)
        default:
            try self.init(key: key, rawType: itemType, library: library, links: links, parsedDate: parsedDate, createdBy: createdBy,
                          lastModifiedBy: lastModifiedBy, version: version, data: data, schemaController: schemaController)
        }
    }

    private init(key: String, rawType: String, library: LibraryResponse, links: LinksResponse?, parsedDate: String?, createdBy: UserResponse?,
                 lastModifiedBy: UserResponse?, version: Int, data: [String: Any], schemaController: SchemaController) throws {
        let dateAdded = data["dateAdded"] as? String
        let dateModified = data["dateModified"] as? String
        let tags = (data["tags"] as? [[String: Any]]) ?? []
        let creators = (data["creators"] as? [[String: Any]]) ?? []

        self.rawType = rawType
        self.key = key
        self.version = version
        self.collectionKeys = (data["collections"] as? [String]).flatMap(Set.init) ?? []
        self.parentKey = data["parentItem"] as? String
        self.dateAdded = dateAdded.flatMap({ Formatter.iso8601.date(from: $0) }) ?? Date()
        self.dateModified = dateModified.flatMap({ Formatter.iso8601.date(from: $0) }) ?? Date()
        self.parsedDate = parsedDate
        self.isTrash = (data["deleted"] as? Int) == 1
        self.library = library
        self.links = links
        self.tags = try tags.map({ try TagResponse(response: $0) })
        self.creators = try creators.map({ try CreatorResponse(response: $0) })
        self.relations = (data["relations"] as? [String: String]) ?? [:]
        self.inPublications = (data["inPublications"] as? Bool) ?? false
        self.fields = try ItemResponse.parseFields(from: data, rawType: rawType, key: key, schemaController: schemaController)
        self.createdBy = createdBy
        self.lastModifiedBy = lastModifiedBy
    }

    private init(key: String, library: LibraryResponse, links: LinksResponse?, parsedDate: String?, createdBy: UserResponse?,
                 lastModifiedBy: UserResponse?, version: Int, annotationData data: [String: Any], schemaController: SchemaController) throws {
        let dateAdded = data["dateAdded"] as? String
        let dateModified = data["dateModified"] as? String
        let tags = (data["tags"] as? [[String: Any]]) ?? []

        self.rawType = ItemTypes.annotation
        self.key = key
        self.version = version
        self.collectionKeys = []
        self.parentKey = try data.apiGet(key: "parentItem")
        self.dateAdded = dateAdded.flatMap({ Formatter.iso8601.date(from: $0) }) ?? Date()
        self.dateModified = dateModified.flatMap({ Formatter.iso8601.date(from: $0) }) ?? Date()
        self.parsedDate = parsedDate
        self.isTrash = (data["deleted"] as? Int) == 1
        self.library = library
        self.links = links
        self.tags = try tags.map({ try TagResponse(response: $0) })
        self.creators = []
        self.relations = [:]
        self.inPublications = false
        self.fields = try ItemResponse.parseFields(from: data, rawType: ItemTypes.annotation, key: key, schemaController: schemaController)
        self.createdBy = createdBy
        self.lastModifiedBy = lastModifiedBy
    }

    init(translatorResponse response: [String: Any], schemaController: SchemaController) throws {
        let key = KeyGenerator.newKey
        let rawType: String = try response.apiGet(key: "itemType")
        let accessDate = (response["accessDate"] as? String).flatMap({ Formatter.iso8601.date(from: $0) }) ?? Date()
        let tags = (response["tags"] as? [[String: Any]]) ?? []
        let creators = (response["creators"] as? [[String: Any]]) ?? []

        self.rawType = rawType
        self.key = key
        self.version = 0
        self.collectionKeys = []
        self.parentKey = nil
        self.dateAdded = accessDate
        self.dateModified = accessDate
        self.parsedDate = response["date"] as? String
        self.isTrash = false
        // We create a dummy library here, it's not returned by translation server, it'll be picked in the share extension
        self.library = LibraryResponse(id: 0, name: "", type: "", links: nil)
        self.links = nil
        self.tags = try tags.map({ try TagResponse(response: $0) })
        self.creators = try creators.map({ try CreatorResponse(response: $0) })
        self.relations = [:]
        self.inPublications = false
        // Translator returns some extra fields, which may not be recognized by schema, so we just ignore those
        self.fields = try ItemResponse.parseFields(from: response, rawType: rawType, key: key, schemaController: schemaController,
                                                   ignoreUnknownFields: true)
        self.createdBy = nil
        self.lastModifiedBy = nil
    }

    func copy(libraryId: LibraryIdentifier, collectionKeys: Set<String>) -> ItemResponse {
        return ItemResponse(rawType: self.rawType,
                            key: self.key,
                            library: LibraryResponse(libraryId: libraryId),
                            parentKey: self.parentKey,
                            collectionKeys: collectionKeys,
                            links: self.links,
                            parsedDate: self.parsedDate,
                            isTrash: self.isTrash,
                            version: self.version,
                            dateModified: self.dateModified,
                            dateAdded: self.dateAdded,
                            fields: self.fields,
                            tags: self.tags,
                            creators: self.creators,
                            relations: self.relations,
                            createdBy: self.createdBy,
                            lastModifiedBy: self.lastModifiedBy)
    }

    /// Parses field values from item data for given type.
    /// - parameter data: Data to parse.
    /// - parameter rawType: Raw item type of parsed item.
    /// - parameter schemaController: Schema controller to check fields against schema.
    /// - parameter key: Key of item.
    /// - parameter ignoreUnknownFields: If set to `false`, when an unknown field is encountered during parsing, an exception `Error.unknownField` is thrown. Otherwise the field is silently ignored and parsing continues.
    /// - returns: Parsed dictionary of fields with their values.
    private static func parseFields(from data: [String: Any], rawType: String, key: String, schemaController: SchemaController,
                                    ignoreUnknownFields: Bool = false) throws -> [String: String] {
        let excludedKeys = FieldKeys.Item.knownNonFieldKeys
        var fields: [String: String] = [:]

        guard let schemaFields = schemaController.fields(for: rawType) else { throw SchemaError.missingFieldsForItemType(rawType) }

        for object in data {
            guard !excludedKeys.contains(object.key) else { continue }

            if !self.isKnownField(object.key, in: schemaFields, itemType: rawType) {
                if ignoreUnknownFields {
                    continue
                }
                throw SchemaError.unknownField(key: key, field: object.key)
            }

            fields[object.key] = object.value as? String
        }

        return fields
    }

    /// Checks whether given field is a known field for given item type.
    /// - parameter field: Field to check.
    /// - parameter schema: Schema for given item type.
    /// - parameter itemType: Raw item type of item.
    /// - returns: `true` if field is a known field for given item, `false` otherwise.
    private static func isKnownField(_ field: String, in schema: [FieldSchema], itemType: String) -> Bool {
        // Note is not a field stored in schema but we consider it as one, since it can be returned with fields together with other data.
        if field == FieldKeys.Item.note || schema.contains(where: { $0.field == field }) { return true }

        switch itemType {
        case ItemTypes.annotation:
            // Annotations don't have some fields that are returned by backend in schema, so we have to filter them out here manually.
            switch field {
            case FieldKeys.Item.Annotation.color,
                 FieldKeys.Item.Annotation.comment,
                 FieldKeys.Item.Annotation.pageLabel,
                 FieldKeys.Item.Annotation.position,
                 FieldKeys.Item.Annotation.text,
                 FieldKeys.Item.Annotation.type,
                 FieldKeys.Item.Annotation.sortIndex:
                return true
            default:
                return false
            }
        case ItemTypes.attachment:
            // Attachments don't have some fields that are returned by backend in schema, so we have to filter them out here manually.
            switch field {
            case FieldKeys.Item.Attachment.contentType,
                 FieldKeys.Item.Attachment.md5,
                 FieldKeys.Item.Attachment.mtime,
                 FieldKeys.Item.Attachment.filename,
                 FieldKeys.Item.Attachment.linkMode,
                 FieldKeys.Item.Attachment.charset:
                return true
            default:
                return false
            }
        default:
            // Field not found in schema and is not a special case.
            return false
        }
    }
}

struct TagResponse {
    let tag: String

    init(response: [String: Any]) throws {
        self.tag = try response.apiGet(key: "tag")
    }
}

struct CreatorResponse {
    let creatorType: String
    let firstName: String?
    let lastName: String?
    let name: String?

    init(response: [String: Any]) throws {
        self.creatorType = try response.apiGet(key: "creatorType")
        self.firstName = response["firstName"] as? String
        self.lastName = response["lastName"] as? String
        self.name = response["name"] as? String
    }
}

struct RelationResponse {

}

struct UserResponse {
    let id: Int
    let name: String
    let username: String

    init(response: [String: Any]) throws {
        self.id = try response.apiGet(key: "id")
        self.name = try response.apiGet(key: "name")
        self.username = try response.apiGet(key: "username")
    }
}
