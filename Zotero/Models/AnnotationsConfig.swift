//
//  AnnotationsConfig.swift
//  Zotero
//
//  Created by Michal Rentka on 12/05/2020.
//  Copyright © 2020 Corporation for Digital Scholarship. All rights reserved.
//

import UIKit

#if PDFENABLED
import PSPDFKit
#endif

struct AnnotationsConfig {
    static let defaultActiveColor = "#ff8c19"
    static let colors: [String] = ["#ff6666", "#ff8c19", "#5fb236", "#2ea8e5", "#a28ae5"]

    static let isZoteroKey = "isZoteroAnnotation"
    static let keyKey = "zoteroKey"
    static let baseColorKey = "zoteroBaseColor"

    #if PDFENABLED
    static let supported: PSPDFKit.Annotation.Kind = [.note, .highlight, .square]
    #endif
}
