import XCTest
import CoreGraphics
@testable import CompositorKit

final class QuadWarpTests:XCTestCase {
    private func image(_ width:Int,_ height:Int,_ value:(Int,Int)->[UInt8]) throws -> CGImage {
        try QuadRaster.rgbaImage((0..<height).flatMap{y in (0..<width).flatMap{value($0,y)}},width:width,height:height)
    }
    private func quad(_ rect:CGRect)->[CGPoint] {
        [CGPoint(x:rect.minX,y:rect.minY),CGPoint(x:rect.maxX,y:rect.minY),CGPoint(x:rect.maxX,y:rect.maxY),CGPoint(x:rect.minX,y:rect.maxY)]
    }
    func testHomographyHitsCornersAndInverseRoundTripsFarFromOrigin() throws {
        let source=CGRect(x:17,y:-9,width:40,height:25)
        let corners=[CGPoint(x:900010,y:-800000),CGPoint(x:900110,y:-799990),CGPoint(x:900090,y:-799930),CGPoint(x:900030,y:-799940)]
        let map=try QuadWarp(source:source,corners:corners)
        for (a,b) in zip(quad(source),corners) {
            let result=try XCTUnwrap(map.forward(a));XCTAssertEqual(result.x,b.x,accuracy:1e-7);XCTAssertEqual(result.y,b.y,accuracy:1e-7)
        }
        for x in 0...4 {for y in 0...4 {
            let point=CGPoint(x:source.minX+source.width*CGFloat(x)/4,y:source.minY+source.height*CGFloat(y)/4)
            let result=try XCTUnwrap(map.inverse(XCTUnwrap(map.forward(point))))
            XCTAssertEqual(result.x,point.x,accuracy:1e-7);XCTAssertEqual(result.y,point.y,accuracy:1e-7)
        }}
    }
    func testConcaveFoldedCollapsedNonfiniteAndOversizedShapesReject() throws {
        let source=CGRect(x:0,y:0,width:1,height:1),normal=quad(CGRect(x:0,y:0,width:20,height:20))
        for corners in [[normal[0],normal[2],normal[1],normal[3]],
                        [normal[0],normal[0],normal[2],normal[3]],
                        [normal[0],normal[1],CGPoint(x:2,y:2),normal[3]],
                        [CGPoint(x:CGFloat.infinity,y:0),normal[1],normal[2],normal[3]],
                        Array(normal.prefix(3))] {
            XCTAssertThrowsError(try QuadWarp(source:source,corners:corners))
        }
        let big=try QuadWarp(source:source,corners:quad(CGRect(x:0,y:0,width:5000,height:1)))
        XCTAssertThrowsError(try big.bounds())
        let sourceImage=try image(2,2){_,_ in [128,0,0,128]}
        XCTAssertThrowsError(try QuadRaster.warp(sourceImage,mask:nil,transform:LayerTransform(size:CGSize(width:2,height:2)),corners:[]))
    }
    func testSamplingSupportCannotCrossProjectivePole() throws {
        let map=try QuadWarp(source:CGRect(x:0,y:0,width:100,height:100),corners:[CGPoint(x:0,y:0),CGPoint(x:100,y:0),CGPoint(x:60,y:100),CGPoint(x:40,y:100)])
        XCTAssertNoThrow(try map.projectedBounds(CGRect(x:0,y:0,width:100,height:100)))
        XCTAssertThrowsError(try map.projectedBounds(CGRect(x:0,y:-100,width:100,height:300)))
    }
    func testPerspectivePairsAnEdgeWhileDistortMovesOnlyGrabbedCorner() throws {
        let original=quad(CGRect(x:10,y:20,width:100,height:80)),start=original[0]
        let perspective=try XCTUnwrap(QuadWarpGesture(corners:original,corner:0,start:start,mode:.perspective).updated(to:CGPoint(x:25,y:22)))
        XCTAssertEqual(perspective[0],CGPoint(x:25,y:20));XCTAssertEqual(perspective[1],CGPoint(x:95,y:20))
        XCTAssertEqual(perspective[2],original[2]);XCTAssertEqual(perspective[3],original[3])
        let distort=try XCTUnwrap(QuadWarpGesture(corners:original,corner:0,start:start,mode:.distort).updated(to:CGPoint(x:25,y:22)))
        XCTAssertEqual(distort[0],CGPoint(x:25,y:22));XCTAssertEqual(Array(distort.dropFirst()),Array(original.dropFirst()))
        XCTAssertNil(QuadWarpGesture(corners:original,corner:0,start:start,mode:.distort).updated(to:CGPoint(x:120,y:110)))
    }
    func testNearestWarpRespectsAllFlipCombinationsAndIntegerPlacement() throws {
        let colors:[[UInt8]]=[[255,0,0,255],[0,255,0,255],[0,0,255,255],[255,255,0,255]]
        let source=try image(2,2){x,y in colors[y*2+x]},target=quad(CGRect(x:3,y:7,width:2,height:2))
        let tones:[UInt8]=[0,64,128,255],mask=try NumericSelectionRaster.grayImage(tones,width:2,height:2)
        for flipX in [false,true] {for flipY in [false,true] {
            let transform=LayerTransform(size:CGSize(width:2,height:2),flipX:flipX,flipY:flipY,sampling:.nearest)
            let result=try QuadRaster.warp(source,mask:mask,transform:transform,corners:target)
            XCTAssertEqual(result.transform.origin,CGPoint(x:3,y:7));XCTAssertEqual(result.transform.rotation,0)
            var expected=[UInt8]()
            for y in 0..<2 {for x in 0..<2 {
                let sourceX=flipX ? 1-x:x,sourceY=flipY ? 1-y:y
                expected.append(contentsOf:colors[sourceY*2+sourceX])
            }}
            XCTAssertEqual(try NumericSelectionRaster.rgba(result.image),expected)
            var expectedMask=[UInt8]()
            for y in 0..<2 {for x in 0..<2 {expectedMask.append(tones[(flipY ? 1-y:y)*2+(flipX ? 1-x:x)])}}
            XCTAssertEqual(try NumericSelectionRaster.gray(XCTUnwrap(result.mask)),expectedMask)
        }}
    }
    func testSoftMaskDoesNotSquareAntialiasedGeometryOrBakeIntoSourcePixels() throws {
        let source=try image(8,8){_,_ in [128,0,0,128]}
        let mask=try NumericSelectionRaster.grayImage(Array(repeating:128,count:64),width:8,height:8)
        let target=[CGPoint(x:0.2,y:0.4),CGPoint(x:8.4,y:1.2),CGPoint(x:6.7,y:9.3),CGPoint(x:1.1,y:8.2)]
        let result=try QuadRaster.warp(source,mask:mask,transform:LayerTransform(size:CGSize(width:8,height:8)),corners:target)
        XCTAssertEqual(Set(try NumericSelectionRaster.gray(XCTUnwrap(result.mask))),[128])
        let raw=try NumericSelectionRaster.rgba(result.image)
        XCTAssertTrue(stride(from:3,to:raw.count,by:4).contains(where:{raw[$0]>0 && raw[$0]<128}))
        let layer=RasterLayer(pngData:try RasterImage.png(result.image),transform:result.transform,maskPNGData:try RasterImage.png(XCTUnwrap(result.mask)))
        let document=CanvasDocument(width:12,height:12,layers:[layer],activeLayerID:layer.id)
        let masked=try NumericSelectionRaster.rgba(DocumentRenderer().render(document))
        var without=document;without.layers[0].maskPNGData=nil
        let reference=try NumericSelectionRaster.rgba(DocumentRenderer().render(without))
        for index in stride(from:3,to:masked.count,by:4) {
            XCTAssertEqual(Int(masked[index]),(Int(reference[index])*128+127)/255,accuracy:1)
        }
        XCTAssertEqual(try NumericSelectionRaster.rgba(source),Array(repeating:[UInt8(128),0,0,128],count:64).flatMap{$0})
    }
    func testSelectedPixelWarpKeepsIndependentMaskAndRefillsSoftOverlapOnce() throws {
        let source=try image(8,4){x,y in (2..<6).contains(x) && (1..<3).contains(y) ? [128,0,0,128]:[0,0,0,0]}
        let mask=try NumericSelectionRaster.grayImage((0..<32).map{$0%8<4 ? 64:192},width:8,height:4)
        let selection=try NumericSelectionRaster.grayImage((0..<72).map{let x=$0%12,y=$0/12;return (2..<6).contains(x) && (2..<4).contains(y) ? 128:0},width:12,height:6)
        let layer=RasterLayer(pngData:try RasterImage.png(source),transform:LayerTransform(origin:CGPoint(x:0,y:1),size:CGSize(width:8,height:4),sampling:.nearest),maskPNGData:try RasterImage.png(mask))
        let document=CanvasDocument(width:12,height:6,layers:[layer],activeLayerID:layer.id,selectionMaskPNGData:try RasterImage.png(selection))
        let plan=try LayerWarpSource(document:document,selectedIDs:[layer.id],renderer:DocumentRenderer())
        let result=try plan.preview(plan.original.map{CGPoint(x:$0.x+2,y:$0.y)})
        XCTAssertEqual(try NumericSelectionRaster.gray(XCTUnwrap(result.mask)),try NumericSelectionRaster.gray(mask))
        let pixels=try NumericSelectionRaster.rgba(result.image)
        XCTAssertEqual(pixels[(1*8+2)*4+3],64)
        XCTAssertEqual(pixels[(1*8+4)*4+3],128,"Soft overlap restores original coverage, not 0.75 of it")
        XCTAssertEqual(pixels[(1*8+6)*4+3],64)
        let moved=try NumericSelectionRaster.gray(XCTUnwrap(result.selection))
        XCTAssertEqual(moved[2*12+4],128);XCTAssertEqual(moved[2*12+2],0)
        XCTAssertEqual(plan.source,document)
        let identity=try plan.preview(plan.original)
        XCTAssertEqual(try NumericSelectionRaster.rgba(identity.image),try NumericSelectionRaster.rgba(source))
    }
    func testRotatedSelectedSourceUsesOneDocumentGridAndIdentityKeepsOriginalResources() throws {
        let source=try image(10,8){_,_ in [100,20,0,128]}
        let mask=try NumericSelectionRaster.grayImage((0..<20).map{$0%5<2 ? 0:128},width:5,height:4)
        let layer=RasterLayer(pngData:try RasterImage.png(source),transform:LayerTransform(origin:CGPoint(x:15,y:12),size:CGSize(width:20,height:16),rotation:23),maskPNGData:try RasterImage.png(mask),maskEnabled:false)
        let selection=try NumericSelectionRaster.grayImage((0..<2400).map{let x=$0%60,y=$0/60;return (15..<30).contains(x) && (15..<25).contains(y) ? 128:0},width:60,height:40)
        let document=CanvasDocument(width:60,height:40,layers:[layer],activeLayerID:layer.id,selectionMaskPNGData:try RasterImage.png(selection))
        let plan=try LayerWarpSource(document:document,selectedIDs:[layer.id],renderer:DocumentRenderer())
        var target=plan.original;target[0].x+=1;target[0].y+=1
        let result=try plan.preview(target)
        XCTAssertTrue(result.rasterized);XCTAssertEqual(result.transform.rotation,0)
        XCTAssertEqual(result.mask?.width,result.image.width);XCTAssertEqual(result.mask?.height,result.image.height)
        let identity=try plan.preview(plan.original)
        XCTAssertEqual(identity.transform,layer.transform)
        XCTAssertEqual(try NumericSelectionRaster.gray(XCTUnwrap(identity.mask)),try NumericSelectionRaster.gray(mask))
        XCTAssertEqual(plan.source.layers[0].pngData,layer.pngData);XCTAssertFalse(plan.source.layers[0].maskEnabled)
    }
    func testLockedGroupedMultiSelectionAndExplicitBlackSelectionRefuseAtomically() throws {
        let source=try image(4,4){_,_ in [255,0,0,255]}
        let layer=RasterLayer(pngData:try RasterImage.png(source),transform:LayerTransform(size:CGSize(width:4,height:4)))
        var document=CanvasDocument(width:8,height:8,layers:[layer],activeLayerID:layer.id)
        XCTAssertThrowsError(try LayerWarpSource(document:document,selectedIDs:[layer.id,UUID()],renderer:DocumentRenderer()))
        document.layers[0].isLocked=true
        XCTAssertThrowsError(try LayerWarpSource(document:document,selectedIDs:[layer.id],renderer:DocumentRenderer()))
        document.layers[0].isLocked=false
        document.selectionMaskPNGData=try RasterImage.png(NumericSelectionRaster.grayImage(Array(repeating:0,count:64),width:8,height:8))
        XCTAssertThrowsError(try LayerWarpSource(document:document,selectedIDs:[layer.id],renderer:DocumentRenderer()))
        XCTAssertEqual(document.layers[0],layer)
    }
}
