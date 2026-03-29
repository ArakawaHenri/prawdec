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
                        Label("没有转换任务", systemImage: "film.stack")
                    } description: {
                        Text("点击工具栏的 \(Image(systemName: "plus")) 按钮导入 ProRes RAW 素材")
                    }
                    .listRowSeparator(.hidden)
                } else {
                    Section {
                        ForEach(model.jobs) { job in
                            QueueJobRowView(job: job, queuePosition: model.queuePosition(for: job.id))
                                .tag(job.id)
                                .contextMenu {
                                    Button("开始") {
                                        model.start(jobID: job.id)
                                    }
                                    .disabled(!job.canStart)

                                    Button("暂停") {
                                        model.pause(jobID: job.id)
                                    }
                                    .disabled(!job.canPause)

                                    Button("取消") {
                                        model.cancel(jobID: job.id)
                                    }
                                    .disabled(!job.canCancel)

                                    Divider()

                                    Button("移除") {
                                        model.remove(jobID: job.id)
                                    }
                                    .disabled(!job.canRemove)
                                }
                        }
                    } header: {
                        Text("转换队列")
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 360, ideal: 420)
        } detail: {
            if let selectedJob = model.selectedJob {
                JobDetailView(model: model, job: selectedJob)
            } else {
                ContentUnavailableView(
                    "没有选择任务",
                    systemImage: "film.stack",
                    description: Text("导入素材后，在左侧选择一个任务查看详情。")
                )
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    model.isShowingImporter = true
                } label: {
                    Label("导入素材", systemImage: "plus")
                }

                Button {
                    model.startAll()
                } label: {
                    Label("开始全部", systemImage: "play.fill")
                }
                .disabled(model.jobs.isEmpty)

                Button {
                    if let id = model.selectedJobID {
                        model.pause(jobID: id)
                    }
                } label: {
                    Label("暂停", systemImage: "pause.fill")
                }
                .disabled(!(model.selectedJob?.canPause ?? false))

                Button {
                    model.cancelAll()
                } label: {
                    Label("取消全部", systemImage: "stop.fill")
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
            "错误",
            isPresented: Binding(
                get: { model.alertMessage != nil },
                set: { if !$0 { model.alertMessage = nil } }
            ),
            actions: {
                Button("确定", role: .cancel) {
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
