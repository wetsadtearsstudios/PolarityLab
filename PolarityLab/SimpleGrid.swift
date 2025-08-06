import SwiftUI

/// A horizontal, scrollable grid for a header + rows
public struct SimpleGrid<Col: Hashable, Content: View>: View {
    let columns: [Col]
    let rows: [[Col:String]]
    let content: (Col, String) -> Content

    public init(
        columns: [Col],
        rows: [[Col:String]],
        @ViewBuilder content: @escaping (Col, String) -> Content
    ) {
        self.columns = columns
        self.rows = rows
        self.content = content
    }

    public var body: some View {
        ScrollView(.horizontal, showsIndicators: true) {
            LazyVGrid(columns: columns.map { _ in GridItem(.fixed(120), spacing: 8) }, spacing: 8) {
                // Headers
                ForEach(columns, id: \.self) { col in
                    Text("\(col)")
                        .bold()
                        .frame(width: 120, alignment: .leading)
                }
                Divider().gridCellColumns(columns.count)

                // Cells
                ForEach(Array(rows.enumerated()), id: \.offset) { rowIndex, row in
                    ForEach(columns, id: \.self) { col in
                        content(col, row[col] ?? "")
                            .frame(width: 120, alignment: .leading)
                            .lineLimit(1)
                            .font(.caption)
                    }
                }
            }
            .padding(.horizontal)
        }
    }
}
