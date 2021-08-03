//
//  CitationActionHandler.swift
//  Zotero
//
//  Created by Michal Rentka on 15.06.2021.
//  Copyright © 2021 Corporation for Digital Scholarship. All rights reserved.
//

import UIKit
import WebKit

import CocoaLumberjackSwift
import RxSwift

struct CitationActionHandler: ViewModelActionHandler {
    typealias Action = CitationAction
    typealias State = CitationState

    private unowned let citationController: CitationController
    private let disposeBag: DisposeBag

    init(citationController: CitationController) {
        self.citationController = citationController
        self.disposeBag = DisposeBag()
    }

    func process(action: CitationAction, in viewModel: ViewModel<CitationActionHandler>) {
        switch action {
        case .preload(let webView):
            self.preload(webView: webView, in: viewModel)

        case .setLocator(let locator):
            // TODO: - do something with locator
            self.loadPreview(stateAction: { state in
                state.locator = locator
                state.changes = [.preview, .locator]
            }, in: viewModel)

        case .setLocatorValue(let value):
            // TODO: - do something with locator value
            self.loadPreview(stateAction: { state in
                state.locatorValue = value
                state.changes = .preview
            }, in: viewModel)

        case .setOmitAuthor(let omitAuthor):
            // TODO: - do something with omitAuthor
            self.loadPreview(stateAction: { state in
                state.omitAuthor = omitAuthor
                state.changes = .preview
            }, in: viewModel)

        case .cleanup:
            self.citationController.finishCitation()

        case .copy:
            UIPasteboard.general.string = viewModel.state.preview
        }
    }

    private func loadPreview(stateAction: @escaping (inout CitationState) -> Void, in viewModel: ViewModel<CitationActionHandler>) {
        guard let webView = viewModel.state.webView else { return }
        self.citationController.citation(for: viewModel.state.item, format: .html, in: webView)
                               .subscribe(onSuccess: { [weak viewModel] preview in
                                   guard let viewModel = viewModel else { return }
                                   self.update(viewModel: viewModel) { state in
                                       state.preview = preview
                                       stateAction(&state)
                                   }
                               })
                               .disposed(by: self.disposeBag)
    }

    private func preload(webView: WKWebView, in viewModel: ViewModel<CitationActionHandler>) {
        let item = viewModel.state.item
        self.citationController.prepareForCitation(styleId: viewModel.state.styleId, localeId: viewModel.state.localeId, in: webView)
                               .flatMap({ [weak webView] _ -> Single<String> in
                                   guard let webView = webView else { return Single.error(CitationController.Error.prepareNotCalled) }
                                   return self.citationController.citation(for: item, format: .html, in: webView)
                               })
                               .subscribe(onSuccess: { [weak viewModel, weak webView] preview in
                                   guard let viewModel = viewModel else { return }
                                   self.update(viewModel: viewModel) { state in
                                       state.webView = webView
                                       state.preview = preview
                                       state.changes = [.loading, .preview]
                                   }
                               }, onFailure: { error in
                                   DDLogError("CitationActionHandler: can't preload webView - \(error)")
                                   self.update(viewModel: viewModel) { state in
                                       state.error = .cantPreloadWebView
                                   }
                               })
                               .disposed(by: self.disposeBag)
    }
}
