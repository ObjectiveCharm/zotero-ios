//
//  ReadStylesDbRequest.swift
//  Zotero
//
//  Created by Michal Rentka on 18.05.2021.
//  Copyright © 2021 Corporation for Digital Scholarship. All rights reserved.
//

import Foundation

import RealmSwift

struct ReadStylesDbRequest: DbResponseRequest {
    typealias Response = Results<RStyle>

    var needsWrite: Bool { return false }

    func process(in database: Realm) throws -> Results<RStyle> {
        return database.objects(RStyle.self).sorted(byKeyPath: "title")
    }
}

struct ReadInstalledStylesDbRequest: DbResponseRequest {
    typealias Response = Results<RStyle>

    var needsWrite: Bool { return false }

    func process(in database: Realm) throws -> Results<RStyle> {
        return database.objects(RStyle.self).filter("installed = true").sorted(byKeyPath: "title")
    }
}
