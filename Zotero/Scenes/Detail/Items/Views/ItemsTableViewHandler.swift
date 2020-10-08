//
//  ItemsTableViewHandler.swift
//  Zotero
//
//  Created by Michal Rentka on 24/02/2020.
//  Copyright © 2020 Corporation for Digital Scholarship. All rights reserved.
//

import UIKit

import CocoaLumberjackSwift
import RxCocoa
import RxSwift

class ItemsTableViewHandler: NSObject {
    enum Action {
        case editing(isEditing: Bool, animated: Bool)
        case reloadAll
        case reload(modifications: [Int], insertions: [Int], deletions: [Int])
        case updateVisibleCell(attachment: Attachment?, parentKey: String)
        case selectAll
        case deselectAll
    }

    private static let maxUpdateCount = 200
    private static let cellId = "ItemCell"
    private unowned let tableView: UITableView
    private unowned let viewModel: ViewModel<ItemsActionHandler>
    private unowned let dragDropController: DragDropController
    let tapObserver: PublishSubject<RItem>
    private let disposeBag: DisposeBag

    private var queue: [Action]
    private var isPerformingAction: Bool
    private var shouldBatchReloads: Bool
    private var pendingUpdateCount: Int
    private var batchTimerScheduler: ConcurrentDispatchQueueScheduler
    private var batchTimerDisposeBag: DisposeBag?
    private weak var fileDownloader: FileDownloader?
    private weak var coordinatorDelegate: DetailItemsCoordinatorDelegate?

    init(tableView: UITableView, viewModel: ViewModel<ItemsActionHandler>, dragDropController: DragDropController, fileDownloader: FileDownloader?) {
        self.tableView = tableView
        self.viewModel = viewModel
        self.dragDropController = dragDropController
        self.fileDownloader = fileDownloader
        self.queue = []
        self.isPerformingAction = false
        self.shouldBatchReloads = false
        self.pendingUpdateCount = 0
        self.batchTimerScheduler = ConcurrentDispatchQueueScheduler(qos: .utility)
        self.tapObserver = PublishSubject()
        self.disposeBag = DisposeBag()

        super.init()

        self.setupTableView()
        self.setupKeyboardObserving()
    }

    // MARK: - Data source

    func sourceDataForCell(for key: String) -> (UIView, CGRect?) {
        let cell = self.tableView.visibleCells.first(where: { ($0 as? ItemCell)?.key == key })
        return (self.tableView, cell?.frame)
    }

    // MARK: - Actions

    /// Start batching table view updates.
    func startBatchingUpdates() {
        self.shouldBatchReloads = true
    }

    /// Stop batching table view updates.
    func stopBatchingUpdates() {
        guard self.shouldBatchReloads else { return }

        // Stop batching
        self.shouldBatchReloads = false
        // Stop timer
        self.batchTimerDisposeBag = nil
        // Reset pending updates
        self.pendingUpdateCount = 0
        // Perform next (pending) action if needed
        self.performNextAction()
    }

    func enqueue(action: Action) {
        inMainThread { [weak self] in
            self?._enqueue(action)
        }
    }

    private func updateCell(with attachment: Attachment?, parentKey: String) {
        guard let cell = self.tableView.visibleCells.first(where: { ($0 as? ItemCell)?.key == parentKey }) as? ItemCell else { return }

        if let attachment = attachment {
            let (progress, error) = self.fileDownloader?.data(for: attachment.key, libraryId: attachment.libraryId) ?? (nil, nil)
            cell.set(contentType: attachment.contentType, progress: progress, error: error)
        } else {
            cell.clearAttachment()
        }
    }

    private func reload(modifications: [Int], insertions: [Int], deletions: [Int], completion: @escaping () -> Void) {
        self.tableView.performBatchUpdates({
            self.tableView.deleteRows(at: deletions.map({ IndexPath(row: $0, section: 0) }), with: .automatic)
            self.tableView.reloadRows(at: modifications.map({ IndexPath(row: $0, section: 0) }), with: .none)
            self.tableView.insertRows(at: insertions.map({ IndexPath(row: $0, section: 0) }), with: .automatic)
        }, completion: { _ in
            completion()
        })
    }

    private func selectAll() {
        let rows = self.tableView(self.tableView, numberOfRowsInSection: 0)
        (0..<rows).forEach { row in
            self.tableView.selectRow(at: IndexPath(row: row, section: 0), animated: false, scrollPosition: .none)
        }
    }

