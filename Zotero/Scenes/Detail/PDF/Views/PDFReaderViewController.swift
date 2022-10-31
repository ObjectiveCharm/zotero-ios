//
//  PDFReaderViewController.swift
//  Zotero
//
//  Created by Michal Rentka on 24/04/2020.
//  Copyright © 2020 Corporation for Digital Scholarship. All rights reserved.
//

#if PDFENABLED

import UIKit

import CocoaLumberjackSwift
import PSPDFKit
import PSPDFKitUI
import RxSwift
import RealmSwift

final class PDFReaderViewController: UIViewController {
    private enum NavigationBarButton: Int {
        case redo = 1
        case undo = 2
        case share = 3
    }

    private weak var sidebarController: PDFSidebarViewController!
    private weak var pdfController: PDFViewController!
    private weak var sidebarControllerLeft: NSLayoutConstraint!
    private weak var pdfControllerLeft: NSLayoutConstraint!
    // Annotation toolbar
    private weak var createNoteButton: CheckboxButton!
    private weak var createHighlightButton: CheckboxButton!
    private weak var createAreaButton: CheckboxButton!
    private weak var createInkButton: CheckboxButton!
    private weak var createEraserButton: CheckboxButton!
    private weak var colorPickerbutton: UIButton!

    private static let saveDelay: Int = 3
    private let viewModel: ViewModel<PDFReaderActionHandler>
    private let disposeBag: DisposeBag

    private var isCompactSize: Bool
    private var isSidebarTransitioning: Bool
    private var annotationTimerDisposeBag: DisposeBag
    private var pageTimerDisposeBag: DisposeBag
    private var selectionView: SelectionView?
    private var lastGestureRecognizerTouch: UITouch?
    private var didAppear: Bool

    private lazy var shareButton: UIBarButtonItem = {
        let share = UIBarButtonItem(image: UIImage(systemName: "square.and.arrow.up"), style: .plain, target: nil, action: nil)
        share.accessibilityLabel = L10n.Accessibility.Pdf.export
        share.tag = NavigationBarButton.share.rawValue
        share.rx.tap
             .subscribe(onNext: { [weak self, weak share] _ in
                 guard let `self` = self, let share = share else { return }
                 self.coordinatorDelegate?.showPdfExportSettings(sender: share) { [weak self] settings in
                     self?.viewModel.process(action: .export(settings))
                 }
             })
             .disposed(by: self.disposeBag)
        return share
    }()
    private lazy var settingsButton: UIBarButtonItem = {
        let settings = self.pdfController.settingsButtonItem
        settings.rx
                .tap
                .subscribe(onNext: { [weak self] _ in
                    self?.showSettings(sender: settings)
                })
                .disposed(by: self.disposeBag)
        return settings
    }()
    private lazy var searchButton: UIBarButtonItem = {
        let search = UIBarButtonItem(image: UIImage(systemName: "magnifyingglass"), style: .plain, target: nil, action: nil)
        search.rx.tap
              .subscribe(onNext: { [weak self] _ in
                  self?.showSearch(sender: search, text: nil)
              })
              .disposed(by: self.disposeBag)
        return search
    }()
    private lazy var undoButton: UIBarButtonItem = {
        let undo = UIBarButtonItem(image: UIImage(systemName: "arrow.uturn.left"), style: .plain, target: nil, action: nil)
        undo.isEnabled = self.viewModel.state.document.undoController.undoManager.canUndo
        undo.tag = NavigationBarButton.undo.rawValue
        undo.rx
            .tap
            .subscribe(onNext: { [weak self] _ in
                guard let `self` = self, self.viewModel.state.document.undoController.undoManager.canUndo else { return }
                self.viewModel.state.document.undoController.undoManager.undo()
            })
            .disposed(by: self.disposeBag)
        return undo
    }()
    private lazy var redoButton: UIBarButtonItem = {
        let redo = UIBarButtonItem(image: UIImage(systemName: "arrow.uturn.right"), style: .plain, target: nil, action: nil)
        redo.isEnabled = self.viewModel.state.document.undoController.undoManager.canRedo
        redo.tag = NavigationBarButton.redo.rawValue
        redo.rx
            .tap
            .subscribe(onNext: { [weak self] _ in
                guard let `self` = self, self.viewModel.state.document.undoController.undoManager.canRedo else { return }
                self.viewModel.state.document.undoController.undoManager.redo()
            })
            .disposed(by: self.disposeBag)
        return redo
    }()

    weak var coordinatorDelegate: (DetailPdfCoordinatorDelegate & DetailAnnotationsCoordinatorDelegate)?

    var isSidebarVisible: Bool {
        return self.sidebarControllerLeft?.constant == 0
    }

    var key: String {
        return self.viewModel.state.key
    }

    // MARK: - Lifecycle

