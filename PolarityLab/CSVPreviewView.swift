// CSVPreviewView.swift

import SwiftUI

struct CSVPreviewView: View {
    let csv: SimpleCSV
    @Binding var selectedColumns: [String]
    @Binding var selectedModel: SentimentModel
    let onAnalyze: () -> Void

    var body: some View {
        GeometryReader { geo in
            let inset: CGFloat = 16
            let totalWidth = geo.size.width - inset * 2
            let cols = selectedColumns.isEmpty ? csv.headers : selectedColumns
            let columnWidth = totalWidth / CGFloat(max(cols.count, 1))

            VStack(spacing: 0) {
                // MARK: — Header —
                Text("Preview (\(csv.allRows.count) rows)")
                    .font(.largeTitle).bold()
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(.top, inset)

                Divider()

                // MARK: — Sentiment Model Picker —
                VStack(spacing: 12) {
                    Text("Choose Sentiment Analysis Model")
                        .font(.title2.bold())
                        .multilineTextAlignment(.center)

                    Text("More advanced models take longer to run but may give better results. Select what fits your content.")
                        .font(.callout)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 500)

                    Picker("Sentiment Model", selection: $selectedModel) {
                        ForEach(SentimentModel.allCases) { model in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(model.rawValue)
                                    .font(.headline)
                                Text(model.description)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            .tag(model)
                        }
                    }
                    .pickerStyle(RadioGroupPickerStyle())
                    .frame(maxWidth: 500)
                }
                .padding(.vertical, inset)

                Divider()

                // MARK: — Column Selector —
                VStack(alignment: .leading, spacing: 12) {
                    Text("Select columns to include in the analysis:")
                        .font(.title3)
                        .frame(maxWidth: .infinity, alignment: .center)

                    HStack {
                        Spacer()
                        Menu {
                            ForEach(csv.headers, id: \.self) { col in
                                Button(action: { toggle(col) }) {
                                    Label(col,
                                          systemImage: selectedColumns.contains(col)
                                              ? "checkmark.circle.fill"
                                              : "circle")
                                }
                            }
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "list.bullet")
                                    .font(.title2)
                                Text("Columns (\(selectedColumns.count))")
                                    .font(.title2)
                            }
                            .padding(.vertical, 12)
                            .padding(.horizontal, 20)
                            .background(RoundedRectangle(cornerRadius: 8)
                                            .fill(Color.gray.opacity(0.2)))
                        }
                        .fixedSize()
                        Spacer()
                    }
                }
                .padding(.horizontal, inset)

                Divider()

                // MARK: — Data Table —
                ScrollView([.horizontal, .vertical], showsIndicators: true) {
                    VStack(spacing: 0) {
                        HStack(spacing: 0) {
                            ForEach(cols, id: \.self) { col in
                                Text(col)
                                    .font(.headline)
                                    .frame(width: columnWidth)
                                    .padding(.vertical, 8)
                            }
                        }
                        .background(Color.secondary.opacity(0.05))

                        ForEach(csv.allRows.indices, id: \.self) { rowIdx in
                            HStack(spacing: 0) {
                                ForEach(cols, id: \.self) { col in
                                    Text(csv.allRows[rowIdx][col] ?? "")
                                        .font(.callout)
                                        .frame(width: columnWidth)
                                        .padding(.vertical, 6)
                                }
                            }
                            if rowIdx < csv.allRows.count - 1 {
                                Divider().background(Color.secondary.opacity(0.1))
                            }
                        }
                    }
                    .padding(.horizontal, inset)
                }
                .frame(maxHeight: .infinity)

                Divider()

                // MARK: — Analyze Button —
                Button(action: onAnalyze) {
                    HStack(spacing: 10) {
                        Image(systemName: "bolt.fill")
                            .font(.title2)
                        Text("Analyze Selected Columns")
                            .font(.title3).bold()
                    }
                    .padding(.vertical, 16)
                    .padding(.horizontal, 32)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(selectedColumns.isEmpty
                                  ? Color.gray.opacity(0.3)
                                  : Color.accentColor)
                    )
                    .foregroundColor(selectedColumns.isEmpty ? .gray : .white)
                }
                .buttonStyle(PlainButtonStyle())
                .disabled(selectedColumns.isEmpty)
                .padding(.vertical, inset)
            }
            .padding(.horizontal, inset)
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }

    private func toggle(_ col: String) {
        if let idx = selectedColumns.firstIndex(of: col) {
            selectedColumns.remove(at: idx)
        } else {
            selectedColumns.append(col)
        }
    }
}
