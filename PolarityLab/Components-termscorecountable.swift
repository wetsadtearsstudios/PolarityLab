// Components/TermScoreCountTable.swift
import SwiftUI

/// Term • Score • Count table that *constrains itself to its parent card’s height*
/// (no more overflow into Stats). The ScrollView expands to fill remaining space.
struct TermScoreCountTable: View {
    let rows: [(term: String, score: Double, count: Int)]
    
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Term").font(.headline)
                Spacer()
                Text("Score").font(.headline).frame(width: 80, alignment: .trailing)
                Text("Count").font(.headline).frame(width: 70, alignment: .trailing)
            }
            .padding(.vertical, 6)
            
            Divider()
            
            // Fill the remaining height inside the TableCard and clip
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(rows, id: \.term) { row in
                        HStack {
                            Text(row.term)
                            Spacer()
                            Text(String(format: "%+.2f", row.score))
                                .frame(width: 80, alignment: .trailing)
                                .foregroundStyle(row.score > 0 ? .green : row.score < 0 ? .red : .secondary)
                            Text("\(row.count)")
                                .frame(width: 70, alignment: .trailing)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 6)
                        Divider()
                    }
                }
            }
            .frame(maxHeight: .infinity)
            .clipped()
        }
    }
}
