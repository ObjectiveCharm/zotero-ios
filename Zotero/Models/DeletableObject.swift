//
//  DeletableObject.swift
//  Zotero
//
//  Created by Michal Rentka on 06/05/2019.
//  Copyright © 2019 Corporation for Digital Scholarship. All rights reserved.
//

import Foundation

import RealmSwift

typealias DeletableObject = Deletable&Object

protocol Deletable: class {
    var deleted: Bool { get set }

    func removeChildren(in database: Realm)
}

extension RCollection: Deletable {
    func removeChildren(in database: Realm) {
        self.children.forEach { child in
            child.removeChildren(in: database)
        }
        database.delete(self.children)
    }
}
extension RItem: Deletable {
    func removeChildren(in database: Realm) {
        self.children.forEach { child in
            child.removeChildren(in: database)
        }
        database.delete(self.children)
    }
}
extension RSearch: Deletable {
    func removeChildren(in database: Realm) {}
}
