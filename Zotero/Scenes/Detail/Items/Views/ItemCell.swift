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
    @IBOutlet private weak var titleLabelsToContainerBottom: NSLayoutConstraint!
    @IBOutlet private weak var subtitleLabel: UILabel!
    @IBOutlet private weak var fakeSubtitleLabel: UILabel!
    @IBOutlet private weak var tagCircles: TagCirclesView!
    @IBOutlet private weak var noteIcon: UIImageView!
    @IBOutlet private weak var fileView: FileAttachmentView!

    var key: String = ""
    private var tagBorderColor: CGColor {
        return self.traitCollection.userInterfaceStyle == .dark ? UIColor.black.cgColor : UIColor.white.cgColor
    }
    private var highlightColor: UIColor? {
        return self.isEditing ? self.multipleSelectionBackgroundView?.backgroundColor :
                                self.selectedBackgroundView?.backgroundColor
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        self.fileView.tapAction = nil
        self.key = ""
    }

    override func awakeFromNib() {
        super.awakeFromNib()

        let font = UIFont.preferredFont(for: .headline, weight: .regular)
        self.titleLabel.font = font
        self.titleLabelsToContainerBottom.constant = 12  + (1 / UIScreen.main.scale) // +(1/scale) is for bottom separator
        self.fileView.contentInsets = UIEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        self.tagCircles.borderColor = self.tagBorderColor

        self.separatorInset = UIEdgeInsets(top: 0, left: 64, bottom: 0, right: 0)
        
        let highlightView = UIView()
        highlightView.backgroundColor = Asset.Colors.cellHighlighted.color
        self.selectedBackgroundView = highlightView

        let selectionView = UIView()
        selectionView.backgroundColor = Asset.Colors.cellSelected.color
        self.multipleSelectionBackgroundView = selectionView
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)

        if previousTraitCollection?.userInterfaceStyle != self.traitCollection.userInterfaceStyle {
            self.tagCircles.borderColor = self.tagBorderColor
            self.fileView.set(backgroundColor: self.backgroundColor, circleStrokeColor: .systemGray5)
        }
    }
    
    override func setHighlighted(_ highlighted: Bool, animated: Bool) {
        super.setHighlighted(highlighted, animated: animated)
        
        if highlighted {
            guard let highlightColor = self.highlightColor else { return }
            self.fileView.set(backgroundColor: highlightColor, circleStrokeColor: .systemGray5)
            self.tagCircles.borderColor = highlightColor.cgColor
        } else {
            self.fileView.set(backgroundColor: self.backgroundColor, circleStrokeColor: .systemGray5)
            self.tagCircles.borderColor = self.tagBorderColor
        }
    }
    
    override func setSelected(_ selected: Bool, animated: Bool) {
        super.setSelected(selected, animated: animated)

        if selected {
            guard let highlightColor = self.highlightColor else { return }
            self.fileView.set(backgroundColor: highlightColor, circleStrokeColor: .systemGray5)
            self.tagCircles.borderColor = highlightColor.cgColor
        } else {
            self.fileView.set(backgroundColor: self.backgroundColor, circleStrokeColor: .systemGray5)
            self.tagCircles.borderColor = self.tagBorderColor
        }
    }

    func set(item: ItemCellModel, tapAction: @escaping () -> Void) {
        self.key = item.key
        self.fileView.tapAction = tapAction

        self.typeImageView.image = UIImage(named: item.typeIconName)
        self.titleLabel.text = item.title.isEmpty ? " " : item.title
        self.subtitleLabel.text = item.subtitle.isEmpty ? " " : item.subtitle
        self.fakeSubtitleLabel.text = self.subtitleLabel.text
        self.subtitleLabel.isHidden = item.subtitle.isEmpty && (item.hasNote || !item.tagColors.isEmpty)
        self.noteIcon.isHidden = !item.hasNote

        self.tagCircles.isHidden = item.tagColors.isEmpty
        if !self.tagCircles.isHidden {
            self.tagCircles.colors = item.tagColors
        }

        if let (contentType, progress, error) = item.attachment {
            self.fileView.set(contentType: contentType, progress: progress, error: error, style: .list)
            self.fileView.isHidden = false
        } else {
            self.fileView.isHidden = true
        }
    }

    func set(contentType: Attachment.ContentType, progress: CGFloat?, error: Error?) {
        self.fileView.set(contentType: contentType, progress: progress, error: error, style: .list)
        self.fileView.isHidden = false
    }

    func clearAttachment() {
        self.fileView.isHidden = true
    }
}
