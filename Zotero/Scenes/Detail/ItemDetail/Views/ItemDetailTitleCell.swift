//
//  ItemDetailTitleCell.swift
//  Zotero
//
//  Created by Michal Rentka on 10/02/2020.
//  Copyright © 2020 Corporation for Digital Scholarship. All rights reserved.
//

import UIKit

import RxCocoa
import RxSwift

class ItemDetailTitleCell: RxTableViewCell {
    @IBOutlet private weak var label: UILabel!
    @IBOutlet private weak var textField: UITextField!
    @IBOutlet private weak var separatorLeft: NSLayoutConstraint!

    var textObservable: ControlProperty<String> {
        return self.textField.rx.text.orEmpty
    }

    func setup(with title: String, isEditing: Bool) {
        self.separatorLeft.constant = self.separatorInset.left
        if isEditing {
            self.textField.text = title
        } else {
            self.label.text = title
        }
        self.textField.isHidden = !isEditing
        self.label.isHidden = isEditing
    }
}
