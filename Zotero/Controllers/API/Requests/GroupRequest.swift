//
//  GroupRequest.swift
//  Zotero
//
//  Created by Michal Rentka on 05/02/2019.
//  Copyright © 2019 Corporation for Digital Scholarship. All rights reserved.
//

import Foundation

struct GroupRequest: ApiRequest {
    typealias Response = GroupResponse

    let identifier: Int
    let version: Int

    var path: String {
        return "groups/\(self.identifier)"
    }

    var httpMethod: ApiHttpMethod {
        return .get
    }

    var encoding: ApiParameterEncoding {
        return .url
    }

    var parameters: [String : Any]? {
        return ["since": self.version]
    }
}
