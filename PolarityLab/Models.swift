// Models.swift
import Foundation

struct TLPoint: Identifiable, Hashable {
    let id = UUID()
    let date: Date
    let avg: Double
    let count: Int
}

struct YearLinePoint: Identifiable {
    let id = UUID()
    let monthAligned: Date
    let avg: Double
    let yearLabel: String
}

struct EventMarker: Identifiable {
    let id = UUID()
    let date: Date
    let title: String
}

struct PieSlice: Identifiable {
    let id = UUID()
    let label: String
    let count: Int
}
