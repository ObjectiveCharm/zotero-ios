//
//  ItemDetailAttachmentCell.swift
//  Zotero
//
//  Created by Michal Rentka on 10/02/2020.
//  Copyright © 2020 Corporation for Digital Scholarship. All rights reserved.
//

import UIKit

final class ItemDetailAttachmentCell: UITableViewCell {
    @IBOutlet private weak var containerHeight: NSLayoutConstraint!
    @IBOutlet private weak var fileView: FileAttachmentView!
    @IBOutlet private weak var attachmentIcon: UIImageView!
    @IBOutlet private weak var labelTop: NSLayoutConstraint!
    @IBOutlet private weak var labelLeft: NSLayoutConstraint!
    @IBOutlet private weak var label: UILabel!

    override func awakeFromNib() {
        super.awakeFromNib()

        let highlightView = UIView()
        highlightView.backgroundColor = Asset.Colors.cellHighlighted.color
        self.selectedBackgroundView = highlightView

        self.containerHeight.constant = ItemDetailLayout.minCellHeight
    }
    
    override func setHighlighted(_ highlighted: Bool, animated: Bool) {
        super.setHighlighted(highlighted, animated: animated)

        self.fileView.set(backgroundColor: (highlighted ? self.selectedBackgroundView?.backgroundColor : self.backgroundColor))
    }

    func setup(with attachment: Attachment, progress: CGFloat?, error: Error?, enabled: Bool) {
        switch attachment.type {
        case .file:
            self.fileView.set(state: .stateFrom(type: attachment.type, progress: progress, error: error), style: .detail)
            self.fileView.isHidden = false
            self.attachmentIcon.isHidden = true
        case .url:
            self.attachmentIcon.image = Asset.Images.ItemTypes.webPage.image
            self.fileView.isHidden = true
            self.attachmentIcon.isHidden = false
        }

        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.minimumLineHeight = ItemDetailLayout.lineHeight
        paragraphStyle.maximumLineHeight = ItemDetailLayout.lineHeight
        let attributedString = NSAttributedString(string: attachment.title,
                                                  attributes: [.font: UIFont.preferredFont(forTextStyle: .body),
                                                               .paragraphStyle: paragraphStyle])
        self.label.attributedText = attributedString

        let font = self.label.font!
        self.labelTop.constant = -(font.ascender - font.capHeight) - (ItemDetailLayout.lineHeight - font.lineHeight)
        self.labelLeft.constant = self.layoutMargins.left

        let textColor: UIColor
        if !enabled {
            textColor = .placeholderText
        } else {
            textColor = UIColor(dynamicProvider: { traitCollection -> UIColor in
                return traitCollection.userInterfaceStyle == .dark ? .white : .darkText
            })
        }

        self.label.textColor = textColor
        self.isUserInteractionEnabled = enabled
        self.setupAccessibility(for: attachment, enabled: enabled)
    }

    private func setupAccessibility(for attachment: Attachment, enabled: Bool) {
        guard enabled && self.selectionStyle != .none else {
            self.accessibilityTraits = []
            self.accessibilityHint = nil
            return
        }

        switch attachment.type {
        case .file(_, _, let location, _):
            switch location {
            case .remoteMissing:
                self.accessibilityTraits = []
                self.accessibilityHint = nil

            case .remote, .localAndChangedRemotely:
                self.accessibilityHint = L10n.Accessibility.ItemDetail.downloadAndOpen
                self.accessibilityTraits = .button

            case .local:
                self.accessibilityHint = L10n.Accessibility.ItemDetail.open
                self.accessibilityTraits = .button
            }

        case .url:
            self.accessibilityHint = L10n.Accessibility.ItemDetail.open
            self.accessibilityTraits = .button
        }
    }
}
