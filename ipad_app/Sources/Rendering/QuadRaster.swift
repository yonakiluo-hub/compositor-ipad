// Four-corner placement follows Compositor Distort.swift.
// MIT © 2026 Wonder Assembly LLC; upstream 365b5745eda537f984f3d5bed1e53c361dbc9c91.
// iPad uses explicit inverse samples to retain nearest/linear and numeric gray rules.
import Foundation
import CoreGraphics

/// Images and the frozen source buffers are immutable after construction.
struct QuadWarpResult: @unchecked Sendable {
    let image:CGImage
    let mask:CGImage?
    let selection:CGImage?
    let transform:LayerTransform
    let rasterized:Bool
}

enum QuadRaster {
    static func warp(_ image:CGImage,mask:CGImage?,transform:LayerTransform,corners:[CGPoint]) throws -> QuadWarpResult {
        guard transform.isValid,QuadWarp.isConvex(corners) else {throw DocumentError.invalid("四角变换参数无效。")}
        let target=imageCorners(corners,flipX:transform.flipX,flipY:transform.flipY)
        let map=try QuadWarp(source:CGRect(x:0,y:0,width:image.width,height:image.height),corners:target)
        let bounds=try map.bounds(),width=Int(bounds.width),height=Int(bounds.height),nearest=transform.sampling == .nearest
        let pixels=try NumericSelectionRaster.rgba(image)
        let coverage=try shapeCoverage(corners,bounds:bounds,antialias:!nearest)
        var output=[UInt8](repeating:0,count:width*height*4)
        for y in 0..<height {for x in 0..<width {
            let index=y*width+x,weight=Double(coverage[index])/255
            guard weight>0,let source=map.inverse(CGPoint(x:bounds.minX+CGFloat(x)+0.5,y:bounds.minY+CGFloat(y)+0.5)) else {continue}
            let point=clamped(source,width:image.width,height:image.height)
            let color=rgbaSample(pixels,width:image.width,height:image.height,point:point,nearest:nearest)
            let alpha=byte(color.3*weight)
            output[index*4]=min(alpha,byte(color.0*weight));output[index*4+1]=min(alpha,byte(color.1*weight))
            output[index*4+2]=min(alpha,byte(color.2*weight));output[index*4+3]=alpha
        }}
        var resultMask:CGImage?
        if let mask {
            if mask.width == 1 && mask.height == 1 {resultMask=mask}
            else {
                let values=try NumericSelectionRaster.gray(mask)
                let maskMap=try QuadWarp(source:CGRect(x:0,y:0,width:mask.width,height:mask.height),corners:target)
                var output=[UInt8](repeating:255,count:width*height)
                for y in 0..<height {for x in 0..<width {
                    guard let source=maskMap.inverse(CGPoint(x:bounds.minX+CGFloat(x)+0.5,y:bounds.minY+CGFloat(y)+0.5)) else {continue}
                    output[y*width+x]=byte(graySample(values,width:mask.width,height:mask.height,
                        point:clamped(source,width:mask.width,height:mask.height),nearest:nearest))
                }}
                // Geometry is already in the image's alpha. Extend mask edge
                // tones throughout the bounding rectangle, including transparent
                // texels: the compositor may interpolate adjacent mask samples.
                // A black geometric silhouette here would darken the edge twice.
                resultMask=try NumericSelectionRaster.grayImage(output,width:width,height:height)
            }
        }
        return QuadWarpResult(image:try rgbaImage(output,width:width,height:height),mask:resultMask,selection:nil,
            transform:LayerTransform(origin:bounds.origin,size:bounds.size,sampling:transform.sampling),rasterized:true)
    }
    static func imageCorners(_ c:[CGPoint],flipX:Bool,flipY:Bool) -> [CGPoint] {
        let units=[(0,0),(1,0),(1,1),(0,1)]
        return units.map { x,y in let u=flipX ? 1-x:x,v=flipY ? 1-y:y;return c[[0,1,3,2][v*2+u]] }
    }
    private static func shapeCoverage(_ corners:[CGPoint],bounds:CGRect,antialias:Bool) throws -> [UInt8] {
        let context=try RasterImage.context(width:Int(bounds.width),height:Int(bounds.height),gray:true)
        context.setFillColor(gray:0,alpha:1);context.fill(CGRect(origin:.zero,size:bounds.size))
        context.setShouldAntialias(antialias);context.setFillColor(gray:1,alpha:1)
        context.addLines(between:corners.map{CGPoint(x:$0.x-bounds.minX,y:$0.y-bounds.minY)})
        context.closePath();context.fillPath()
        guard let image=context.makeImage() else {throw RasterError.allocation}
        return try NumericSelectionRaster.gray(image)
    }
    static func rgbaImage(_ pixels:[UInt8],width:Int,height:Int) throws -> CGImage {
        try NumericSelectionRaster.check(width,height)
        guard pixels.count == width*height*4,let provider=CGDataProvider(data:Data(pixels) as CFData),
              let image=CGImage(width:width,height:height,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:width*4,
                space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.premultipliedLast.rawValue|CGBitmapInfo.byteOrder32Big.rawValue),
                provider:provider,decode:nil,shouldInterpolate:false,intent:.defaultIntent) else {throw RasterError.allocation}
        return image
    }
    static func rgbaSample(_ pixels:[UInt8],width:Int,height:Int,point:CGPoint,nearest:Bool) -> (Double,Double,Double,Double) {
        guard point.x>=0,point.y>=0,point.x<CGFloat(width),point.y<CGFloat(height) else {return (0,0,0,0)}
        if nearest {let i=(Int(point.y)*width+Int(point.x))*4;return (Double(pixels[i]),Double(pixels[i+1]),Double(pixels[i+2]),Double(pixels[i+3]))}
        let x=Double(point.x)-0.5,y=Double(point.y)-0.5,left=Int(floor(x)),top=Int(floor(y)),fx=x-floor(x),fy=y-floor(y)
        let x0=max(0,left),x1=min(width-1,left+1),y0=max(0,top),y1=min(height-1,top+1)
        func value(_ c:Int)->Double {
            let a=Double(pixels[(y0*width+x0)*4+c])*(1-fx)+Double(pixels[(y0*width+x1)*4+c])*fx
            let b=Double(pixels[(y1*width+x0)*4+c])*(1-fx)+Double(pixels[(y1*width+x1)*4+c])*fx
            return a*(1-fy)+b*fy
        }
        return (value(0),value(1),value(2),value(3))
    }
    static func graySample(_ pixels:[UInt8],width:Int,height:Int,point:CGPoint,nearest:Bool) -> Double {
        guard point.x>=0,point.y>=0,point.x<CGFloat(width),point.y<CGFloat(height) else {return 0}
        if nearest {return Double(pixels[Int(point.y)*width+Int(point.x)])}
        let x=Double(point.x)-0.5,y=Double(point.y)-0.5,left=Int(floor(x)),top=Int(floor(y)),fx=x-floor(x),fy=y-floor(y)
        let x0=max(0,left),x1=min(width-1,left+1),y0=max(0,top),y1=min(height-1,top+1)
        let a=Double(pixels[y0*width+x0])*(1-fx)+Double(pixels[y0*width+x1])*fx
        let b=Double(pixels[y1*width+x0])*(1-fx)+Double(pixels[y1*width+x1])*fx
        return a*(1-fy)+b*fy
    }
    static func byte(_ value:Double)->UInt8 {UInt8(min(255,max(0,value.rounded())))}
    private static func clamped(_ point:CGPoint,width:Int,height:Int)->CGPoint {
        CGPoint(x:min(CGFloat(width).nextDown,max(0,point.x)),y:min(CGFloat(height).nextDown,max(0,point.y)))
    }
}

