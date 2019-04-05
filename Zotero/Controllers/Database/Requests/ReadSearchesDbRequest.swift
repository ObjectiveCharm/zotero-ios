//
//  ReadSearchesDbRequest.swift
//  Zotero
//
//  Created by Michal Rentka on 26/02/2019.
//  Copyright © 2019 Corporation for Digital Scholarship. All rights reserved.
//

import Foundation

import RealmSwift

struct ReadSearchesDbRequest: DbResponseRequest {
    typealias Response = Results<RSearch>

    let libraryId: LibraryIdentifier

    var needsWrite: Bool { return false }

    func process(in database: Realm) throws -> Results<RSearch> {
        return database.objects(RSearch.self).filter(Predicates.notSyncState(.dirty, in: self.libraryId))
                                             .sorted(byKeyPath: "name")
    }
}
