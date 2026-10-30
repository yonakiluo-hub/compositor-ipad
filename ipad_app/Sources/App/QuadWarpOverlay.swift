import UIKit

struct QuadWarpOverlay {
    enum Hit {case corner(Int),translate}
    let points:[CGPoint]
    init(corners:[CGPoint],viewport:CanvasViewport,documentSize:CGSize) {
        points=corners.map{viewport.viewPoint(from:$0,documentSize:documentSize)}
    }
    func hit(_ point:CGPoint)->Hit? {
        guard points.count == 4 else {return nil}
        if let index=points.indices.min(by:{hypot(points[$0].x-point.x,points[$0].y-point.y)<hypot(points[$1].x-point.x,points[$1].y-point.y)}),
           hypot(points[index].x-point.x,points[index].y-point.y)<=26 {return .corner(index)}
        let path=CGMutablePath();path.addLines(between:points);path.closeSubpath()
        return path.contains(point) ? .translate:nil
    }
    func draw(in context:CGContext) {
        guard points.count == 4 else {return}
        context.saveGState();defer{context.restoreGState()}
        context.setStrokeColor(UIColor.systemTeal.cgColor);context.setLineWidth(2)
        context.addLines(between:points+[points[0]]);context.strokePath()
        for (index,point) in points.enumerated() {
            let rect=CGRect(x:point.x-8,y:point.y-8,width:16,height:16)
            context.setFillColor(UIColor.white.cgColor);context.fillEllipse(in:rect);context.strokeEllipse(in:rect)
            let title=("\(index+1)" as NSString)
            title.draw(at:CGPoint(x:point.x+11,y:point.y-8),withAttributes:[.font:UIFont.systemFont(ofSize:12,weight:.bold),.foregroundColor:UIColor.systemTeal])
        }
    }
}
