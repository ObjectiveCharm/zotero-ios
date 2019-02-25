//
//  ItemResponse.swift
//  Zotero
//
//  Created by Michal Rentka on 08/02/2019.
//  Copyright © 2019 Corporation for Digital Scholarship. All rights reserved.
//

import Foundation

import CocoaLumberjack
import DictionaryDecoder

enum ItemResponseError: Error {
    case notArray
    case missingKey(String)
    case unknownType(String)
}

struct ItemResponse {
    enum ItemType: String {
        case artwork
        case attachment
        case audioRecording
        case book
        case bookSection
        case bill
        case blogPost
        case `case`
        case computerProgram
        case conferencePaper
        case dictionaryEntry
        case document
        case email
        case encyclopediaArticle
        case film
        case forumPost
        case hearing
        case instantMessage
        case interview
        case journalArticle
        case letter
        case magazineArticle
        case map
        case manuscript
        case note
        case newspaperArticle
        case patent
        case podcast
        case presentation
        case radioBroadcast
        case report
        case statute
        case thesis
        case tvBroadcast
        case videoRecording
        case webpage
    }

    let type: ItemType
    let key: String
    let library: LibraryResponse
    let parentKey: String?
    let collectionKeys: Set<String>
    let links: LinksResponse
    let isTrash: Bool
    let version: Int
    let fields: [String: String]
    let tags: [TagResponse]
    let creators: [CreatorResponse]

    private static var notFieldKeys: Set<String> = {
        return ["creators", "itemType", "version", "key", "tags",
                "collections", "relations", "dateAdded", "dateModified"]
    }()

    init(response: [String: Any]) throws {
        let data: [String: Any] = try ItemResponse.parse(key: "data", from: response)
        let rawType: String = try ItemResponse.parse(key: "itemType", from: data)
        guard let type = ItemType(rawValue: rawType) else {
            throw ZoteroApiError.jsonDecoding(ItemResponseError.unknownType(rawType))
        }

        self.type = type
        self.key = try ItemResponse.parse(key: "key", from: response)
        self.version = try ItemResponse.parse(key: "version", from: response)
        let collections = data["collections"] as? [String]
        self.collectionKeys = collections.flatMap(Set.init) ?? []
        self.parentKey = data["parentItem"] as? String

        let deleted = data["deleted"] as? Int
        self.isTrash = deleted == 1

        let decoder = DictionaryDecoder()
        let libraryData: [String: Any] = try ItemResponse.parse(key: "library", from: response)
        self.library = try decoder.decode(LibraryResponse.self, from: libraryData)
        let linksData: [String: Any] = try ItemResponse.parse(key: "links", from: response)
        self.links = try decoder.decode(LinksResponse.self, from: linksData)
        let tagsData: [[String: Any]] = try ItemResponse.parse(key: "tags", from: data)
        self.tags = try tagsData.map({ try decoder.decode(TagResponse.self, from: $0) })
        let creatorsData: [[String: Any]]? = data["creators"] as? [[String: Any]]
        if let data = creatorsData {
            self.creators = try data.map({ try decoder.decode(CreatorResponse.self, from: $0) })
        } else {
            self.creators = []
        }

        let excludedKeys = ItemResponse.notFieldKeys
        var fields: [String: String] = [:]
        data.forEach { data in
            if !excludedKeys.contains(data.key) {
                fields[data.key] = data.value as? String
            }
        }
        self.fields = fields
    }

    static func decode(response: Any) throws -> ([ItemResponse], [Error]) {
        guard let array = response as? [[String: Any]] else {
            throw ZoteroApiError.jsonDecoding(ItemResponseError.notArray)
        }

        var items: [ItemResponse] = []
        var errors: [Error] = []
        array.forEach { data in
            do {
                let item = try ItemResponse(response: data)
                items.append(item)
            } catch let error {
                errors.append(error)
            }
        }
        return (items, errors)
    }

    private static func parse<T>(key: String, from data: [String: Any]) throws -> T {
        guard let parsed = data[key] as? T else {
            throw ZoteroApiError.jsonDecoding(ItemResponseError.missingKey(key))
        }
        return parsed
    }
}

struct TagResponse: Decodable {
    let tag: String
}

struct CreatorResponse: Decodable {
    let creatorType: String
    let firstName: String
    let lastName: String
}