    private func deselectAll() {
        self.tableView.indexPathsForSelectedRows?.forEach({ indexPath in
            self.tableView.deselectRow(at: indexPath, animated: false)
        })
    }

    // MARK: - Queue

    private func _enqueue(_ action: Action) {
        // Reset batch timer
        self.batchTimerDisposeBag = nil

        // Enqueue new action(s)
        var shouldDelay = false
        switch action {
        case .reloadAll:
            // Don't delay even when `shouldBatchReloads` is `true`, `reloadAll` is called when new data is presented during user actions (i. e. sort change), so it needs to be instant.
            self.enqueueReloadAll()

        case .reload(let modifications, let insertions, let deletions):
            shouldDelay = !self.enqueueReload(modifications: modifications, insertions: insertions, deletions: deletions)

        default:
            self.queue.append(action)
        }

        if !shouldDelay {
            // Perform new action immediately if delay is not needed
            self.performNextAction()
            return
        }

        // Create a batch delay
        let disposeBag = DisposeBag()
        Single<Int>.timer(.milliseconds(750), scheduler: self.self.batchTimerScheduler)
                   .observeOn(MainScheduler.instance)
                   .subscribe(onSuccess: { [weak self] _ in
                       self?.performNextAction()
                   })
                   .disposed(by: disposeBag)
        self.batchTimerDisposeBag = disposeBag
    }

    /// Enqueues `Action.reloadAll`. Removes all other reload actions from queue, since tableView will be reloaded. Moves all other (user) actions after this `reloadAll` action.
    private func enqueueReloadAll() {
        if !self.queue.isEmpty, case .reloadAll = self.queue[0] { return }

        self.queue.removeAll(where: {
            switch $0 {
            case .reload, .updateVisibleCell, .reloadAll:
                return true
            case .selectAll, .deselectAll, .editing:
                return false
            }
        })
        self.queue.insert(.reloadAll, at: 0)
    }

    /// Enqueues `Action.reload(...)`.
    ///
    /// During initial sync, for users with many items, when there are many updates, an update is reported each 0.5s. This puts big pressure on the tableView
    /// and it becomes laggy. So these updates will be batched and tableView will be reloaded after each batch to increase times between reloads.
    /// These delays are put only on this action so that the tableView remains responsive for other (user) actions.
    /// - parameter modifications: Modifications to apply to tableView.
    /// - parameter insertions: Insertions to apply to tableView.
    /// - parameter deletions: Deletions to apply to tableView.
    /// - returns: `true` if update limit has been passed and tableView should be reloaded, `false` otherwise.
    private func enqueueReload(modifications: [Int], insertions: [Int], deletions: [Int]) -> Bool {
        if !self.shouldBatchReloads {
            self.queue.append(.reload(modifications: modifications, insertions: insertions, deletions: deletions))
            return true
        }

        self.pendingUpdateCount += modifications.count + insertions.count + deletions.count
        self.enqueueReloadAll()

        if self.pendingUpdateCount > ItemsTableViewHandler.maxUpdateCount {
            self.pendingUpdateCount = 0
            return true
        }

        return false
    }

    private func performNextAction() {
        guard !self.isPerformingAction && !self.queue.isEmpty else { return }
        self.perform(action: self.queue.removeFirst())
    }

    private func perform(action: Action) {
        self.isPerformingAction = true

        let start = CFAbsoluteTimeGetCurrent()
        DDLogInfo("ItemsTableViewHandler: perform \(action)")

        let actionCompletion: () -> Void = { [weak self] in
            DDLogInfo("ItemsTableViewHandler: did perform action in \(CFAbsoluteTimeGetCurrent() - start)")
            self?.isPerformingAction = false
            self?.performNextAction()
        }

        switch action {
        case .deselectAll:
            self.deselectAll()
            actionCompletion()
        case .selectAll:
            self.selectAll()
            actionCompletion()
        case .editing(let isEditing, let animated):
            self.tableView.setEditing(isEditing, animated: animated)
            actionCompletion()
        case .reload(let modifications, let insertions, let deletions):
            self.reload(modifications: modifications, insertions: insertions, deletions: deletions, completion: actionCompletion)
        case .reloadAll:
            self.tableView.reloadData()
            actionCompletion()
        case .updateVisibleCell(let attachment, let parentKey):
            self.updateCell(with: attachment, parentKey: parentKey)
            actionCompletion()
        }
    }

    // MARK: - Setups

