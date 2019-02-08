//
//  ObjectsRequest.swift
//  Zotero
//
//  Created by Michal Rentka on 07/02/2019.
//  Copyright © 2019 Corporation for Digital Scholarship. All rights reserved.
//

import Foundation

struct ObjectsRequest: ApiRequest {
    let groupType: SyncGroupType
    let objectType: SyncObjectType
    let keys: [Any]

    var path: String {
        if self.objectType == .group, let key = self.keys.first {
            return "groups/\(key)"
        }
        return "\(self.groupType.apiPath)/\(self.objectType.apiPath)"
    }

    var httpMethod: ApiHttpMethod {
        return .get
    }

    var encoding: ApiParameterEncoding {
        return .url
    }

    var parameters: [String : Any]? {
        switch self.objectType {
        case .group:
            return nil
        case .collection:
            return ["collectionKey": self.keys]
        case .item, .trash:
            return ["itemKey": self.keys]
        case .search:
            return ["searchKey": self.keys]
        }
    }
}
