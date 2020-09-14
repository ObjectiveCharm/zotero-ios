//
//  AuthorizeUploadResponse.swift
//  Zotero
//
//  Created by Michal Rentka on 18/07/2019.
//  Copyright © 2019 Corporation for Digital Scholarship. All rights reserved.
//

import Foundation

enum AuthorizeUploadResponse {
    case exists
    case new(AuthorizeNewUploadResponse)

    init(from jsonObject: Any) throws {
        guard let data = jsonObject as? [String: Any] else {
            throw Parsing.Error.notDictionary
        }

        if data["exists"] != nil {
            self = .exists
        } else {
            self = try .new(AuthorizeNewUploadResponse(from: data))
        }
    }
}

struct AuthorizeNewUploadResponse {
    let url: URL
    let uploadKey: String
    let params: [String: String]

    init(from jsonObject: [String: Any]) throws {
        let urlString: String = try jsonObject.apiGet(key: "url")

        guard let url = URL(string: urlString.replacingOccurrences(of: "\\", with: "")) else {
            throw Parsing.Error.missingKey("url")
        }

        self.url = url
        self.uploadKey = try jsonObject.apiGet(key: "uploadKey")
        self.params = try jsonObject.apiGet(key: "params")
    }
}