    private func setupTableView() {
        self.tableView.delegate = self
        self.tableView.dataSource = self
        self.tableView.dragDelegate = self
        self.tableView.dropDelegate = self
        self.tableView.rowHeight = UITableView.automaticDimension
        self.tableView.estimatedRowHeight = 60
        self.tableView.allowsMultipleSelectionDuringEditing = true
        self.tableView.keyboardDismissMode = UIDevice.current.userInterfaceIdiom == .phone ? .interactive : .none

        self.tableView.register(UINib(nibName: "ItemCell", bundle: nil), forCellReuseIdentifier: ItemsTableViewHandler.cellId)
        self.tableView.tableFooterView = UIView()
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

extension ItemsTableViewHandler: UITableViewDataSource {
    func numberOfSections(in tableView: UITableView) -> Int {
        return 1
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return self.viewModel.state.results?.count ?? 0
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: ItemsTableViewHandler.cellId, for: indexPath)

        if let item = self.viewModel.state.results?[indexPath.row],
           let cell = cell as? ItemCell {
            // Create and cache attachment if needed
            self.viewModel.process(action: .cacheAttachment(item: item))

            let parentKey = item.key
            let attachment = self.viewModel.state.attachments[parentKey]
            let attachmentData: ItemCellAttachmentData? = attachment.flatMap({ attachment in
                let (progress, error) = self.fileDownloader?.data(for: attachment.key, libraryId: attachment.libraryId) ?? (nil, nil)
                return (attachment.contentType, progress, error)
            })

            cell.set(item: ItemCellModel(item: item, attachment: attachmentData), tapAction: { [weak self] in
                guard let key = attachment?.key else { return }
                self?.viewModel.process(action: .openAttachment(key: key, parentKey: parentKey))
            })
        }

        return cell
    }
}

extension ItemsTableViewHandler: UITableViewDelegate {
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        guard let item = self.viewModel.state.results?[indexPath.row] else { return }

        if self.viewModel.state.isEditing {
            self.viewModel.process(action: .selectItem(item.key))
        } else {
            tableView.deselectRow(at: indexPath, animated: true)
            self.tapObserver.on(.next(item))
        }
    }

    func tableView(_ tableView: UITableView, didDeselectRowAt indexPath: IndexPath) {
        if self.viewModel.state.isEditing,
           let item = self.viewModel.state.results?[indexPath.row] {
            self.viewModel.process(action: .deselectItem(item.key))
        }
    }

    func tableView(_ tableView: UITableView, shouldBeginMultipleSelectionInteractionAt indexPath: IndexPath) -> Bool {
        return tableView.isEditing
    }
}

extension ItemsTableViewHandler: UITableViewDragDelegate {
    func tableView(_ tableView: UITableView, itemsForBeginning session: UIDragSession, at indexPath: IndexPath) -> [UIDragItem] {
        guard let item = self.viewModel.state.results?[indexPath.row] else { return [] }
        return [self.dragDropController.dragItem(from: item)]
    }
}

extension ItemsTableViewHandler: UITableViewDropDelegate {
    func tableView(_ tableView: UITableView, performDropWith coordinator: UITableViewDropCoordinator) {
        guard let indexPath = coordinator.destinationIndexPath,
              let key = self.viewModel.state.results?[indexPath.row].key else { return }

        switch coordinator.proposal.operation {
        case .move:
            self.dragDropController.itemKeys(from: coordinator.items) { [weak self] keys in
                self?.viewModel.process(action: .moveItems(keys, key))
            }
        default: break
        }
    }

    func tableView(_ tableView: UITableView,
                   dropSessionDidUpdate session: UIDropSession,
                   withDestinationIndexPath destinationIndexPath: IndexPath?) -> UITableViewDropProposal {
        if !self.viewModel.state.library.metadataEditable {
            return UITableViewDropProposal(operation: .forbidden)
        }

        // Allow only local drag session
        guard session.localDragSession != nil else {
            return UITableViewDropProposal(operation: .forbidden)
        }

        // Allow dropping only to non-standalone items
        if let item = destinationIndexPath.flatMap({ self.viewModel.state.results?[$0.row] }),
           (item.rawType == ItemTypes.note || item.rawType == ItemTypes.attachment) {
           return UITableViewDropProposal(operation: .forbidden)
        }

        // Allow drops of only standalone items
        if session.items.compactMap({ self.dragDropController.item(from: $0) })
                        .contains(where: { $0.rawType != ItemTypes.attachment && $0.rawType != ItemTypes.note }) {
            return UITableViewDropProposal(operation: .forbidden)
        }

        return UITableViewDropProposal(operation: .move, intent: .insertIntoDestinationIndexPath)
    }
}