final class LayerWarpSource:@unchecked Sendable {
    let source:CanvasDocument
    let layer:RasterLayer
    let original:[CGPoint]
    let selected:Bool
    private let image:CGImage
    private let mask:CGImage?
    private let selectionSource:SelectionTransformSource?

    init(document:CanvasDocument,selectedIDs:Set<UUID>,renderer:DocumentRenderer) throws {
        try document.validate()
        guard selectedIDs.count<=1,let layer=document.activeLayer,!layer.isGroup,layer.adjustment == nil else {
            throw DocumentError.invalid("四角变换当前仅支持一个普通图层或其中的选中像素；不会压平组或多选。")
        }
        guard !layer.hasEditableContent else {
            throw DocumentError.invalid("请先在图层面板栅格化文字或形状，再进行透视或扭曲；撤销可恢复可编辑内容。")
        }
        guard layer.effects?.isEmpty != false else {
            throw DocumentError.unsupported("带图层效果的透视或扭曲需要先移除效果，或使用盖印副本；整层自由变换可保留效果。")
        }
        guard selectedIDs.isEmpty || selectedIDs.contains(layer.id) else {throw DocumentError.invalid("图层选择已改变，请重新选择一个图层。")}
        guard !document.isEffectivelyLocked(layer.id) else {throw DocumentError.lockedLayer}
        guard let image=try renderer.image(for:layer) else {throw DocumentError.invalid("当前图层没有可变换像素。")}
        self.source=document;self.layer=layer;self.image=image;mask=try layer.maskPNGData.map(RasterImage.decode)
        selected=document.selectionMaskPNGData != nil
        selectionSource=try selected ? SelectionTransformSource(document:document,layer:layer,renderer:renderer):nil
        original=QuadWarp.corners(of:selectionSource?.original ?? layer.transform)
        _=try QuadWarp(source:CGRect(x:0,y:0,width:1,height:1),corners:original).bounds()
    }
    func preview(_ corners:[CGPoint]) throws -> QuadWarpResult {
        if corners == original {
            return QuadWarpResult(image:image,mask:mask,selection:try source.selectionMaskPNGData.map(RasterImage.decode),transform:layer.transform,rasterized:false)
        }
        if let selectionSource {
            let result=try selectionSource.previewQuad(corners)
            return QuadWarpResult(image:result.image,mask:result.mask,selection:result.selection,transform:result.transform,rasterized:result.rasterized)
        }
        return try QuadRaster.warp(image,mask:mask,transform:layer.transform,corners:corners)
    }
}
