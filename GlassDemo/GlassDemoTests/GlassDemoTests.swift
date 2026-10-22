//
//  GlassDemoTests.swift
//  GlassDemoTests
//
//  Created by dongchankim on 10/21/26.
//

import CoreGraphics
import Testing
@testable import GlassDemo

struct GlassDemoTests {

    @Test func visionBoxFlipsYAxis() {
        // 좌하단 1/4 영역 → SwiftUI에서는 아래쪽
        let r = viewRect(normalized: CGRect(x: 0, y: 0, width: 0.5, height: 0.25),
                         imageSize: CGSize(width: 100, height: 200), viewSize: CGSize(width: 100, height: 200))
        #expect(r == CGRect(x: 0, y: 150, width: 50, height: 50))
    }

    @Test func visionBoxAccountsForAspectFillCrop() {
        // 504x896 영상을 393x852 화면에 aspect-fill → 세로 기준 스케일, 좌우가 잘림
        let r = viewRect(normalized: CGRect(x: 0.5, y: 0.5, width: 0, height: 0),
                         imageSize: CGSize(width: 504, height: 896), viewSize: CGSize(width: 393, height: 852))
        #expect(abs(r.midX - 393 / 2) < 0.001)
        #expect(abs(r.midY - 852 / 2) < 0.001)
    }

}
