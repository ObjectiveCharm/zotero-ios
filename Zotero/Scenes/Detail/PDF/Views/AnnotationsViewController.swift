//
//  AnnotationsViewController.swift
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

protocol SidebarParent: AnyObject {
    var isSidebarVisible: Bool { get }
}

typealias AnnotationsViewControllerAction = (AnnotationView.Action, Annotation, UIButton) -> Void

final class AnnotationsViewController: UIViewController {
    private static let cellId = "AnnotationCell"
    private let viewModel: ViewModel<PDFReaderActionHandler>
    private let disposeBag: DisposeBag

    private weak var tableView: UITableView!
    private var dataSource: UITableViewDiffableDataSource<Int, Annotation>!
    private var searchController: UISearchController!
    private var isVisible: Bool

    weak var sidebarParent: SidebarParent?
    weak var coordinatorDelegate: DetailAnnotationsCoordinatorDelegate?

    // MARK: - Lifecycle

    init(viewModel: ViewModel<PDFReaderActionHandler>) {
        self.viewModel = viewModel
        self.isVisible = false
        self.disposeBag = DisposeBag()
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        self.definesPresentationContext = true
        self.view.backgroundColor = .systemGray6
        self.setupTableView()
        self.setupSearchController()
        self.setupKeyboardObserving()

        self.viewModel.stateObservable
                      .observeOn(MainScheduler.instance)
                      .subscribe(onNext: { [weak self] state in
                          self?.update(state: state)
                      })
                      .disposed(by: self.disposeBag)

        self.viewModel.process(action: .startObservingAnnotationChanges)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        self.isVisible = true
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        self.isVisible = false
    }

    deinit {
        DDLogInfo("AnnotationsViewController deinitialized")
    }

    // MARK: - Actions

    private func perform(action: AnnotationView.Action, annotation: Annotation) {
        let state = self.viewModel.state

        guard state.library.metadataEditable else { return }

        switch action {
        case .tags:
            guard annotation.isAuthor else { return }
            let selected = Set(annotation.tags.map({ $0.name }))
            self.coordinatorDelegate?.showTagPicker(libraryId: state.library.identifier, selected: selected, picked: { [weak self] tags in
                self?.viewModel.process(action: .setTags(tags, annotation.key))
            })

        case .options(let sender):
            self.coordinatorDelegate?.showCellOptions(for: annotation, sender: sender,
                                                      saveAction: { [weak self] annotation in
                                                          self?.viewModel.process(action: .updateAnnotationProperties(annotation))
                                                      },
                                                      deleteAction: { [weak self] annotation in
                                                          self?.viewModel.process(action: .removeAnnotation(annotation))
                                                      })

        case .setComment(let comment):
            self.viewModel.process(action: .setComment(key: annotation.key, comment: comment))

        case .reloadHeight:
            self.updateCellHeight()
            self.focusSelectedCell()

        case .setCommentActive(let isActive):
            self.viewModel.process(action: .setCommentActive(isActive))

        case .done: break // Done button doesn't appear here
        }
    }

    private func update(state: PDFReaderState) {
        self.reloadIfNeeded(for: state) {
            if let keys = state.loadedPreviewImageAnnotationKeys {
                self.updatePreviewsIfVisible(for: keys)
            }

            if let indexPath = state.focusSidebarIndexPath {
                self.tableView.selectRow(at: indexPath, animated: true, scrollPosition: .middle)
            }
        }
    }

    /// Updates `UIImage` of `SquareAnnotation` preview if the cell is currently on screen.
    /// - parameter keys: Set of keys to update.
    private func updatePreviewsIfVisible(for keys: Set<String>) {
        let cells = self.tableView.visibleCells.compactMap({ $0 as? AnnotationCell }).filter({ keys.contains($0.key) })

        for cell in cells {
            let image = self.viewModel.state.previewCache.object(forKey: (cell.key as NSString))
            cell.updatePreview(image: image)
        }
    }

    /// Reloads tableView if needed, based on new state. Calls completion either when reloading finished or when there was no reload.
    /// - parameter state: Current state.
    /// - parameter completion: Called after reload was performed or even if there was no reload.
    private func reloadIfNeeded(for state: PDFReaderState, completion: @escaping () -> Void) {
        let reloadVisibleCells: ([IndexPath]) -> Void = { indexPaths in
            for indexPath in indexPaths {
                guard let cell = self.tableView.cellForRow(at: indexPath) as? AnnotationCell else { continue }
                if let annotations = state.annotations[indexPath.section], indexPath.row < annotations.count {
                    self.setup(cell: cell, with: annotations[indexPath.row], state: state)
                }
            }
        }

        if !state.changes.contains(.annotations) && (state.changes.contains(.selection) || state.changes.contains(.activeComment)) {
            // Reload updated cells which are visible
            if let indexPaths = state.updatedAnnotationIndexPaths {
                reloadVisibleCells(indexPaths)
            }

            self.updateCellHeight()
            self.focusSelectedCell()

            completion()
            return
        }

        guard state.changes.contains(.annotations) || state.changes.contains(.interfaceStyle) else {
            completion()
            return
        }

        if state.document.pageCount == 0 {
            DDLogWarn("AnnotationsViewController: trying to reload empty document")
            completion()
            return
        }

        let isVisible = self.sidebarParent?.isSidebarVisible ?? false

        var snapshot = NSDiffableDataSourceSnapshot<Int, Annotation>()
        snapshot.appendSections(Array(0..<Int(state.document.pageCount)))
        for (page, annotations) in state.annotations {
            guard page < state.document.pageCount else {
                DDLogWarn("AnnotationsViewController: annotations page (\(page)) outside of document bounds (\(state.document.pageCount))")
                continue
            }
            snapshot.appendItems(annotations, toSection: page)
        }

        self.dataSource.apply(snapshot, animatingDifferences: isVisible, completion: {
            // Update selection if needed
            if let indexPaths = state.updatedAnnotationIndexPaths {
                reloadVisibleCells(indexPaths)
            }
            completion()
        })
    }

