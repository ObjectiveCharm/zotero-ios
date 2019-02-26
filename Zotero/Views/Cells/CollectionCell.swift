//
//  CollectionCell.swift
//  Zotero
//
//  Created by Michal Rentka on 14/02/2019.
//  Copyright © 2019 Corporation for Digital Scholarship. All rights reserved.
//

import UIKit

protocol CollectionCellModel {
    var name: String { get }
    var level: Int { get }
}

class CollectionCell: UITableViewCell {
    // Outlets
    @IBOutlet private weak var titleLabel: UILabel!
    @IBOutlet private weak var leftConstraint: NSLayoutConstraint!
    // Constants
    static let baseOffset: CGFloat = 20.0
    static let levelOffset: CGFloat = 20.0

    func setup(with model: CollectionCellModel) {
        self.titleLabel.text = model.name
        let offset = CollectionCell.baseOffset + (CGFloat(model.level) * CollectionCell.levelOffset)
        self.leftConstraint.constant = offset
        self.separatorInset = UIEdgeInsets(top: 0, left: offset - 3, bottom: 0, right: 0)
        self.layoutMargins = UIEdgeInsets(top: 0, left: offset - 3, bottom: 0, right: 0)
    }
}
