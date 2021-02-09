//
//  Conflict.swift
//  Zotero
//
//  Created by Michal Rentka on 03/04/2020.
//  Copyright © 2020 Corporation for Digital Scholarship. All rights reserved.
//

import Foundation

enum Conflict {
    case groupRemoved(Int, String)
    case groupWriteDenied(Int, String)
    case objectsRemoved(libraryId: LibraryIdentifier, collections: [String], items: [String], searches: [String], tags: [String], version: Int)
}
