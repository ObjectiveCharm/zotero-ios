//
//  LinksResponse.swift
//  Zotero
//
//  Created by Michal Rentka on 08/02/2019.
//  Copyright © 2019 Corporation for Digital Scholarship. All rights reserved.
//

import Foundation

struct LinksResponse: Codable {
    let main: LinkResponse?
    let alternate: LinkResponse?
}

struct LinkResponse: Codable {
    let href: String
    let type: String
}
