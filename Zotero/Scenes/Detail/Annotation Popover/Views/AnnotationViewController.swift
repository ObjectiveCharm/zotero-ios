//
//  AnnotationViewController.swift
//  Zotero
//
//  Created by Michal Rentka on 13/10/2020.
//  Copyright © 2020 Corporation for Digital Scholarship. All rights reserved.
//

import UIKit

import RxSwift

#if PDFENABLED

typealias AnnotationViewControllerAction = (AnnotationView.Action, Annotation, UIButton) -> Void

final class AnnotationViewController: UIViewController {
    private let viewModel: ViewModel<PDFReaderActionHandler>
    private unowned let attributedStringConverter: HtmlAttributedStringConverter
    private let disposeBag: DisposeBag

    @IBOutlet private weak var scrollView: UIScrollView!
    @IBOutlet private weak var containerStackView: UIStackView!
    @IBOutlet private weak var colorPickerContainer: UIStackView!
    @IBOutlet private weak var lineWidthContainer: UIStackView!
    @IBOutlet private weak var lineWidthSlider: UISlider!
    @IBOutlet private weak var lineWidthValueLabel: UILabel!
    @IBOutlet private weak var deleteButton: UIButton!
    private weak var header: AnnotationViewHeader!
    private weak var comment: AnnotationViewTextView?
    private weak var tagsButton: AnnotationViewButton!
    private weak var tags: AnnotationViewText!

    weak var coordinatorDelegate: AnnotationPopoverAnnotationCoordinatorDelegate?

    private var commentPlaceholder: String {
        if self.viewModel.state.library.metadataEditable || self.viewModel.state.selectedAnnotation?.isAuthor == true {
            return L10n.Pdf.AnnotationsSidebar.addComment
        }
        return L10n.Pdf.AnnotationPopover.noComment
    }

    // MARK: - Lifecycle

    init(viewModel: ViewModel<PDFReaderActionHandler>, attributedStringConverter: HtmlAttributedStringConverter) {
        self.viewModel = viewModel
        self.attributedStringConverter = attributedStringConverter
        self.disposeBag = DisposeBag()
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        self.setupViews()
        self.view.layoutSubviews()

        self.viewModel.stateObservable
                      .observe(on: MainScheduler.instance)
                      .subscribe(onNext: { [weak self] state in
                          self?.update(state: state)
                      })
                      .disposed(by: self.disposeBag)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)

