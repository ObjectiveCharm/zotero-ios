//
//  LibrariesState.swift
//  Zotero
//
//  Created by Michal Rentka on 27/02/2020.
//  Copyright © 2020 Corporation for Digital Scholarship. All rights reserved.
//

import Foundation

import RealmSwift

struct LibrariesState: ViewModelState {
    var customLibraries: Results<RCustomLibrary>?
    var groupLibraries: Results<RGroup>?
    var error: LibrariesError?

    var librariesToken: NotificationToken?
    var groupsToken: NotificationToken?

    mutating func cleanup() {
        self.error = nil
    }
}
