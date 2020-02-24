//
//  CollectionsState.swift
//  Zotero
//
//  Created by Michal Rentka on 24/02/2020.
//  Copyright © 2020 Corporation for Digital Scholarship. All rights reserved.
//

import Foundation

import RealmSwift

typealias CollectionStateEditingData = (String?, String, Collection?)

struct CollectionsState: ViewModelState {
    struct Changes: OptionSet {
        typealias RawValue = UInt8

        let rawValue: UInt8

        static let results = Changes(rawValue: 1 << 0)
        static let selection = Changes(rawValue: 1 << 1)
    }

    enum EditingType {
        case add
        case addSubcollection(Collection)
        case edit(Collection)
    }

    let library: Library

    var selectedCollection: Collection
    var collections: [Collection]
    var editingData: CollectionStateEditingData?
    var changes: Changes
    var error: CollectionsError?

    init(library: Library, collections: [Collection], error: CollectionsError?) {
        self.library = library
        self.selectedCollection = collections.first ?? Collection(custom: .all)
        self.collections = collections
        self.changes = []
        self.error = error
    }

    mutating func cleanup() {
        self.error = nil
        self.editingData = nil
        self.changes = []
    }
}
