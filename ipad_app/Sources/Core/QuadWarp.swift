// Adapted from Compositor Distort.swift (homography and corner order).
// MIT © 2026 Wonder Assembly LLC; upstream 365b5745eda537f984f3d5bed1e53c361dbc9c91.
import Foundation
import CoreGraphics

enum QuadWarpMode:String,CaseIterable,Sendable {
    case perspective,distort
    var title:String {self == .perspective ? "透视" : "四角扭曲"}
}

/// A convex quadrilateral mapping. Coordinates are normalized around the target
/// bounds before inversion so a layer far from the canvas does not lose precision.
struct QuadWarp:Sendable {
    let source:CGRect
    let corners:[CGPoint]
    private let target:CGRect
    private let matrix:[Double]
    private let inverseMatrix:[Double]

    init(source:CGRect,corners:[CGPoint]) throws {
        guard source.width > 0,source.height > 0,
              [source.minX,source.minY,source.width,source.height].allSatisfy(\.isFinite),
              Self.isConvex(corners) else {throw DocumentError.invalid("四角不能交叉、折叠或重合。")}
        let xs=corners.map(\.x),ys=corners.map(\.y)
        let target=CGRect(x:xs.min()!,y:ys.min()!,width:xs.max()!-xs.min()!,height:ys.max()!-ys.min()!)
        let c=corners.map {CGPoint(x:($0.x-target.minX)/target.width,y:($0.y-target.minY)/target.height)}
        let sx=c[0].x-c[1].x+c[2].x-c[3].x,sy=c[0].y-c[1].y+c[2].y-c[3].y
        var g=0.0,h=0.0
        if abs(sx)>1e-12 || abs(sy)>1e-12 {
            let dx1=c[1].x-c[2].x,dx2=c[3].x-c[2].x,dy1=c[1].y-c[2].y,dy2=c[3].y-c[2].y
            let denominator=dx1*dy2-dx2*dy1
            guard abs(denominator)>1e-12 else {throw DocumentError.invalid("四角变换过于接近退化形状。")}
            g=Double((sx*dy2-dx2*sy)/denominator);h=Double((dx1*sy-sx*dy1)/denominator)
        }
        let a=Double(c[1].x-c[0].x)+g*Double(c[1].x),b=Double(c[3].x-c[0].x)+h*Double(c[3].x)
        let d=Double(c[1].y-c[0].y)+g*Double(c[1].y),e=Double(c[3].y-c[0].y)+h*Double(c[3].y)
        let m=[a,b,Double(c[0].x),d,e,Double(c[0].y),g,h,1]
        let inverse=try Self.inverted(m)
        guard m.allSatisfy(\.isFinite),inverse.allSatisfy(\.isFinite) else {throw DocumentError.invalid("四角变换不可逆。")}
        self.source=source;self.corners=corners;self.target=target;matrix=m;inverseMatrix=inverse
    }
    static func corners(of transform:LayerTransform) -> [CGPoint] {
        [CGPoint(x:0,y:0),CGPoint(x:1,y:0),CGPoint(x:1,y:1),CGPoint(x:0,y:1)].map(transform.point)
    }
    static func isConvex(_ corners:[CGPoint]) -> Bool {
        guard corners.count == 4,corners.allSatisfy({$0.x.isFinite && $0.y.isFinite && abs($0.x)<=1_000_000 && abs($0.y)<=1_000_000}) else {return false}
        var sign:CGFloat=0
        for i in 0..<4 {
            let a=corners[i],b=corners[(i+1)%4],c=corners[(i+2)%4]
            let cross=(b.x-a.x)*(c.y-b.y)-(b.y-a.y)*(c.x-b.x)
            guard abs(cross)>0.01 else {return false}
            if sign == 0 {sign=cross} else if (sign<0) != (cross<0) {return false}
        }
        return true
    }
    func forward(_ point:CGPoint) -> CGPoint? {
        guard let p=Self.apply(matrix,CGPoint(x:(point.x-source.minX)/source.width,y:(point.y-source.minY)/source.height)) else {return nil}
        let result=CGPoint(x:target.minX+p.x*target.width,y:target.minY+p.y*target.height)
        return result.x.isFinite && result.y.isFinite ? result:nil
    }
    func inverse(_ point:CGPoint) -> CGPoint? {
        guard let p=Self.apply(inverseMatrix,CGPoint(x:(point.x-target.minX)/target.width,y:(point.y-target.minY)/target.height)) else {return nil}
        let result=CGPoint(x:source.minX+p.x*source.width,y:source.minY+p.y*source.height)
        return result.x.isFinite && result.y.isFinite ? result:nil
    }
    func bounds() throws -> CGRect {
        let left=floor(target.minX),top=floor(target.minY),right=ceil(target.maxX),bottom=ceil(target.maxY)
        let bounds=CGRect(x:left,y:top,width:right-left,height:bottom-top)
        guard bounds.width>=1,bounds.height>=1,bounds.width<=4096,bounds.height<=4096,bounds.width*bounds.height<=16_000_000 else {throw RasterError.oversized}
        return bounds
    }
    func projectedBounds(_ rect:CGRect) throws -> CGRect {
        let points=[CGPoint(x:rect.minX,y:rect.minY),CGPoint(x:rect.maxX,y:rect.minY),CGPoint(x:rect.maxX,y:rect.maxY),CGPoint(x:rect.minX,y:rect.maxY)]
        let weights=points.map {Double(($0.x-source.minX)/source.width)*matrix[6]+Double(($0.y-source.minY)/source.height)*matrix[7]+matrix[8]}
        guard weights.allSatisfy({$0.isFinite && $0>1e-10}) || weights.allSatisfy({$0.isFinite && $0 < -1e-10}) else {
            throw DocumentError.invalid("四角变换的采样范围穿过透视奇点。")
        }
        let moved=points.compactMap(forward)
        guard moved.count == 4 else {throw DocumentError.invalid("四角变换范围无效。")}
        let x=moved.map(\.x),y=moved.map(\.y)
        return CGRect(x:x.min()!,y:y.min()!,width:x.max()!-x.min()!,height:y.max()!-y.min()!)
    }
    private static func apply(_ m:[Double],_ p:CGPoint) -> CGPoint? {
        let x=Double(p.x),y=Double(p.y),w=m[6]*x+m[7]*y+m[8]
        guard x.isFinite,y.isFinite,w.isFinite,abs(w)>1e-12 else {return nil}
        let result=CGPoint(x:(m[0]*x+m[1]*y+m[2])/w,y:(m[3]*x+m[4]*y+m[5])/w)
        return result.x.isFinite && result.y.isFinite ? result:nil
    }
    private static func inverted(_ m:[Double]) throws -> [Double] {
        let a=m[0],b=m[1],c=m[2],d=m[3],e=m[4],f=m[5],g=m[6],h=m[7],i=m[8]
        let values=[e*i-f*h,c*h-b*i,b*f-c*e,f*g-d*i,a*i-c*g,c*d-a*f,d*h-e*g,b*g-a*h,a*e-b*d]
        let determinant=a*values[0]+b*values[3]+c*values[6]
        guard determinant.isFinite,abs(determinant)>1e-12 else {throw DocumentError.invalid("四角变换不可逆。")}
        return values.map{$0/determinant}
    }
}

