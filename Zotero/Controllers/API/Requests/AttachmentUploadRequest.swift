//
//  AttachmentUploadRequest.swift
//  Zotero
//
//  Created by Michal Rentka on 18/07/2019.
//  Copyright © 2019 Corporation for Digital Scholarship. All rights reserved.
//

import Foundation

struct AttachmentUploadRequest: ApiUploadRequest {
    let url: URL

    var httpMethod: ApiHttpMethod { return .post }

    var headers: [String : String]? {
        return ["If-None-Match": "*"]
    }
}
