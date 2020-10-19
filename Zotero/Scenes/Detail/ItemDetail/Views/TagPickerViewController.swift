//
//  TagPickerViewController.swift
//  Zotero
//
//  Created by Michal Rentka on 19/10/2020.
//  Copyright © 2020 Corporation for Digital Scholarship. All rights reserved.
//

import UIKit

import RxSwift

class TagPickerViewController: UIViewController {
    @IBOutlet private weak var tableView: UITableView!

    private static let cellId = "TagCell"
    private let viewModel: ViewModel<TagPickerActionHandler>
    private let saveAction: ([Tag]) -> Void
    private let disposeBag: DisposeBag

    private var dataSource: UITableViewDiffableDataSource<Int, Tag>!

    // MARK: - Lifecycle

    init(viewModel: ViewModel<TagPickerActionHandler>, saveAction: @escaping ([Tag]) -> Void) {
        self.viewModel = viewModel
        self.saveAction = saveAction
        self.disposeBag = DisposeBag()
        super.init(nibName: "TagPickerViewController", bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        self.setupTableView()
        self.setupSearchBar()
        self.setupNavigationBar()

        self.viewModel.stateObservable
                      .observeOn(MainScheduler.instance)
                      .subscribe(onNext: { [weak self] state in
                          self?.update(to: state)
                      })
                      .disposed(by: self.disposeBag)

        self.viewModel.process(action: .load)
    }

    // MARK: - Actions

    private func update(to state: TagPickerState) {
        if state.changes.contains(.tags) {
            self.tableView.reloadData()
            self.select(selected: state.selectedTags, tags: state.tags)
        }

        if let error = state.error {
            // TODO: - show error
        }
    }

    private func select(selected: Set<String>, tags: [Tag]) {
        for name in selected {
            guard let index = tags.firstIndex(where: { $0.name == name }) else { continue }
            self.tableView.selectRow(at: IndexPath(row: index, section: 0), animated: false, scrollPosition: .none)
        }
    }

    private func save() {
        let allTags = self.viewModel.state.snapshot ?? self.viewModel.state.tags
        let tags = self.viewModel.state.selectedTags.compactMap { id in
            allTags.first(where: { $0.id == id })
        }.sorted(by: { $0.name < $1.name })
        self.saveAction(tags)
    }

    // MARK: - Setups

    private func setupSearchBar() {
        let searchController = UISearchController()
        searchController.obscuresBackgroundDuringPresentation = false
        searchController.hidesNavigationBarDuringPresentation = false
        searchController.searchBar.placeholder = L10n.ItemDetail.searchTags
        searchController.searchBar.autocapitalizationType = .none

        searchController.searchBar.rx.text.observeOn(MainScheduler.instance)
                         .debounce(.milliseconds(150), scheduler: MainScheduler.instance)
                         .subscribe(onNext: { [weak self] text in
                            self?.viewModel.process(action: .search(text ?? ""))
                         })
                         .disposed(by: self.disposeBag)

        self.navigationItem.searchController = searchController
        self.navigationItem.hidesSearchBarWhenScrolling = false
    }

    private func setupTableView() {
        self.tableView.delegate = self
        self.tableView.dataSource = self
        self.tableView.allowsMultipleSelectionDuringEditing = true
        self.tableView.isEditing = true
        self.tableView.register(UINib(nibName: "ItemDetailTagCell", bundle: nil), forCellReuseIdentifier: TagPickerViewController.cellId)
    }

    private func setupNavigationBar() {
        let left = UIBarButtonItem(title: L10n.cancel, style: .plain, target: nil, action: nil)
        left.rx.tap
            .subscribe(onNext: { [weak self] in
                self?.navigationController?.dismiss(animated: true, completion: nil)
            })
            .disposed(by: self.disposeBag)
        self.navigationItem.leftBarButtonItem = left

        let right = UIBarButtonItem(title: L10n.save, style: .plain, target: nil, action: nil)
        right.rx.tap
             .subscribe(onNext: { [weak self] in
                 self?.save()
                 self?.navigationController?.dismiss(animated: true, completion: nil)
             })
             .disposed(by: self.disposeBag)
        self.navigationItem.rightBarButtonItem = right
    }
}

extension TagPickerViewController: UITableViewDataSource {
    func numberOfSections(in tableView: UITableView) -> Int {
        return 1
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return self.viewModel.state.tags.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: TagPickerViewController.cellId, for: indexPath)
        if let cell = cell as? ItemDetailTagCell {
            let tag = self.viewModel.state.tags[indexPath.row]
            cell.setup(with: tag, showEmptyTagCircle: false)
        }
        return cell
    }
}

extension TagPickerViewController: UITableViewDelegate {
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        let name = self.viewModel.state.tags[indexPath.row].name
        self.viewModel.process(action: .select(name))
    }

    func tableView(_ tableView: UITableView, didDeselectRowAt indexPath: IndexPath) {
        let name = self.viewModel.state.tags[indexPath.row].name
        self.viewModel.process(action: .deselect(name))
    }

    func tableView(_ tableView: UITableView, shouldBeginMultipleSelectionInteractionAt indexPath: IndexPath) -> Bool {
        return true
    }
}
