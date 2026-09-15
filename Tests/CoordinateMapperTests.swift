import XCTest
@testable import VibeStudio

final class CoordinateMapperTests: XCTestCase {
    // Primary display: 1440x900 points, retina scale 2.
    private let primaryHeight: CGFloat = 900

    func testAppKitToCGPointFlip() {
        // AppKit bottom-left (0,0) -> CG bottom edge y = primaryHeight.
        XCTAssertEqual(CoordinateMapper.appKitPointToCG(CGPoint(x: 0, y: 0), primaryHeight: primaryHeight),
                       CGPoint(x: 0, y: 900))
        XCTAssertEqual(CoordinateMapper.appKitPointToCG(CGPoint(x: 10, y: 900), primaryHeight: primaryHeight),
                       CGPoint(x: 10, y: 0))
    }

    func testCGToAppKitIsInverse() {
        let point = CGPoint(x: 123, y: 456)
        let cg = CoordinateMapper.appKitPointToCG(point, primaryHeight: primaryHeight)
        XCTAssertEqual(CoordinateMapper.cgPointToAppKit(cg, primaryHeight: primaryHeight), point)
    }

    func testAppKitRectToCGFlipsWithinRect() {
        // A 200x100 rect hugging the TOP of a 900pt-tall primary screen.
        let appKit = CGRect(x: 100, y: 800, width: 200, height: 100)
        let cg = CoordinateMapper.appKitRectToCG(appKit, primaryHeight: primaryHeight)
        XCTAssertEqual(cg, CGRect(x: 100, y: 0, width: 200, height: 100))
    }

    func testDisplayModeMappingScale2() {
        let mapping = CaptureMapping.display(frameCG: CGRect(x: 0, y: 0, width: 1440, height: 900), scale: 2)
        XCTAssertEqual(mapping.videoPixel(forGlobalCGPoint: CGPoint(x: 10, y: 20)), CGPoint(x: 20, y: 40))
        XCTAssertEqual(mapping.videoPixel(forGlobalCGPoint: CGPoint(x: 1440, y: 900)), CGPoint(x: 2880, y: 1800))
    }

    func testDisplayModeMappingScale1SecondaryDisplay() {
        // Secondary display to the right of the primary, scale 1.
        let mapping = CaptureMapping.display(frameCG: CGRect(x: 1440, y: 0, width: 1920, height: 1080), scale: 1)
        XCTAssertEqual(mapping.videoPixel(forGlobalCGPoint: CGPoint(x: 1500, y: 50)), CGPoint(x: 60, y: 50))
    }

    func testWindowModeMapping() {
        let mapping = CaptureMapping.window(frameCG: CGRect(x: 100, y: 100, width: 400, height: 300), scale: 2)
        XCTAssertEqual(mapping.videoPixel(forGlobalCGPoint: CGPoint(x: 150, y: 200)), CGPoint(x: 100, y: 200))
        // Points outside the window are allowed (negative/overshoot) — Phase 2 clamps.
        XCTAssertEqual(mapping.videoPixel(forGlobalCGPoint: CGPoint(x: 50, y: 50)), CGPoint(x: -100, y: -100))
    }

    func testAreaSourceRectPixelsYFlipScale2() {
        // User drags a 200x100pt rect at the TOP of the primary screen (AppKit y = 800).
        let drag = CGRect(x: 100, y: 800, width: 200, height: 100)
        let displayFrameCG = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let source = CoordinateMapper.areaSourceRectPixels(dragRectAppKitGlobal: drag,
                                                           displayFrameCG: displayFrameCG,
                                                           scale: 2,
                                                           primaryHeight: primaryHeight)
        // CG rect is y=0 (top), pixels double: (200, 0, 400, 200).
        XCTAssertEqual(source, CGRect(x: 200, y: 0, width: 400, height: 200))
    }

    func testAreaModeEventProjection() {
        let displayFrameCG = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let source = CGRect(x: 200, y: 0, width: 400, height: 200)
        let mapping = CaptureMapping.area(displayFrameCG: displayFrameCG, sourceRectPixels: source, scale: 2)
        // CG point (150, 50) -> display-local (150, 50) -> pixels (300, 100) -> minus source origin (200, 0).
        XCTAssertEqual(mapping.videoPixel(forGlobalCGPoint: CGPoint(x: 150, y: 50)), CGPoint(x: 100, y: 100))
    }

    func testAreaModeScale1() {
        let displayFrameCG = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let drag = CGRect(x: 0, y: 0, width: 100, height: 50) // bottom-left corner in AppKit
        let source = CoordinateMapper.areaSourceRectPixels(dragRectAppKitGlobal: drag,
                                                           displayFrameCG: displayFrameCG,
                                                           scale: 1,
                                                           primaryHeight: 1080)
        // Bottom-left in AppKit -> y = 1080 - 50 = 1030 in CG top-left space.
        XCTAssertEqual(source, CGRect(x: 0, y: 1030, width: 100, height: 50))
        let mapping = CaptureMapping.area(displayFrameCG: displayFrameCG, sourceRectPixels: source, scale: 1)
        XCTAssertEqual(mapping.videoPixel(forGlobalCGPoint: CGPoint(x: 10, y: 1040)), CGPoint(x: 10, y: 10))
    }

    func testCappedPixelSize() {
        XCTAssertEqual(CoordinateMapper.cappedPixelSize(native: CGSize(width: 2880, height: 1800), cap: .native),
                       CGSize(width: 2880, height: 1800))
        XCTAssertEqual(CoordinateMapper.cappedPixelSize(native: CGSize(width: 2880, height: 1800), cap: .p1080),
                       CGSize(width: 1728, height: 1080))
        XCTAssertEqual(CoordinateMapper.cappedPixelSize(native: CGSize(width: 5120, height: 2880), cap: .p4k),
                       CGSize(width: 3840, height: 2160))
        // Odd sizes round to even for H.264.
        let capped = CoordinateMapper.cappedPixelSize(native: CGSize(width: 1111, height: 1081), cap: .p1080)
        XCTAssertEqual(Int(capped.width) % 2, 0)
        XCTAssertEqual(Int(capped.height) % 2, 0)
    }
}
