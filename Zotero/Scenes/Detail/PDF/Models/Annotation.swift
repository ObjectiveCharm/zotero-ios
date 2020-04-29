//
//  Annotation.swift
//  Zotero
//
//  Created by Michal Rentka on 29/04/2020.
//  Copyright © 2020 Corporation for Digital Scholarship. All rights reserved.
//

import UIKit

struct Annotation {
    enum Kind {
        case highlight, note, area
    }

    let key: String
    let type: Kind
    let page: Int
    let pageLabel: String
    let rects: [CGRect]
    let author: String
    let isAuthor: Bool
    let color: String
    let comment: String
    let text: String?
    let isLocked: Bool
    let sortIndex: String
    let dateModified: Date
    let tags: [Tag]

    var boundingBox: CGRect {
        if self.rects.count == 1, let boundingBox = self.rects.first {
            return boundingBox
        }

        var minX: CGFloat = 0.0
        var minY: CGFloat = 0.0
        var maxX: CGFloat = 0.0
        var maxY: CGFloat = 0.0

        for rect in self.rects {
            if rect.minX < minX {
                minX = rect.minX
            }
            if rect.minY < minY {
                minY = rect.minY
            }
            if rect.maxX > maxX {
                maxX = rect.maxX
            }
            if rect.maxY > maxY {
                maxY = rect.maxY
            }
        }

        return CGRect(x: minX, y: minY, width: (maxX - minX), height: (maxY - minY))
    }
}
