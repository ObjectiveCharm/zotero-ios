//
//  AnnotationViewHighlightContent.swift
//  Zotero
//
//  Created by Michal Rentka on 13.11.2020.
//  Copyright © 2020 Corporation for Digital Scholarship. All rights reserved.
//

import UIKit

import RxSwift
import RxCocoa

class AnnotationViewHighlightContent: UIView {
    private var lineView: UIView!
    private var textLabel: UILabel!
    private var button: UIButton!

    var tap: Observable<UIButton> {
        return self.button.rx.tap.flatMap({ Observable.just(self.button) })
    }

    init() {
        let lineView = UIView()
        lineView.translatesAutoresizingMaskIntoConstraints = false
        
        let label = UILabel()
        label.font = PDFReaderLayout.font
        label.textColor = Asset.Colors.annotationText.color
        label.numberOfLines = 0
        label.translatesAutoresizingMaskIntoConstraints = false

        let button = UIButton()
        button.translatesAutoresizingMaskIntoConstraints = false

        super.init(frame: CGRect())

        self.translatesAutoresizingMaskIntoConstraints = false
        self.backgroundColor = .white

        self.addSubview(lineView)
        self.addSubview(label)
        self.addSubview(button)

        let topFontOffset = PDFReaderLayout.font.ascender - PDFReaderLayout.font.xHeight

        NSLayoutConstraint.activate([
            // Horizontal
            lineView.leadingAnchor.constraint(equalTo: self.leadingAnchor, constant: PDFReaderLayout.annotationsHorizontalInset),
            label.leadingAnchor.constraint(equalTo: lineView.trailingAnchor, constant: PDFReaderLayout.annotationHighlightContentLeadingOffset),
            self.trailingAnchor.constraint(equalTo: label.trailingAnchor, constant: PDFReaderLayout.annotationsHorizontalInset),
            button.leadingAnchor.constraint(equalTo: self.leadingAnchor),
            button.trailingAnchor.constraint(equalTo: self.trailingAnchor),
            // Size
            lineView.heightAnchor.constraint(equalTo: label.heightAnchor),
            lineView.widthAnchor.constraint(equalToConstant: PDFReaderLayout.annotationHighlightLineWidth),
            // Vertical
            lineView.topAnchor.constraint(equalTo: label.topAnchor),
            lineView.bottomAnchor.constraint(equalTo: label.bottomAnchor),
            label.topAnchor.constraint(equalTo: self.topAnchor, constant: -topFontOffset),
            label.lastBaselineAnchor.constraint(equalTo: self.bottomAnchor),
            button.topAnchor.constraint(equalTo: self.topAnchor),
            button.bottomAnchor.constraint(equalTo: self.bottomAnchor)
        ])

        self.lineView = lineView
        self.textLabel = label
        self.button = button
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setup(with color: UIColor, text: String) {
        self.lineView.backgroundColor = color

        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.minimumLineHeight = PDFReaderLayout.annotationLineHeight
        paragraphStyle.maximumLineHeight = PDFReaderLayout.annotationLineHeight
        let attributedString = NSAttributedString(string: text, attributes: [.paragraphStyle: paragraphStyle])
        self.textLabel.attributedText = attributedString
    }
}
