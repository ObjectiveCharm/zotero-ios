//
//  UICollectionViewListCell+Extensions.swift
//  Zotero
//
//  Created by Michal Rentka on 02.08.2022.
//  Copyright © 2022 Corporation for Digital Scholarship. All rights reserved.
//

import UIKit

extension UIView {
    func add(contentView view: UIView) {
        view.translatesAutoresizingMaskIntoConstraints = false
        self.addSubview(view)

        let constraint = self.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        constraint.priority = UILayoutPriority(999)

        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: self.leadingAnchor),
            self.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            self.topAnchor.constraint(equalTo: view.topAnchor),
            constraint
        ])
    }
}
