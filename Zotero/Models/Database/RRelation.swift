//
//  RRelation.swift
//  Zotero
//
//  Created by Michal Rentka on 09/06/2020.
//  Copyright © 2020 Corporation for Digital Scholarship. All rights reserved.
//

import Foundation

import RealmSwift

final class RRelation: Object {
    @Persisted var type: String
    @Persisted var urlString: String
    @Persisted var item: RItem?
}
