//
//  ItemCell.swift
//  Zotero
//
//  Created by Michal Rentka on 17/10/2019.
//  Copyright © 2019 Corporation for Digital Scholarship. All rights reserved.
//

import UIKit

class ItemCell: UITableViewCell {
    @IBOutlet private weak var typeImageView: UIImageView!
    @IBOutlet private weak var titleLabel: UILabel!
    @IBOutlet private weak var subtitleLabel: UILabel!
    @IBOutlet private weak var tagCircles: TagCirclesView!
    @IBOutlet private weak var noteIcon: UIImageView!
    @IBOutlet private weak var fileView: FileAttachmentView!

    private var key: String = ""
    private var tapAction: ((String, FileAttachmentView.State) -> Void)?

    override func awakeFromNib() {
        super.awakeFromNib()

        self.titleLabel.font = UIFont.preferredFont(for: .headline, weight: .regular)
        self.fileView.contentInsets = UIEdgeInsets(top: 8, left: 8, bottom: 8, right: 15)
        self.fileView.tapAction = { [weak self] in
            guard let `self` = self else { return }
            self.tapAction?(self.key, self.fileView.state)
        }
    }

    func set(item: ItemCellModel, tapAction: @escaping (String, FileAttachmentView.State) -> Void) {
        self.tapAction = tapAction
        self.key = item.key

        self.typeImageView.image = UIImage(named: item.typeIconName)
        self.titleLabel.text = item.title.isEmpty ? " " : item.title
        self.subtitleLabel.text = item.subtitle.isEmpty ? " " : item.subtitle
        self.subtitleLabel.isHidden = item.subtitle.isEmpty && (item.hasNote || !item.tagColors.isEmpty)
        self.noteIcon.isHidden = !item.hasNote

        self.tagCircles.isHidden = item.tagColors.isEmpty
        if !self.tagCircles.isHidden {
            self.tagCircles.colors = item.tagColors
        }

        if let data = item.fileData {
            self.fileView.set(data: data)
            self.fileView.isHidden = false
        } else {
            self.fileView.isHidden = true
        }
    }

    func update(progress: CGFloat) {
        self.fileView.set(progress: progress)
    }
}