        self.navigationController?.setNavigationBarHidden(true, animated: animated)
        self.updatePreferredContentSize()
    }

    deinit {
        self.coordinatorDelegate?.didFinish()
    }

    // MARK: - Actions

    private func updatePreferredContentSize() {
        guard var size = self.containerStackView?.systemLayoutSizeFitting(CGSize(width: AnnotationPopoverLayout.width, height: .greatestFiniteMagnitude)) else { return }
        size.width = AnnotationPopoverLayout.width
        self.preferredContentSize = size
        self.navigationController?.preferredContentSize = size
    }

    private func update(state: PDFReaderState) {
        guard let annotation = state.selectedAnnotation else {
            self.presentingViewController?.dismiss(animated: true, completion: nil)
            return
        }

        guard state.changes.contains(.annotations) else { return }

        // Update header
        self.header.setup(with: annotation, isEditable: state.library.metadataEditable, showDoneButton: false, accessibilityType: .view)

        // Update comment
        if let commentView = self.comment {
            let comment = self.attributedStringConverter.convert(text: annotation.comment, baseFont: AnnotationPopoverLayout.annotationLayout.font)
            commentView.setup(text: comment)
        }

        // Update selected color
        if let views = self.colorPickerContainer?.arrangedSubviews {
            for view in views {
                guard let circleView = view as? ColorPickerCircleView else { continue }
                circleView.isSelected = circleView.hexColor == annotation.color
                circleView.accessibilityLabel = self.name(for: circleView.hexColor, isSelected: circleView.isSelected)
            }
        }

        // Update tags
        if !annotation.tags.isEmpty {
            self.tags.setup(with: AnnotationView.attributedString(from: annotation.tags, layout: AnnotationPopoverLayout.annotationLayout))
        }
        self.tags.isHidden = annotation.tags.isEmpty
        self.tagsButton.isHidden = !annotation.tags.isEmpty
    }

    private func name(for color: String, isSelected: Bool) -> String {
        let colorName = AnnotationsConfig.colorNames[color] ?? L10n.unknown
        return !isSelected ? colorName : L10n.Accessibility.Pdf.selected + ": " + colorName
    }

    @IBAction private func delete() {
        guard let annotation = self.viewModel.state.selectedAnnotation else { return }

        let controller = UIAlertController(title: L10n.warning, message: L10n.Pdf.AnnotationPopover.deleteConfirm, preferredStyle: .alert)

        controller.addAction(UIAlertAction(title: L10n.yes, style: .destructive, handler: { [weak self] _ in
            self?.viewModel.process(action: .removeAnnotation(annotation))
        }))

        controller.addAction(UIAlertAction(title: L10n.no, style: .cancel, handler: nil))
        self.present(controller, animated: true, completion: nil)
    }

    private func showSettings() {
        guard let annotation = self.viewModel.state.selectedAnnotation else { return }
        self.coordinatorDelegate?.showEdit(annotation: annotation,
                                           saveAction: { [weak self] annotation in
                                               self?.viewModel.process(action: .updateAnnotationProperties(annotation))
                                           },
                                           deleteAction: { [weak self] annotation in
                                               self?.viewModel.process(action: .removeAnnotation(annotation))
                                           })
    }

    private func set(color: String) {
        guard let annotation = self.viewModel.state.selectedAnnotation else { return }
        self.viewModel.process(action: .setColor(key: annotation.key, color: color))
    }

    private func showTagPicker() {
        guard let annotation = self.viewModel.state.selectedAnnotation, annotation.isAuthor else { return }

        let selected = Set(annotation.tags.map({ $0.name }))
        self.coordinatorDelegate?.showTagPicker(libraryId: self.viewModel.state.library.identifier, selected: selected, picked: { [weak self] tags in
            self?.viewModel.process(action: .setTags(tags, annotation.key))
        })
    }

    private func scrollToBottomIfNeeded() {
        guard self.containerStackView.frame.height > self.scrollView.frame.height else {
            self.scrollView.isScrollEnabled = false
            return
        }
        self.scrollView.isScrollEnabled = true
        let yOffset = self.scrollView.contentSize.height - self.scrollView.bounds.height + self.scrollView.contentInset.bottom
        self.scrollView.setContentOffset(CGPoint(x: 0, y: yOffset), animated: true)
    }

    // MARK: - Setups

    private func setupViews() {
        guard let annotation = self.viewModel.state.selectedAnnotation else { return }

        let layout = AnnotationPopoverLayout.annotationLayout

        var arrangedSubviews: [UIView] = []

        // Setup header
        let header = AnnotationViewHeader(layout: layout)
        header.setup(with: annotation, isEditable: self.viewModel.state.library.metadataEditable, showDoneButton: false, accessibilityType: .view)
        header.menuTap
              .subscribe(with: self, onNext: { `self`, _ in
                  self.showSettings()
              })
              .disposed(by: self.disposeBag)
        self.header = header

        arrangedSubviews.append(header)
        arrangedSubviews.append(AnnotationViewSeparator())

        // Setup comment
        if annotation.type != .ink {
            let commentView = AnnotationViewTextView(layout: layout, placeholder: self.commentPlaceholder)
            let comment = AnnotationView.attributedString(from: self.attributedStringConverter.convert(text: annotation.comment, baseFont: layout.font), layout: layout)
            commentView.setup(text: comment)
            commentView.textObservable
                       .subscribe(with: self, onNext: { `self`, data in
                           self.viewModel.process(action: .setComment(key: annotation.key, comment: data.0))
                           if data.1 {
                               self.updatePreferredContentSize()
                               self.scrollToBottomIfNeeded()
                           }
                       })
                       .disposed(by: self.disposeBag)
            self.comment = commentView

            arrangedSubviews.append(commentView)
            arrangedSubviews.append(AnnotationViewSeparator())
        }

        // Setup color picker
        self.colorPickerContainer.accessibilityLabel = L10n.Accessibility.Pdf.colorPicker
        for (idx, hexColor) in AnnotationsConfig.colors.enumerated() {
            let circleView = ColorPickerCircleView(hexColor: hexColor)
            circleView.contentInsets = UIEdgeInsets(top: 11, left: (idx == 0 ? 16 : 11), bottom: 11, right: 11)
            circleView.backgroundColor = .clear
            circleView.isSelected = circleView.hexColor == self.viewModel.state.selectedAnnotation?.color
            circleView.tap
                      .subscribe(with: self, onNext: { `self`, color in
                          self.set(color: color)
                      })
                      .disposed(by: self.disposeBag)
            circleView.isAccessibilityElement = true
            circleView.accessibilityLabel = self.name(for: circleView.hexColor, isSelected: circleView.isSelected)
            circleView.backgroundColor = Asset.Colors.defaultCellBackground.color
            self.colorPickerContainer.addArrangedSubview(circleView)
        }

        arrangedSubviews.append(self.colorPickerContainer)
        arrangedSubviews.append(AnnotationViewSeparator())

        // Setup tags
        let tags = AnnotationViewText(layout: layout)
        if !annotation.tags.isEmpty {
            tags.setup(with: AnnotationView.attributedString(from: annotation.tags, layout: layout))
        }
        tags.isHidden = annotation.tags.isEmpty
        tags.tap
            .subscribe(with: self, onNext: { `self`, _ in
                self.showTagPicker()
            })
            .disposed(by: self.disposeBag)
        tags.button.accessibilityLabel = L10n.Accessibility.Pdf.tags + ": " + (self.tags?.textLabel.text ?? "")
        tags.textLabel.isAccessibilityElement = false
        self.tags = tags

        arrangedSubviews.append(tags)

        let tagButton = AnnotationViewButton(layout: layout)
        tagButton.setTitle(L10n.Pdf.AnnotationsSidebar.addTags, for: .normal)
        tagButton.isHidden = !annotation.tags.isEmpty
        tagButton.rx.tap
                 .subscribe(with: self, onNext: { `self`, _ in
                     self.showTagPicker()
                 })
                 .disposed(by: self.disposeBag)
        tagButton.accessibilityLabel = L10n.Pdf.AnnotationsSidebar.addTags
        self.tagsButton = tagButton

        arrangedSubviews.append(tagButton)
        arrangedSubviews.append(AnnotationViewSeparator())

        for subview in self.containerStackView.arrangedSubviews {
            self.containerStackView.removeArrangedSubview(subview)
        }
        for subview in arrangedSubviews {
            self.containerStackView.addArrangedSubview(subview)
        }
    }
}

extension AnnotationViewController: AnnotationPopover {
    var annotationKey: String {
        return self.viewModel.state.selectedAnnotation?.key ?? ""
    }
}

#endif