    init(viewModel: ViewModel<PDFReaderActionHandler>, compactSize: Bool) {
        self.viewModel = viewModel
        self.isCompactSize = compactSize
        self.didAppear = false
        self.isSidebarTransitioning = false
        self.disposeBag = DisposeBag()
        self.annotationTimerDisposeBag = DisposeBag()
        self.pageTimerDisposeBag = DisposeBag()
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        self.view.backgroundColor = .systemGray6
        self.set(userActivity: .pdfActivity(for: self.viewModel.state.key, libraryId: self.viewModel.state.library.identifier))
        self.setupViews()
        self.setupNavigationBar()
        self.setupAnnotationControls(forCompactSize: self.isCompactSize)
        self.set(toolColor: self.viewModel.state.activeColor, in: self.pdfController.annotationStateManager)
        self.setupObserving()
        self.updateInterface(to: self.viewModel.state.settings)

        self.viewModel.process(action: .loadDocumentData(boundingBoxConverter: self))

        self.pdfController.setPageIndex(PageIndex(self.viewModel.state.visiblePage), animated: false)

        if let annotation = self.viewModel.state.selectedAnnotation {
            self.select(annotation: self.viewModel.state.selectedAnnotation, pageIndex: self.pdfController.pageIndex, document: self.viewModel.state.document)
            self.toggleSidebar(animated: false)
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        self.didAppear = true
    }

    deinit {
        self.viewModel.process(action: .changeIdleTimerDisabled(false))
        self.pdfController?.annotationStateManager.remove(self)
        self.coordinatorDelegate?.pdfDidDeinitialize()
        DDLogInfo("PDFReaderViewController deinitialized")
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)

        guard self.traitCollection.hasDifferentColorAppearance(comparedTo: previousTraitCollection) else { return }

        self.viewModel.process(action: .userInterfaceStyleChanged(self.traitCollection.userInterfaceStyle))
    }

    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)

        let isCompactSize = UIDevice.current.isCompactWidth(size: size)
        let sizeDidChange = isCompactSize != self.isCompactSize
        self.isCompactSize = isCompactSize

        guard self.viewIfLoaded != nil else { return }

        if self.isSidebarVisible && sizeDidChange {
            self.pdfControllerLeft.constant = isCompactSize ? 0 : PDFReaderLayout.sidebarWidth
        }

        coordinator.animate(alongsideTransition: { _ in
            if sizeDidChange {
                self.navigationItem.rightBarButtonItems = self.createRightBarButtonItems(forCompactSize: isCompactSize)
                self.setupAnnotationControls(forCompactSize: isCompactSize)
                self.view.layoutIfNeeded()
            }

            // Update highlight selection if needed
            if let annotation = self.viewModel.state.selectedAnnotation,
               let pageView = self.pdfController.pageViewForPage(at: self.pdfController.pageIndex) {
                self.updateSelection(on: pageView, annotation: annotation)
            }
        }, completion: nil)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()

        guard !self.didAppear else { return }

        if let (page, _) = self.viewModel.state.focusDocumentLocation, let annotation = self.viewModel.state.selectedAnnotation {
            self.select(annotation: annotation, pageIndex: PageIndex(page), document: self.viewModel.state.document)
        }
    }

    // MARK: - Actions

    private func update(state: PDFReaderState) {
        if state.changes.contains(.annotations) {
            // Hide popover if annotation has been deleted
            if let controller = (self.presentedViewController as? UINavigationController)?.viewControllers.first as? AnnotationPopover, let key = controller.annotationKey, !state.sortedKeys.contains(key) {
                self.dismiss(animated: true, completion: nil)
            }
        }

        if state.changes.contains(.interfaceStyle) {
            self.updateInterface(to: state.settings)
        }

        if state.changes.contains(.settings) {
            self.updateInterface(to: state.settings)

            if self.pdfController.configuration.scrollDirection != state.settings.direction ||
               self.pdfController.configuration.pageTransition != state.settings.transition ||
               self.pdfController.configuration.pageMode != state.settings.pageMode ||
               self.pdfController.configuration.spreadFitting != state.settings.pageFitting {
                self.pdfController.updateConfiguration { configuration in
                    configuration.scrollDirection = state.settings.direction
                    configuration.pageTransition = state.settings.transition
                    configuration.pageMode = state.settings.pageMode
                    configuration.spreadFitting = state.settings.pageFitting
                }
            }
        }

        if state.changes.contains(.selection) {
            if let annotation = state.selectedAnnotation {
                if let location = state.focusDocumentLocation {
                    // If annotation was selected, focus if needed
                    self.focus(annotation: annotation, at: location, document: state.document)
                } else if annotation.type != .ink || self.pdfController.annotationStateManager.state != .ink {
                    // Update selection if needed.
                    // Never select ink annotation if inking is active in case the user needs to continue typing.
                    self.select(annotation: annotation, pageIndex: self.pdfController.pageIndex, document: state.document)
                }
            } else {
                // Otherwise remove selection if needed
                self.select(annotation: nil, pageIndex: self.pdfController.pageIndex, document: state.document)
            }

            self.showPopupAnnotationIfNeeded(state: state)
        }

        if state.changes.contains(.activeColor) {
            self.set(toolColor: state.activeColor, in: self.pdfController.annotationStateManager)
            self.colorPickerbutton.tintColor = state.activeColor
        }

        if state.changes.contains(.activeLineWidth) {
            self.set(lineWidth: state.activeLineWidth, in: self.pdfController.annotationStateManager)
        }

        if state.changes.contains(.activeEraserSize) {
            self.set(lineWidth: state.activeEraserSize, in: self.pdfController.annotationStateManager)
        }

        if state.changes.contains(.export) {
            self.update(state: state.exportState)
        }

        if let error = state.error {
            // TODO: - show error
        }

        if let notification = state.pdfNotification {
            self.updatePdf(notification: notification)
        }
    }

    private func updatePdf(notification: Notification) {
        switch notification.name {
        case .PSPDFAnnotationChanged:
            guard let changes = notification.userInfo?[PSPDFAnnotationChangedNotificationKeyPathKey] as? [String] else { return }
            // Changing annotation color changes the `lastUsed` color in `annotationStateManager` (#487), so we have to re-set it.
            if changes.contains("color") {
                self.set(toolColor: self.viewModel.state.activeColor, in: self.pdfController.annotationStateManager)
            }

        case .PSPDFAnnotationsAdded:
            guard let annotations = notification.object as? [PSPDFKit.Annotation] else { return }
            // If Image annotation is active after adding the annotation, deactivate it
            if annotations.first is PSPDFKit.SquareAnnotation && self.pdfController.annotationStateManager.state == .square {
                // Don't reset apple pencil detection here, this is automatic action, not performed by user.
                self.toggle(annotationTool: .square, tappedWithStylus: false, resetPencilManager: false)
            }

        default: break
        }
    }

    private func update(state: PDFExportState?) {
        var items = self.navigationItem.rightBarButtonItems ?? []

        guard let shareId = items.firstIndex(where: { $0.tag == NavigationBarButton.share.rawValue }) else { return }

        guard let state = state else {
            if items[shareId].customView != nil { // if activity indicator is visible, replace it with share button
                items[shareId] = self.shareButton
                self.navigationItem.rightBarButtonItems = items
            }
            return
        }

        switch state {
        case .preparing:
            let indicator = UIActivityIndicatorView(style: .medium)
            indicator.startAnimating()
            let button = UIBarButtonItem(customView: indicator)
            button.tag = NavigationBarButton.share.rawValue
            items[shareId] = button

        case .exported(let file):
            DDLogInfo("PDFReaderViewController: share pdf file - \(file.createUrl().absoluteString)")
            items[shareId] = self.shareButton
            self.coordinatorDelegate?.share(url: file.createUrl(), barButton: self.shareButton)

        case .failed(let error):
            DDLogError("PDFReaderViewController: could not export pdf - \(error)")
            self.coordinatorDelegate?.show(error: error)
            items[shareId] = self.shareButton
        }

        self.navigationItem.rightBarButtonItems = items
    }

    private func updateInterface(to settings: PDFSettings) {
        switch settings.appearanceMode {
        case .automatic:
            self.pdfController.appearanceModeManager.appearanceMode = self.traitCollection.userInterfaceStyle == .dark ? .night : []
            self.navigationController?.overrideUserInterfaceStyle = .unspecified
        case .light:
            self.pdfController.appearanceModeManager.appearanceMode = []
            self.navigationController?.overrideUserInterfaceStyle = .light
        case .dark:
            self.pdfController.appearanceModeManager.appearanceMode = .night
            self.navigationController?.overrideUserInterfaceStyle = .dark
        }
    }

    private func showPopupAnnotationIfNeeded(state: PDFReaderState) {
        guard !self.isSidebarVisible,
              let annotation = state.selectedAnnotation,
              let pageView = self.pdfController.pageViewForPage(at: UInt(annotation.page)) else { return }

        let frame = self.view.convert(annotation.boundingBox(boundingBoxConverter: self), from: pageView.pdfCoordinateSpace)

        self.coordinatorDelegate?.showAnnotationPopover(viewModel: self.viewModel, sourceRect: frame, popoverDelegate: self)
    }

    private func toggle(annotationTool: PSPDFKit.Annotation.Tool, tappedWithStylus: Bool, resetPencilManager: Bool = true) {
        let stateManager = self.pdfController.annotationStateManager
        stateManager.stylusMode = .fromStylusManager

        if stateManager.state == annotationTool {
            stateManager.setState(nil, variant: nil)
            if resetPencilManager {
                PSPDFKit.SDK.shared.applePencilManager.detected = false
                PSPDFKit.SDK.shared.applePencilManager.enabled = false
            }
            return
        } else if tappedWithStylus {
            PSPDFKit.SDK.shared.applePencilManager.detected = true
            PSPDFKit.SDK.shared.applePencilManager.enabled = true
        }

        stateManager.setState(annotationTool, variant: nil)

        let (color, _, blendMode) = AnnotationColorGenerator.color(from: self.viewModel.state.activeColor, isHighlight: (annotationTool == .highlight), userInterfaceStyle: self.traitCollection.userInterfaceStyle)
        stateManager.drawColor = color
        stateManager.blendMode = blendMode ?? .normal

        switch annotationTool {
        case .ink:
            stateManager.lineWidth = self.viewModel.state.activeLineWidth
            if UIPencilInteraction.prefersPencilOnlyDrawing {
                stateManager.stylusMode = .stylus
            }

        case .eraser:
            stateManager.lineWidth = self.viewModel.state.activeEraserSize

        default: break
        }
    }

    private func updatePencilSettingsIfNeeded() {
        guard self.pdfController.annotationStateManager.state == .ink else { return }
        self.pdfController.annotationStateManager.stylusMode = UIPencilInteraction.prefersPencilOnlyDrawing ? .stylus : .fromStylusManager
    }

    private func showColorPicker(sender: UIButton) {
        self.coordinatorDelegate?.showColorPicker(selected: self.viewModel.state.activeColor.hexString, sender: sender, save: { [weak self] color in
            self?.viewModel.process(action: .setActiveColor(color))
        })
    }

    private func toggleSidebar(animated: Bool) {
        let shouldShow = !self.isSidebarVisible

        // If the layout is compact, show annotation sidebar above pdf document.
        if !UIDevice.current.isCompactWidth(size: self.view.frame.size) {
            self.pdfControllerLeft.constant = shouldShow ? PDFReaderLayout.sidebarWidth : 0
        }
        self.sidebarControllerLeft.constant = shouldShow ? 0 : -PDFReaderLayout.sidebarWidth

        self.navigationItem.leftBarButtonItems?.last?.accessibilityLabel = shouldShow ? L10n.Accessibility.Pdf.sidebarClose : L10n.Accessibility.Pdf.sidebarOpen

        if !animated {
            self.sidebarController.view.isHidden = !shouldShow
            self.view.layoutIfNeeded()

            if !shouldShow {
                self.view.endEditing(true)
            }
            return
        }

        if shouldShow {
            self.sidebarController.view.isHidden = false
        } else {
            self.view.endEditing(true)
        }

        self.isSidebarTransitioning = true

        UIView.animate(withDuration: 0.3, delay: 0,
                       usingSpringWithDamping: 1,
                       initialSpringVelocity: 5,
                       options: [.curveEaseOut],
                       animations: {
                           self.view.layoutIfNeeded()
                       },
                       completion: { finished in
                           guard finished else { return }
                           if !shouldShow {
                               self.sidebarController.view.isHidden = true
                           }
                           self.isSidebarTransitioning = false
                       })
    }

    private func showSearch(sender: UIBarButtonItem, text: String?) {
        self.coordinatorDelegate?.showSearch(pdfController: self.pdfController, text: text, sender: sender, result: { [weak self] result in
            self?.highlight(result: result)
        })
    }

    private func highlight(result: SearchResult) {
        self.pdfController.searchHighlightViewManager.clearHighlightedSearchResults(animated: (self.pdfController.pageIndex == result.pageIndex))
        self.scrollIfNeeded(to: result.pageIndex, animated: true) {
            self.pdfController.searchHighlightViewManager.addHighlight([result], animated: true)
        }
    }

    /// Scrolls to given page if needed.
    /// - parameter pageIndex: Page index to which the `pdfController` is supposed to scroll.
    /// - parameter animated: `true` if scrolling is animated, `false` otherwise.
    /// - parameter completion: Completion block called after scroll. Block is also called when scroll was not needed.
    private func scrollIfNeeded(to pageIndex: PageIndex, animated: Bool, completion: @escaping () -> Void) {
        guard self.pdfController.pageIndex != pageIndex else {
            completion()
            return
        }

        if !animated {
            self.pdfController.setPageIndex(pageIndex, animated: false)
            completion()
            return
        }

        UIView.animate(withDuration: 0.25, animations: {
            self.pdfController.setPageIndex(pageIndex, animated: false)
        }, completion: { finished in
            guard finished else { return }
            completion()
        })
    }

    private func showSettings(sender: UIBarButtonItem) {
        self.coordinatorDelegate?.showSettings(with: self.viewModel.state.settings, sender: sender, completion: { [weak self] settings in
            self?.viewModel.process(action: .setSettings(settings))
        })
    }

    private func close() {
        self.viewModel.process(action: .clearTmpAnnotationPreviews)
        self.navigationController?.presentingViewController?.dismiss(animated: true, completion: nil)
    }

    private func set(toolColor: UIColor, in stateManager: AnnotationStateManager) {
        let highlightColor = AnnotationColorGenerator.color(from: toolColor, isHighlight: true,
                                                            userInterfaceStyle: self.traitCollection.userInterfaceStyle).color

        stateManager.setLastUsedColor(highlightColor, annotationString: .highlight)
        stateManager.setLastUsedColor(toolColor, annotationString: .note)
        stateManager.setLastUsedColor(toolColor, annotationString: .square)

        if stateManager.state == .highlight {
            stateManager.drawColor = highlightColor
        } else {
            stateManager.drawColor = toolColor
        }
    }

    private func set(lineWidth: CGFloat, in stateManager: AnnotationStateManager) {
        stateManager.lineWidth = lineWidth
    }

    private func add(controller: UIViewController) {
        controller.willMove(toParent: self)
        self.addChild(controller)
        self.view.addSubview(controller.view)
        controller.didMove(toParent: self)
    }

    @objc private func annotationControlTapped(sender: UIButton, event: UIEvent) {
        let tool: PSPDFKit.Annotation.Tool
        if sender == self.createNoteButton {
            tool = .note
        } else if sender == self.createAreaButton {
            tool = .square
        } else if sender == self.createHighlightButton {
            tool = .highlight
        } else if sender == self.createEraserButton {
            tool = .eraser
        } else {
            fatalError()
        }

        let isStylus = event.allTouches?.first?.type == .stylus

        self.toggle(annotationTool: tool, tappedWithStylus: isStylus)
    }

    // MARK: - Selection

    /// (De)Selects given annotation in document.
    /// - parameter annotation: Annotation to select. Existing selection will be deselected if set to `nil`.
    /// - parameter pageIndex: Page index of page where (de)selection should happen.
    /// - parameter document: Active `Document` instance.
    private func select(annotation: Annotation?, pageIndex: PageIndex, document: PSPDFKit.Document) {
        guard let pageView = self.pdfController.pageViewForPage(at: pageIndex) else { return }

        self.updateSelection(on: pageView, annotation: annotation)

        if let annotation = annotation, let pdfAnnotation = document.annotation(on: Int(pageIndex), with: annotation.key) {
            if !pageView.selectedAnnotations.contains(pdfAnnotation) {
                pageView.selectedAnnotations = [pdfAnnotation]
            }
        } else {
            if !pageView.selectedAnnotations.isEmpty {
                pageView.selectedAnnotations = []
            }
        }
    }

    /// Focuses given annotation and selects it if it's not selected yet.
    private func focus(annotation: Annotation, at location: AnnotationDocumentLocation, document: PSPDFKit.Document) {
        let pageIndex = PageIndex(location.page)
        self.scrollIfNeeded(to: pageIndex, animated: true) {
            self.select(annotation: annotation, pageIndex: pageIndex, document: document)
        }
    }

    /// Updates `SelectionView` for `PDFPageView` based on selected annotation.
    /// - parameter pageView: `PDFPageView` instance for given page.
    /// - parameter selectedAnnotation: Selected annotation or `nil` if there is no selection.
    private func updateSelection(on pageView: PDFPageView, annotation: Annotation?) {
        // Delete existing custom highlight selection view
        if let view = self.selectionView {
            view.removeFromSuperview()
        }

        guard let selection = annotation, selection.type == .highlight && selection.page == Int(pageView.pageIndex) else { return }
        // Add custom highlight selection view if needed
        let frame = pageView.convert(selection.boundingBox(boundingBoxConverter: self), from: pageView.pdfCoordinateSpace).insetBy(dx: -SelectionView.inset, dy: -SelectionView.inset)
        let selectionView = SelectionView()
        selectionView.frame = frame
        pageView.annotationContainerView.addSubview(selectionView)
        self.selectionView = selectionView
    }

    // MARK: - Setups

    private func setupViews() {
        let pdfController = self.createPdfController(with: self.viewModel.state.document, settings: self.viewModel.state.settings)
        pdfController.view.translatesAutoresizingMaskIntoConstraints = false

        let sidebarController = PDFSidebarViewController(viewModel: self.viewModel)
        sidebarController.sidebarDelegate = self
        sidebarController.coordinatorDelegate = self.coordinatorDelegate
        sidebarController.boundingBoxConverter = self
        sidebarController.view.translatesAutoresizingMaskIntoConstraints = false

        let separator = UIView()
        separator.translatesAutoresizingMaskIntoConstraints = false
        separator.backgroundColor = Asset.Colors.annotationSidebarBorderColor.color

        self.add(controller: pdfController)
        self.add(controller: sidebarController)
        self.view.addSubview(separator)

        let pdfLeftConstraint = pdfController.view.leadingAnchor.constraint(equalTo: self.view.leadingAnchor)
        let sidebarLeftConstraint = sidebarController.view.leadingAnchor.constraint(equalTo: self.view.leadingAnchor, constant: -PDFReaderLayout.sidebarWidth)

        NSLayoutConstraint.activate([
            sidebarController.view.topAnchor.constraint(equalTo: self.view.topAnchor),
            sidebarController.view.bottomAnchor.constraint(equalTo: self.view.bottomAnchor),
            sidebarController.view.widthAnchor.constraint(equalToConstant: PDFReaderLayout.sidebarWidth),
            sidebarLeftConstraint,
            separator.widthAnchor.constraint(equalToConstant: PDFReaderLayout.separatorWidth),
            separator.leadingAnchor.constraint(equalTo: sidebarController.view.trailingAnchor),
            separator.topAnchor.constraint(equalTo: self.view.topAnchor),
            separator.bottomAnchor.constraint(equalTo: self.view.bottomAnchor),
            pdfController.view.trailingAnchor.constraint(equalTo: self.view.trailingAnchor),
            pdfController.view.topAnchor.constraint(equalTo: self.view.safeAreaLayoutGuide.topAnchor),
            pdfController.view.bottomAnchor.constraint(equalTo: self.view.safeAreaLayoutGuide.bottomAnchor),
            pdfLeftConstraint
        ])

        self.pdfController = pdfController
        self.pdfControllerLeft = pdfLeftConstraint
        self.sidebarController = sidebarController
        self.sidebarControllerLeft = sidebarLeftConstraint
    }

    private func createPdfController(with document: PSPDFKit.Document, settings: PDFSettings) -> PDFViewController {
        let pdfConfiguration = PDFConfiguration { builder in
            builder.scrollDirection = settings.direction
            builder.pageTransition = settings.transition
            builder.pageMode = settings.pageMode
            builder.spreadFitting = settings.pageFitting
            builder.documentLabelEnabled = .NO
            builder.allowedAppearanceModes = [.night]
            builder.isCreateAnnotationMenuEnabled = true
            builder.createAnnotationMenuGroups = self.createAnnotationCreationMenuGroups()
            builder.allowedMenuActions = [.copy, .search, .speak, .share, .annotationCreation, .define]
            builder.scrubberBarType = .horizontal
//            builder.thumbnailBarMode = .scrubberBar
            builder.markupAnnotationMergeBehavior = .never
            builder.overrideClass(PSPDFKit.HighlightAnnotation.self, with: HighlightAnnotation.self)
            builder.overrideClass(PSPDFKit.NoteAnnotation.self, with: NoteAnnotation.self)
            builder.overrideClass(PSPDFKit.SquareAnnotation.self, with: SquareAnnotation.self)
        }

        let controller = PDFViewController(document: document, configuration: pdfConfiguration)
        controller.view.backgroundColor = .systemGray6
        controller.delegate = self
        controller.formSubmissionDelegate = nil
        controller.annotationStateManager.add(self)
        controller.annotationStateManager.pencilInteraction.delegate = self
        self.setup(scrubberBar: controller.userInterfaceView.scrubberBar)
        self.setup(interactions: controller.interactions)

        return controller
    }

    private func createAnnotationCreationMenuGroups() -> [AnnotationToolConfiguration.ToolGroup] {
        return [AnnotationToolConfiguration.ToolGroup(items: [
                AnnotationToolConfiguration.ToolItem(type: .highlight),
                AnnotationToolConfiguration.ToolItem(type: .note),
                AnnotationToolConfiguration.ToolItem(type: .square),
                AnnotationToolConfiguration.ToolItem(type: .ink, variant: .inkPen)
        ])]
    }

    private func setup(scrubberBar: ScrubberBar) {
        let appearance = UIToolbarAppearance()
        appearance.backgroundColor = Asset.Colors.pdfScrubberBarBackground.color

        scrubberBar.standardAppearance = appearance
        scrubberBar.compactAppearance = appearance
    }

    private func setup(interactions: DocumentViewInteractions) {
        // Only supported annotations can be selected
        interactions.selectAnnotation.addActivationCondition { context, _, _ -> Bool in
            return AnnotationsConfig.supported.contains(context.annotation.type)
        }

        interactions.selectAnnotation.addActivationCallback { [weak self] context, _, _ in
            let key = context.annotation.key ?? context.annotation.uuid
            let type: PDFReaderState.AnnotationKey.Kind = context.annotation.isZoteroAnnotation ? .database : .document
            self?.viewModel.process(action: .selectAnnotationFromDocument(PDFReaderState.AnnotationKey(key: key, type: type)))
        }

        interactions.deselectAnnotation.addActivationCondition { [weak self] _, _, _ -> Bool in
            // `interactions.deselectAnnotation.addActivationCallback` is not always called when highglight annotation tool is enabled.
            self?.viewModel.process(action: .deselectSelectedAnnotation)
            return true
        }

        // Only Zotero-synced annotations can be edited
        interactions.editAnnotation.addActivationCondition { context, _, _ -> Bool in
            return context.annotation.key != nil && context.annotation.isEditable
        }
    }

    private func setupAnnotationControls(forCompactSize isCompact: Bool) {
        let buttons = self.createAnnotationControlButtons()
        self.navigationController?.setToolbarHidden(!isCompact, animated: false)

        if !isCompact {
            self.navigationController?.toolbarItems = nil
            let stackView = UIStackView(arrangedSubviews: buttons)
            stackView.spacing = 14
            self.navigationItem.titleView = stackView
            return
        }

        let flexibleSpacer = UIBarButtonItem(barButtonSystemItem: .flexibleSpace, target: nil, action: nil)
        let fixedSpacer = UIBarButtonItem(barButtonSystemItem: .fixedSpace, target: nil, action: nil)
        fixedSpacer.width = 20

        // Create toolbar items from `UIButton`s
        var toolbarItems = buttons.map({ UIBarButtonItem(customView: $0) })
        // Add undo/redo buttons
        toolbarItems += [self.undoButton, self.redoButton]
        // Insert flexible spacers between each item
        toolbarItems = (0..<((2 * toolbarItems.count) - 1)).map({ $0 % 2 == 0 ? toolbarItems[$0/2] : flexibleSpacer })
        // Insert fixed spacer on sides
        toolbarItems.insert(fixedSpacer, at: 0)
        toolbarItems.insert(fixedSpacer, at: toolbarItems.count)

        self.navigationItem.titleView = nil
        self.toolbarItems = toolbarItems
    }

    private func createAnnotationControlButtons() -> [UIButton] {
        guard self.viewModel.state.library.metadataEditable else {
            return []
        }

        let symbolConfig = UIImage.SymbolConfiguration(scale: .large)

        let highlight = CheckboxButton(type: .custom)
        highlight.accessibilityLabel = L10n.Accessibility.Pdf.highlightAnnotationTool
        highlight.setImage(Asset.Images.Annotations.highlighterLarge.image.withRenderingMode(.alwaysTemplate), for: .normal)
        highlight.tintColor = Asset.Colors.zoteroBlueWithDarkMode.color
        highlight.addTarget(self, action: #selector(PDFReaderViewController.annotationControlTapped(sender:event:)), for: .touchDown)
        self.createHighlightButton = highlight

        let note = CheckboxButton(type: .custom)
        note.accessibilityLabel = L10n.Accessibility.Pdf.noteAnnotationTool
        note.setImage(Asset.Images.Annotations.noteLarge.image.withRenderingMode(.alwaysTemplate), for: .normal)
        note.tintColor = Asset.Colors.zoteroBlueWithDarkMode.color
        note.addTarget(self, action: #selector(PDFReaderViewController.annotationControlTapped(sender:event:)), for: .touchDown)
        self.createNoteButton = note

        let area = CheckboxButton(type: .custom)
        area.accessibilityLabel = L10n.Accessibility.Pdf.imageAnnotationTool
        area.setImage(Asset.Images.Annotations.areaLarge.image.withRenderingMode(.alwaysTemplate), for: .normal)
        area.tintColor = Asset.Colors.zoteroBlueWithDarkMode.color
        area.addTarget(self, action: #selector(PDFReaderViewController.annotationControlTapped(sender:event:)), for: .touchDown)
        self.createAreaButton = area

        let inkLongPress = UILongPressGestureRecognizer()
        inkLongPress.delegate = self
        inkLongPress.rx
                    .event
                    .subscribe(with: self, onNext: { `self`, recognizer in
                        if recognizer.state == .began, let view = recognizer.view {
                            self.coordinatorDelegate?.showSliderSettings(sender: view, title: L10n.Pdf.AnnotationPopover.lineWidth, initialValue: self.viewModel.state.activeLineWidth,
                                                                         valueChanged: { [weak self] newValue in
                                self?.viewModel.process(action: .setActiveLineWidth(newValue))
                            })
                            if self.pdfController.annotationStateManager.state != .ink {
                                self.toggle(annotationTool: .ink, tappedWithStylus: (self.lastGestureRecognizerTouch?.type == .stylus))
                            }
                        }
                    })
                    .disposed(by: self.disposeBag)

        let inkTap = UITapGestureRecognizer()
        inkTap.delegate = self
        inkTap.rx
              .event
              .subscribe(with: self, onNext: { `self`, _ in
                  self.toggle(annotationTool: .ink, tappedWithStylus: (self.lastGestureRecognizerTouch?.type == .stylus))
              })
              .disposed(by: self.disposeBag)
        inkTap.require(toFail: inkLongPress)

        let ink = CheckboxButton(type: .custom)
        ink.accessibilityLabel = L10n.Accessibility.Pdf.inkAnnotationTool
        ink.setImage(Asset.Images.Annotations.inkLarge.image.withRenderingMode(.alwaysTemplate), for: .normal)
        ink.tintColor = Asset.Colors.zoteroBlueWithDarkMode.color
        ink.addGestureRecognizer(inkLongPress)
        ink.addGestureRecognizer(inkTap)
        self.createInkButton = ink

        let eraserLongPress = UILongPressGestureRecognizer()
        eraserLongPress.delegate = self
        eraserLongPress.rx
                    .event
                    .subscribe(with: self, onNext: { `self`, recognizer in
                        if recognizer.state == .began, let view = recognizer.view {
                            self.coordinatorDelegate?.showSliderSettings(sender: view, title: L10n.Pdf.AnnotationPopover.size, initialValue: self.viewModel.state.activeEraserSize,
                                                                         valueChanged: { [weak self] newValue in
                                self?.viewModel.process(action: .setActiveEraserSize(newValue))
                            })
                            if self.pdfController.annotationStateManager.state != .eraser {
                                self.toggle(annotationTool: .eraser, tappedWithStylus: (self.lastGestureRecognizerTouch?.type == .stylus))
                            }
                        }
                    })
                    .disposed(by: self.disposeBag)

        let eraserTap = UITapGestureRecognizer()
        eraserTap.delegate = self
        eraserTap.rx
              .event
              .subscribe(with: self, onNext: { `self`, _ in
                  self.toggle(annotationTool: .eraser, tappedWithStylus: (self.lastGestureRecognizerTouch?.type == .stylus))
              })
              .disposed(by: self.disposeBag)
        eraserTap.require(toFail: eraserLongPress)

        let eraser = CheckboxButton(type: .custom)
        eraser.accessibilityLabel = L10n.Accessibility.Pdf.eraserAnnotationTool
        eraser.setImage(Asset.Images.Annotations.eraserLarge.image.withRenderingMode(.alwaysTemplate), for: .normal)
        eraser.tintColor = Asset.Colors.zoteroBlueWithDarkMode.color
        eraser.addGestureRecognizer(eraserLongPress)
        eraser.addGestureRecognizer(eraserTap)
        self.createEraserButton = eraser

        [highlight, note, area, ink, eraser].forEach { button in
            button.adjustsImageWhenHighlighted = false
            button.selectedBackgroundColor = Asset.Colors.zoteroBlue.color
            button.selectedTintColor = .white
            button.layer.cornerRadius = 4
            button.layer.masksToBounds = true
        }

        let picker = UIButton()
        picker.accessibilityLabel = L10n.Accessibility.Pdf.colorPicker
        picker.setImage(UIImage(systemName: "circle.fill", withConfiguration: symbolConfig), for: .normal)
        picker.tintColor = self.viewModel.state.activeColor
        picker.rx.controlEvent(.touchUpInside)
                 .subscribe(onNext: { [weak self] _ in
                    self?.showColorPicker(sender: picker)
                 })
                 .disposed(by: self.disposeBag)
        self.colorPickerbutton = picker

        let size: CGFloat = 36

        NSLayoutConstraint.activate([
            highlight.widthAnchor.constraint(equalToConstant: size),
            highlight.heightAnchor.constraint(equalToConstant: size),
            note.widthAnchor.constraint(equalToConstant: size),
            note.heightAnchor.constraint(equalToConstant: size),
            area.widthAnchor.constraint(equalToConstant: size),
            area.heightAnchor.constraint(equalToConstant: size),
            ink.widthAnchor.constraint(equalToConstant: size),
            ink.heightAnchor.constraint(equalToConstant: size),
            picker.widthAnchor.constraint(equalToConstant: size),
            picker.heightAnchor.constraint(equalToConstant: size),
            eraser.widthAnchor.constraint(equalToConstant: size),
            eraser.heightAnchor.constraint(equalToConstant: size),
        ])

        return [highlight, note, area, ink, eraser, picker]
    }

    private func setupNavigationBar() {
        let sidebarButton = UIBarButtonItem(image: UIImage(systemName: "sidebar.left"), style: .plain, target: nil, action: nil)
        sidebarButton.accessibilityLabel = self.isSidebarVisible ? L10n.Accessibility.Pdf.sidebarClose : L10n.Accessibility.Pdf.sidebarOpen
        sidebarButton.rx.tap
                     .subscribe(with: self, onNext: { `self`, _ in self.toggleSidebar(animated: true) })
                     .disposed(by: self.disposeBag)
        let closeButton = UIBarButtonItem(image: UIImage(systemName: "chevron.left"), style: .plain, target: nil, action: nil)
        closeButton.rx.tap
                   .subscribe(with: self, onNext: { `self`, _ in self.close() })
                   .disposed(by: self.disposeBag)
        let readerButton = UIBarButtonItem(image: self.pdfController.readerViewButtonItem.image, style: .plain, target: nil, action: nil)
        readerButton.accessibilityLabel = self.isSidebarVisible ? L10n.Accessibility.Pdf.sidebarClose : L10n.Accessibility.Pdf.sidebarOpen
        readerButton.rx.tap
                    .subscribe(with: self, onNext: { `self`, _ in self.coordinatorDelegate?.showReader(document: self.viewModel.state.document) })
                    .disposed(by: self.disposeBag)

        self.navigationItem.leftBarButtonItems = [closeButton, sidebarButton, readerButton]
        self.navigationItem.rightBarButtonItems = self.createRightBarButtonItems(forCompactSize: self.isCompactSize)
    }

    private func createRightBarButtonItems(forCompactSize isCompact: Bool) -> [UIBarButtonItem] {
        if isCompact {
            return [self.settingsButton, self.shareButton, self.searchButton]
        }
        return [self.settingsButton, self.shareButton, self.redoButton, self.undoButton, self.searchButton]
    }

    private func setupObserving() {
        self.viewModel.stateObservable
                      .observe(on: MainScheduler.instance)
                      .subscribe(onNext: { [weak self] state in
                          self?.update(state: state)
                      })
                      .disposed(by: self.disposeBag)

        NotificationCenter.default.rx
                                  .notification(UIApplication.didBecomeActiveNotification)
                                  .observe(on: MainScheduler.instance)
                                  .subscribe(onNext: { [weak self] notification in
                                      guard let `self` = self else { return }
                                      self.viewModel.process(action: .updateAnnotationPreviews)
                                      self.updatePencilSettingsIfNeeded()
                                  })
                                  .disposed(by: self.disposeBag)
    }
}

extension PDFReaderViewController: PDFViewControllerDelegate {
    func pdfViewController(_ pdfController: PDFViewController, willBeginDisplaying pageView: PDFPageView, forPageAt pageIndex: Int) {
        // This delegate method is called for incorrect page index when sidebar is changing size. So if the sidebar is opened/closed, incorrect page
        // is stored in `pageController` and if the user closes the pdf reader without further scrolling, incorrect page is shown on next opening.
        guard !self.isSidebarTransitioning else { return }
        // Save current page
        self.viewModel.process(action: .setVisiblePage(pageIndex))
    }

    func pdfViewController(_ pdfController: PDFViewController, shouldShow controller: UIViewController, options: [String : Any]? = nil, animated: Bool) -> Bool {
        return false
    }

    func pdfViewController(_ pdfController: PDFViewController, shouldShow menuItems: [MenuItem], atSuggestedTargetRect rect: CGRect, for annotations: [PSPDFKit.Annotation]?, in annotationRect: CGRect,
                           on pageView: PDFPageView) -> [MenuItem] {
        guard annotations == nil && self.viewModel.state.library.metadataEditable else { return [] }

        let pageRect = pageView.convert(rect, to: pageView.pdfCoordinateSpace)

        return [MenuItem(title: "Note", block: { [weak self] in
                    self?.viewModel.process(action: .create(annotation: .note, pageIndex: pageView.pageIndex, origin: pageRect.origin))
                }),
                MenuItem(title: "Image", block: { [weak self] in
                    self?.viewModel.process(action: .create(annotation: .image, pageIndex: pageView.pageIndex, origin: pageRect.origin))
                })]
    }

    func pdfViewController(_ pdfController: PDFViewController, shouldShow menuItems: [MenuItem], atSuggestedTargetRect rect: CGRect,
                           forSelectedText selectedText: String, in textRect: CGRect, on pageView: PDFPageView) -> [MenuItem] {
        let identifiers: [String]
        if self.viewModel.state.library.metadataEditable {
            identifiers = [TextMenu.copy.rawValue, TextMenu.annotationMenuHighlight.rawValue, TextMenu.define.rawValue, TextMenu.search.rawValue, TextMenu.speak.rawValue, TextMenu.share.rawValue]
        } else {
            identifiers = [TextMenu.copy.rawValue, TextMenu.define.rawValue, TextMenu.search.rawValue, TextMenu.speak.rawValue, TextMenu.share.rawValue]
        }

        // Filter unwanted items
        let filtered = menuItems.filter({ item in
            guard let identifier = item.identifier else { return false }
            return identifiers.contains(identifier)
        })

        // Overwrite highlight title
        if let idx = filtered.firstIndex(where: { $0.identifier == TextMenu.annotationMenuHighlight.rawValue }) {
            filtered[idx].title = L10n.Pdf.highlight
        }

        // Overwrite share action, because the original one reports "[ShareSheet] connection invalidated".
        if let idx = filtered.firstIndex(where: { $0.identifier == TextMenu.share.rawValue }) {
            filtered[idx].actionBlock = { [weak self] in
                guard let view = self?.pdfController.view else { return }
                self?.coordinatorDelegate?.share(text: selectedText, rect: rect, view: view)
            }
        }

        // Overwrite define action, because the original one doesn't show anything.
        if let idx = filtered.firstIndex(where: { $0.identifier == TextMenu.define.rawValue }) {
            filtered[idx].title = L10n.lookUp
            filtered[idx].actionBlock = { [weak self] in
                guard let view = self?.pdfController.view else { return }
                self?.coordinatorDelegate?.lookup(text: selectedText, rect: rect, view: view)
            }
        }

        if let idx = filtered.firstIndex(where: { $0.identifier == TextMenu.search.rawValue }) {
            filtered[idx].actionBlock = { [weak self] in
                guard let `self` = self else { return }
                self.showSearch(sender: self.searchButton, text: selectedText)
            }
        }

        return filtered
    }

    func pdfViewController(_ pdfController: PDFViewController, shouldSave document: PSPDFKit.Document, withOptions options: AutoreleasingUnsafeMutablePointer<NSDictionary>) -> Bool {
        return false
    }
}

extension PDFReaderViewController: AnnotationStateManagerDelegate {
    func annotationStateManager(_ manager: AnnotationStateManager,
                                didChangeState oldState: PSPDFKit.Annotation.Tool?,
                                to newState: PSPDFKit.Annotation.Tool?,
                                variant oldVariant: PSPDFKit.Annotation.Variant?,
                                to newVariant: PSPDFKit.Annotation.Variant?) {
        if let state = oldState {
            switch state {
            case .note:
                self.createNoteButton.isSelected = false
            case .highlight:
                self.createHighlightButton.isSelected = false
            case .square:
                self.createAreaButton.isSelected = false
            case .ink:
                self.createInkButton.isSelected = false
            case .eraser:
                self.createEraserButton.isSelected = false
            default: break
            }
        }

        if let state = newState {
            switch state {
            case .note:
                self.createNoteButton.isSelected = true
            case .highlight:
                self.createHighlightButton.isSelected = true
            case .square:
                self.createAreaButton.isSelected = true
            case .ink:
                self.createInkButton.isSelected = true
            case .eraser:
                self.createEraserButton.isSelected = true
            default: break
            }
        }
    }

    func annotationStateManager(_ manager: AnnotationStateManager, didChangeUndoState undoEnabled: Bool, redoState redoEnabled: Bool) {
        self.redoButton.isEnabled = redoEnabled
        self.undoButton.isEnabled = undoEnabled
    }
}

extension PDFReaderViewController: UIPencilInteractionDelegate {
    func pencilInteractionDidTap(_ interaction: UIPencilInteraction) {
        switch UIPencilInteraction.preferredTapAction {
        case .switchEraser:
            self.toggle(annotationTool: .eraser, tappedWithStylus: false)

        case .showColorPalette:
            self.showColorPicker(sender: self.colorPickerbutton)

        case .switchPrevious, .showInkAttributes, .ignore: break

        @unknown default: break
        }
    }
}

extension PDFReaderViewController: UIPopoverPresentationControllerDelegate {
    func popoverPresentationControllerDidDismissPopover(_ popoverPresentationController: UIPopoverPresentationController) {
        if self.viewModel.state.selectedAnnotation?.type == .highlight {
            self.viewModel.process(action: .deselectSelectedAnnotation)
        }
    }
}

extension PDFReaderViewController: AnnotationBoundingBoxConverter {
    /// Converts from database to PSPDFKit rect. Database stores rects in RAW PDF Coordinate space. PSPDFKit works with Normalized PDF Coordinate Space.
    func convertFromDb(rect: CGRect, page: PageIndex) -> CGRect? {
        guard let pageInfo = self.viewModel.state.document.pageInfoForPage(at: page) else { return nil }
        return rect.applying(pageInfo.transform)
    }

    func convertFromDb(point: CGPoint, page: PageIndex) -> CGPoint? {
        let tmpRect = CGRect(origin: point, size: CGSize(width: 1, height: 1))
        return self.convertFromDb(rect: tmpRect, page: page)?.origin
    }

    /// Converts from PSPDFKit to database rect. Database stores rects in RAW PDF Coordinate space. PSPDFKit works with Normalized PDF Coordinate Space.
    func convertToDb(rect: CGRect, page: PageIndex) -> CGRect? {
        guard let pageInfo = self.viewModel.state.document.pageInfoForPage(at: page) else { return nil }
        return rect.applying(pageInfo.transform.inverted())
    }

    func convertToDb(point: CGPoint, page: PageIndex) -> CGPoint? {
        let tmpRect = CGRect(origin: point, size: CGSize(width: 1, height: 1))
        return self.convertToDb(rect: tmpRect, page: page)?.origin
    }

    /// Converts from PSPDFKit to sort index rect. PSPDFKit works with Normalized PDF Coordinate Space. Sort index stores y coordinate in RAW View Coordinate Space.
    func sortIndexMinY(rect: CGRect, page: PageIndex) -> CGFloat? {
        guard let pageInfo = self.viewModel.state.document.pageInfoForPage(at: page) else { return nil }

        switch pageInfo.savedRotation {
        case .rotation0:
            return pageInfo.size.height - rect.maxY
        case .rotation180:
            return rect.minY
        case .rotation90:
            return pageInfo.size.width - rect.minX
        case .rotation270:
            return rect.minX
        }
    }

    func textOffset(rect: CGRect, page: PageIndex) -> Int? {
        guard let parser = self.viewModel.state.document.textParserForPage(at: page), !parser.glyphs.isEmpty else { return nil }

        var index = 0
        var minDistance: CGFloat = .greatestFiniteMagnitude
        var textOffset = 0

        for glyph in parser.glyphs {
            guard !glyph.isWordOrLineBreaker else { continue }

            let distance = rect.distance(to: glyph.frame)

            if distance < minDistance {
                minDistance = distance
                textOffset = index
            }

            index += 1
        }

        return textOffset
    }
}

extension PDFReaderViewController: ConflictViewControllerReceiver {
    func shows(object: SyncObject, libraryId: LibraryIdentifier) -> String? {
        guard object == .item && libraryId == self.viewModel.state.library.identifier else { return nil }
        return self.viewModel.state.key
    }

    func canDeleteObject(completion: @escaping (Bool) -> Void) {
        self.coordinatorDelegate?.showDeletedAlertForPdf(completion: completion)
    }
}

final class SelectionView: UIView {
    static let inset: CGFloat = 4.5 // 2.5 for border, 2 for padding

    init() {
        super.init(frame: CGRect())
        self.commonSetup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        self.commonSetup()
    }

    private func commonSetup() {
        self.backgroundColor = .clear
        self.autoresizingMask = [.flexibleTopMargin, .flexibleLeftMargin, .flexibleBottomMargin, .flexibleRightMargin, .flexibleWidth, .flexibleHeight]
        self.layer.borderColor = Asset.Colors.annotationHighlightSelection.color.cgColor
        self.layer.borderWidth = 2.5
        self.layer.cornerRadius = 2.5
        self.layer.masksToBounds = true
    }
}

extension PDFReaderViewController: UIGestureRecognizerDelegate {
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        self.lastGestureRecognizerTouch = touch
        return true
    }
}

extension PDFReaderViewController: SidebarDelegate {
    func tableOfContentsSelected(page: UInt) {
        self.scrollIfNeeded(to: page, animated: true, completion: {})

        if UIDevice.current.userInterfaceIdiom == .phone {
            self.toggleSidebar(animated: true)
        }
    }
}

#endif
