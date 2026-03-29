//
//  ContentView.swift
//  prawdec
//
//  Created by Henri on 2026/3/28.
//

import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @State private var model = AppModel.makeDefault()

    var body: some View {
        NavigationSplitView {
            List(selection: $model.selectedJobID) {
                if model.jobs.isEmpty {
                    ContentUnavailableView {
                        Label(L10n.tr("content.no_jobs.title"), systemImage: "film.stack")
                    } description: {
                        HStack(spacing: 4) {
                            Text(L10n.tr("content.no_jobs.description.prefix"))
                            Image(systemName: "plus")
                            Text(L10n.tr("content.no_jobs.description.suffix"))
                        }
                    }
                    .listRowSeparator(.hidden)
                } else {
                    Section {
                        ForEach(model.jobs) { job in
                            QueueJobRowView(job: job, queuePosition: model.queuePosition(for: job.id))
                                .tag(job.id)
                                .contextMenu {
                                    Button(L10n.tr("action.start")) {
                                        model.start(jobID: job.id)
                                    }
                                    .disabled(!job.canStart)

                                    Button(L10n.tr("action.pause")) {
                                        model.pause(jobID: job.id)
                                    }
                                    .disabled(!job.canPause)

                                    Button(L10n.tr("action.cancel")) {
                                        model.cancel(jobID: job.id)
                                    }
                                    .disabled(!job.canCancel)

                                    Divider()

                                    Button(L10n.tr("action.remove")) {
                                        model.remove(jobID: job.id)
                                    }
                                    .disabled(!job.canRemove)
                                }
                        }
                    } header: {
                        Text(L10n.tr("content.queue.title"))
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 360, ideal: 420)
        } detail: {
            if let selectedJob = model.selectedJob {
                JobDetailView(model: model, job: selectedJob)
            } else {
                ContentUnavailableView(
                    L10n.tr("content.no_selection.title"),
                    systemImage: "film.stack",
                    description: Text(L10n.tr("content.no_selection.description"))
                )
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    model.isShowingImporter = true
                } label: {
                    Label(L10n.tr("action.import_media"), systemImage: "plus")
                }

                Button {
                    model.startAll()
                } label: {
                    Label(L10n.tr("action.start_all"), systemImage: "play.fill")
                }
                .disabled(model.jobs.isEmpty)

                Button {
                    if let id = model.selectedJobID {
                        model.pause(jobID: id)
                    }
                } label: {
                    Label(L10n.tr("action.pause"), systemImage: "pause.fill")
                }
                .disabled(!(model.selectedJob?.canPause ?? false))

                Button {
                    model.cancelAll()
                } label: {
                    Label(L10n.tr("action.cancel_all"), systemImage: "stop.fill")
                }
                .disabled(!model.canCancelAny)
            }

        }
        .fileImporter(
            isPresented: $model.isShowingImporter,
            allowedContentTypes: [.movie],
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls):
                model.addSourceURLs(urls)
            case .failure(let error):
                model.alertMessage = error.localizedDescription
            }
        }
        .alert(
            L10n.tr("alert.error.title"),
            isPresented: Binding(
                get: { model.alertMessage != nil },
                set: { if !$0 { model.alertMessage = nil } }
            ),
            actions: {
                Button(L10n.tr("action.ok"), role: .cancel) {
                    model.alertMessage = nil
                }
            },
            message: {
                Text(model.alertMessage ?? "")
            }
        )
    }
}

#Preview {
    ContentView()
}
