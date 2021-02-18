//
//  SettingsResponse.swift
//  Zotero
//
//  Created by Michal Rentka on 26/02/2019.
//  Copyright © 2019 Corporation for Digital Scholarship. All rights reserved.
//

import Foundation

struct SettingsResponse {
    let tagColors: TagColorsResponse?
    let pageIndices: PageIndicesResponse

    init(response: Any) throws {
        guard let json = response as? [String: Any] else {
            throw Parsing.Error.notDictionary
        }
        self.tagColors = try (json["tagColors"] as? [String: Any]).flatMap({ try TagColorsResponse(response: $0) })
        self.pageIndices = try PageIndicesResponse(response: json)
    }
}

struct PageIndicesResponse {
    let indices: [PageIndexResponse]

    init(response: [String: Any]) throws {
        self.indices = try response.compactMap({ try PageIndexResponse(key: $0.key, data: $0.value) })
    }
}

struct PageIndexResponse {
    let key: String
    let value: Int
    let version: Int

    init?(key: String, data: Any) throws {
        guard key.contains("lastPageIndex") else { return nil }
        guard let dictionary = data as? [String: Any] else {
            throw Parsing.Error.notDictionary
        }

        let parts = key.split(separator: "_")
        guard parts.count == 3 else { throw Parsing.Error.incompatibleValue(key) }

        self.key = String(parts[2])
        self.value = try Parsing.parse(key: "value", from: dictionary)
        self.version = try Parsing.parse(key: "version", from: dictionary)
    }
}

struct TagColorsResponse {
    let value: [TagColorResponse]

    init(response: [String: Any]) throws {
        let responses: [[String: Any]] = try Parsing.parse(key: "value", from: response)
        self.value = try responses.map({ try TagColorResponse(response: $0) })
    }
}

struct TagColorResponse {
    let name: String
    let color: String

    init(response: [String: Any]) throws {
        self.name = try Parsing.parse(key: "name", from: response)
        self.color = try Parsing.parse(key: "color", from: response)
    }
}