    /// Updates tableView layout in case any cell changed height.
    private func updateCellHeight() {
        self.tableView.beginUpdates()
        self.tableView.endUpdates()
    }

    /// Scrolls to selected cell if it's not visible.
    private func focusSelectedCell() {
        guard let indexPath = self.tableView.indexPathForSelectedRow else { return }

        let cellBottom = self.tableView.rectForRow(at: indexPath).maxY - self.tableView.contentOffset.y
        let tableViewBottom = self.tableView.superview!.bounds.maxY - self.tableView.contentInset.bottom

        guard cellBottom > tableViewBottom else { return }

        self.tableView.scrollToRow(at: indexPath, at: .bottom, animated: false)
    }

    private func setup(cell: AnnotationCell, with annotation: Annotation, state: PDFReaderState) {
        let hasWritePermission = state.library.metadataEditable
        let comment = state.comments[annotation.key]
        let selected = annotation.key == state.selectedAnnotation?.key
        let preview: UIImage?

        if annotation.type != .image {
            preview = nil
        } else {
            preview = state.previewCache.object(forKey: (annotation.key as NSString))

            if preview == nil {
                self.viewModel.process(action: .requestPreviews(keys: [annotation.key], notify: true))
            }
        }

        cell.setup(with: annotation, attributedComment: comment, preview: preview, selected: selected, commentActive: state.selectedAnnotationCommentActive,
                   availableWidth: PDFReaderLayout.sidebarWidth, hasWritePermission: hasWritePermission)
        cell.actionPublisher.subscribe(onNext: { [weak self] action in
            self?.perform(action: action, annotation: annotation)
        })
        .disposed(by: cell.disposeBag)
    }

    // MARK: - Setups

    private func setupTableView() {
        let backgroundView = UIView()
        backgroundView.backgroundColor = .systemGray6

        let tableView = UITableView(frame: self.view.bounds, style: .plain)
        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.delegate = self
        tableView.prefetchDataSource = self
        tableView.separatorStyle = .none
        tableView.backgroundView = backgroundView
        tableView.register(AnnotationCell.self, forCellReuseIdentifier: AnnotationsViewController.cellId)

        self.view.addSubview(tableView)

        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: self.view.topAnchor),
            tableView.bottomAnchor.constraint(equalTo: self.view.bottomAnchor),
            tableView.leadingAnchor.constraint(equalTo: self.view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: self.view.trailingAnchor)
        ])

        let dataSource = UITableViewDiffableDataSource<Int, Annotation>(tableView: tableView) { [weak self] tableView, indexPath, model -> UITableViewCell? in
            guard let `self` = self else { return nil }

            let cell = tableView.dequeueReusableCell(withIdentifier: AnnotationsViewController.cellId, for: indexPath)
            cell.contentView.backgroundColor = self.view.backgroundColor
            if let cell = cell as? AnnotationCell {
                self.setup(cell: cell, with: model, state: self.viewModel.state)
            }
            return cell
        }

        self.tableView = tableView
        self.dataSource = dataSource
    }

    private func setupSearchController() {
        let insets = UIEdgeInsets(top: PDFReaderLayout.searchBarVerticalInset,
                                  left: PDFReaderLayout.annotationLayout.horizontalInset,
                                  bottom: PDFReaderLayout.searchBarVerticalInset - PDFReaderLayout.cellSelectionLineWidth,
                                  right: PDFReaderLayout.annotationLayout.horizontalInset)

        var frame = self.tableView.frame
        frame.size.height = 65

        let searchBar = SearchBar(frame: frame, insets: insets, cornerRadius: 10)
        searchBar.text.observeOn(MainScheduler.instance)
                                .debounce(.milliseconds(150), scheduler: MainScheduler.instance)
                                .subscribe(onNext: { [weak self] text in
                                    self?.viewModel.process(action: .searchAnnotations(text))
                                })
                                .disposed(by: self.disposeBag)
        self.tableView.tableHeaderView = searchBar
    }

    private func setupTableView(with keyboardData: KeyboardData) {
        var insets = self.tableView.contentInset
        insets.bottom = keyboardData.endFrame.height
        self.tableView.contentInset = insets
    }

    private func setupKeyboardObserving() {
        NotificationCenter.default
                          .keyboardWillShow
                          .observeOn(MainScheduler.instance)
                          .subscribe(onNext: { [weak self] notification in
                              if let data = notification.keyboardData {
                                  self?.setupTableView(with: data)
                              }
                          })
                          .disposed(by: self.disposeBag)

        NotificationCenter.default
                          .keyboardWillHide
                          .observeOn(MainScheduler.instance)
                          .subscribe(onNext: { [weak self] notification in
                              if let data = notification.keyboardData {
                                  self?.setupTableView(with: data)
                              }
                          })
                          .disposed(by: self.disposeBag)
    }
}

extension AnnotationsViewController: UITableViewDelegate, UITableViewDataSourcePrefetching {
    func tableView(_ tableView: UITableView, prefetchRowsAt indexPaths: [IndexPath]) {
        let keys = indexPaths.compactMap({ self.viewModel.state.annotations[$0.section]?[$0.row] }).map({ $0.key })
        self.viewModel.process(action: .requestPreviews(keys: keys, notify: false))
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        if let annotations = self.viewModel.state.annotations[indexPath.section], indexPath.row < annotations.count {
            self.viewModel.process(action: .selectAnnotation(annotations[indexPath.row]))
        }
    }
}

#endif
