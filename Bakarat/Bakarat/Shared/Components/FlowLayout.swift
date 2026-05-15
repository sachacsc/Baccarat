//
//  FlowLayout.swift
//  Bakarat
//
//  Layout custom qui place les sous-vues comme un flow horizontal : elles
//  s'enchaînent à droite jusqu'à manquer de place, puis passent à la ligne.
//  Plus naturel qu'un LazyVGrid pour des pills/chips de tailles variées.
//

import SwiftUI

struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let containerWidth = proposal.width ?? .infinity
        var current = (x: CGFloat(0), y: CGFloat(0), lineHeight: CGFloat(0))

        for sv in subviews {
            let size = sv.sizeThatFits(.unspecified)
            if current.x + size.width > containerWidth, current.x > 0 {
                current.x = 0
                current.y += current.lineHeight + spacing
                current.lineHeight = 0
            }
            current.x += size.width + spacing
            current.lineHeight = max(current.lineHeight, size.height)
        }
        return CGSize(width: containerWidth.isFinite ? containerWidth : current.x,
                      height: current.y + current.lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var current = (x: bounds.minX, y: bounds.minY, lineHeight: CGFloat(0))

        for sv in subviews {
            let size = sv.sizeThatFits(.unspecified)
            if current.x + size.width > bounds.maxX, current.x > bounds.minX {
                current.x = bounds.minX
                current.y += current.lineHeight + spacing
                current.lineHeight = 0
            }
            sv.place(at: CGPoint(x: current.x, y: current.y),
                     proposal: ProposedViewSize(size))
            current.x += size.width + spacing
            current.lineHeight = max(current.lineHeight, size.height)
        }
    }
}
