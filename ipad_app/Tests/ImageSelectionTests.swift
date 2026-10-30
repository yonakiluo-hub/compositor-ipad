import XCTest
import CoreGraphics
@testable import CompositorKit

final class ImageSelectionTests:XCTestCase {
    private func image(_ width:Int,_ height:Int,_ color:(Int,Int)->[UInt8]) throws -> CGImage {
        let pixels = (0..<height).flatMap { y in (0..<width).flatMap { color($0,y) } }
        let provider = try XCTUnwrap(CGDataProvider(data:Data(pixels) as CFData))
        return try XCTUnwrap(CGImage(width:width,height:height,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:width*4,
            space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.premultipliedLast.rawValue|CGBitmapInfo.byteOrder32Big.rawValue),
            provider:provider,decode:nil,shouldInterpolate:false,intent:.defaultIntent))
    }
    func testContiguousAndWholeImageDifferAndFourConnectedPixelsDoNotCrossCorners() throws {
        let source = try image(7,3) { x,y in x == 3 || (x == 1 && y == 1) ? [0,0,255,255] : [255,0,0,255] }
        var settings = ImageSelectionSettings();settings.tolerance=0
        let connected = try NumericSelectionRaster.gray(ImageSelectionRaster.wand(source,at:CGPoint(x:0.5,y:0.5),settings:settings))
        XCTAssertEqual(connected.filter{$0>0}.count,8)
        settings.contiguous=false
        let whole = try NumericSelectionRaster.gray(ImageSelectionRaster.wand(source,at:CGPoint(x:0.5,y:0.5),settings:settings))
        XCTAssertEqual(whole.filter{$0>0}.count,17)
        settings.contiguous=true
        let diagonal = try image(2,2) { x,y in x == y ? [255,0,0,255] : [0,0,255,255] }
        XCTAssertEqual(try NumericSelectionRaster.gray(ImageSelectionRaster.wand(diagonal,at:.zero,settings:settings)),[255,0,0,0])
    }
    func testToleranceIncludesAlphaAndEveryColorChannel() throws {
        let source = try image(4,1) { x,_ in [[100,0,0,128],[100,0,0,129],[100,1,0,128],[100,0,2,128]][x] }
        var settings = ImageSelectionSettings();settings.tolerance=1;settings.contiguous=false
        XCTAssertEqual(try NumericSelectionRaster.gray(ImageSelectionRaster.wand(source,at:.zero,settings:settings)),[255,255,255,0])
        settings.tolerance=0
        XCTAssertEqual(try NumericSelectionRaster.gray(ImageSelectionRaster.wand(source,at:.zero,settings:settings)),[255,0,0,0])
    }
    func testAverageSampleClampsToCanvasAndNoMatchesStayExplicitBlack() throws {
        let source = try image(3,1) { x,_ in [UInt8(x*90),UInt8(x*90),UInt8(x*90),255] }
        var settings = ImageSelectionSettings();settings.tolerance=0;settings.sampleRadius=1;settings.contiguous=false
        XCTAssertEqual(try NumericSelectionRaster.gray(ImageSelectionRaster.wand(source,at:CGPoint(x:1,y:0),settings:settings)),[0,255,0])
        XCTAssertEqual(try NumericSelectionRaster.gray(ImageSelectionRaster.wand(source,at:.zero,settings:settings)),[0,0,0])
    }
    func testInvalidSettingsAndNonfinitePointsRejectBeforeIntegerConversion() throws {
        let source = try image(2,2) { _,_ in [0,0,0,0] }
        for point in [CGPoint(x:CGFloat.infinity,y:0),CGPoint(x:CGFloat.nan,y:0),CGPoint(x:-1,y:0),CGPoint(x:2,y:0)] {
            XCTAssertThrowsError(try ImageSelectionRaster.wand(source,at:point,settings:ImageSelectionSettings()))
        }
        var settings = ImageSelectionSettings();settings.sampleRadius=3
        XCTAssertThrowsError(try ImageSelectionRaster.wand(source,at:.zero,settings:settings))
        settings.sampleRadius=0;settings.tolerance = -1
        XCTAssertThrowsError(try ImageSelectionRaster.wand(source,at:.zero,settings:settings))
    }
    func testExpansionPreservesSoftValuesAndContractionTreatsBeyondCanvasAsBlack() throws {
        let soft = try NumericSelectionRaster.grayImage([0,0,0,0,128,0,0,0,0],width:3,height:3)
        XCTAssertEqual(try NumericSelectionRaster.gray(ImageSelectionRaster.resized(soft,amount:1)),Array(repeating:128,count:9))
        let white = try NumericSelectionRaster.grayImage(Array(repeating:255,count:25),width:5,height:5)
        let eroded = try NumericSelectionRaster.gray(ImageSelectionRaster.resized(white,amount:-1))
        XCTAssertEqual(eroded,(0..<25).map { let x=$0%5,y=$0/5;return x>0 && x<4 && y>0 && y<4 ? UInt8(255):0 })
        XCTAssertEqual(try NumericSelectionRaster.gray(ImageSelectionRaster.resized(white,amount:-3)),Array(repeating:0,count:25))
        XCTAssertEqual(try NumericSelectionRaster.gray(ImageSelectionRaster.resized(soft,amount:0)),try NumericSelectionRaster.gray(soft))
    }
    func testDequeMorphologyMatchesNaiveNumericReferenceAndKeepsHoles() throws {
        let width=7,height=5,values:[UInt8]=(0..<35).map { UInt8(($0*37)%256) }
        let mask = try NumericSelectionRaster.grayImage(values,width:width,height:height)
        for amount in [-3,-1,1,2] {
            let radius=abs(amount),maximum=amount>0
            let expected:[UInt8]=(0..<values.count).map { index in
                let x=index%width,y=index/width
                var neighborhood=[UInt8]()
                for row in y-radius...y+radius {for column in x-radius...x+radius {
                    neighborhood.append((0..<width).contains(column) && (0..<height).contains(row) ? values[row*width+column]:0)
                }}
                return maximum ? neighborhood.max()! : neighborhood.min()!
            }
            XCTAssertEqual(try NumericSelectionRaster.gray(ImageSelectionRaster.resized(mask,amount:amount)),expected)
        }
    }
    func testNumericGrayEncodingHasNoAlphaAndSelectionCombinationDoesNotSquareCoverage() throws {
        let mask = try NumericSelectionRaster.grayImage([0,128,255,64],width:2,height:2)
        let expanded = try ImageSelectionRaster.resized(mask,amount:1)
        XCTAssertEqual(expanded.bitsPerPixel,8);XCTAssertEqual(expanded.alphaInfo,.none)
        let same = try XCTUnwrap(SelectionMask.combine(existing:mask,incoming:mask,mode:.intersect))
        XCTAssertEqual(try NumericSelectionRaster.gray(same),[0,128,255,64])
        let stored = try RasterImage.decode(RasterImage.png(mask))
        XCTAssertEqual(try NumericSelectionRaster.gray(stored),[0,128,255,64])
    }
}