struct QuadWarpGesture {
    let corners:[CGPoint]
    let corner:Int?
    let start:CGPoint
    let mode:QuadWarpMode
    func updated(to point:CGPoint) -> [CGPoint]? {
        guard corners.count == 4,[point.x,point.y,start.x,start.y].allSatisfy(\.isFinite) else {return nil}
        let delta=CGPoint(x:point.x-start.x,y:point.y-start.y)
        var next=corners
        if let corner {
            guard (0..<4).contains(corner) else {return nil}
            if mode == .distort {next[corner].x+=delta.x;next[corner].y+=delta.y}
            else {
                let u=CGPoint(x:corners[1].x-corners[0].x,y:corners[1].y-corners[0].y)
                let v=CGPoint(x:corners[3].x-corners[0].x,y:corners[3].y-corners[0].y)
                let ul=hypot(u.x,u.y),vl=hypot(v.x,v.y)
                guard ul>0,vl>0 else {return nil}
                let du=(delta.x*u.x+delta.y*u.y)/ul,dv=(delta.x*v.x+delta.y*v.y)/vl
                let horizontal=abs(du)>=abs(dv),axis=horizontal ? CGPoint(x:u.x/ul,y:u.y/ul):CGPoint(x:v.x/vl,y:v.y/vl)
                let distance=horizontal ? du:dv,paired=horizontal ? [1,0,3,2][corner]:[3,2,1,0][corner]
                next[corner].x+=axis.x*distance;next[corner].y+=axis.y*distance
                next[paired].x-=axis.x*distance;next[paired].y-=axis.y*distance
            }
        } else {next=next.map{CGPoint(x:$0.x+delta.x,y:$0.y+delta.y)}}
        return QuadWarp.isConvex(next) ? next:nil
    }
}
