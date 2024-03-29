//
//  MetalRender.swift
//  KSPlayer-iOS
//
//  Created by kintan on 2020/1/11.
//
import Accelerate
import CoreVideo
import Foundation
import Metal
import QuartzCore
import simd
import CompositorServices
import Spatial

struct CustomData {
    public var stereoMode: Int32 = 0
    public var swapEyes: Int32 = 0
    public var ipd: Float = 0
}

struct HandTrackingInfo {
    public var lastTapTimestamp: TimeInterval = 0.0
    
    public var pinchStart: Bool = false
    public var pinching: Bool = false
    public var pinchEnd: Bool = false
    
    public var tapped: Bool = false
    public var doubleTapped: Bool = false
}

struct Uniforms {
    var projectionMatrix: simd_float4x4
    var modelViewMatrix: simd_float4x4
}

struct UniformsArray {
    var uniforms: (Uniforms, Uniforms)
}

extension LayerRenderer.Clock.Instant.Duration {
    var timeInterval: TimeInterval {
        let nanoseconds = TimeInterval(components.attoseconds / 1_000_000_000)
        return TimeInterval(components.seconds) + (nanoseconds / TimeInterval(NSEC_PER_SEC))
    }
}

let alignedUniformsSize = (MemoryLayout<UniformsArray>.size + 0xFF) & -0x100
let maxBuffersInFlight = 3

class MetalRender {
    static var customBuffer: CustomData = CustomData()
    static var options: MoonOptions? = MoonOptions()
    static let device = MTLCreateSystemDefaultDevice()!
    let inFlightSemaphore = DispatchSemaphore(value: maxBuffersInFlight)
    static let library: MTLLibrary = {
        var library: MTLLibrary!
        library = device.makeDefaultLibrary()
        if library == nil {
            library = try? device.makeDefaultLibrary(bundle: .module)
        }
        return library
    }()

    private var lastPassDescriptor: MTLRenderPassDescriptor?
    private let immersivePassDescriptor = MTLRenderPassDescriptor()
    private let planePassDescriptor = MTLRenderPassDescriptor()
    private var dynamicUniformBuffer: MTLBuffer
    private var depthState: MTLDepthStencilState
    private var uniforms: UnsafeMutablePointer<UniformsArray>
    private var uniformBufferOffset = 0
    private var uniformBufferIndex = 0
    private var rightHandInfo: HandTrackingInfo
    private var leftHandInfo: HandTrackingInfo
    private let commandQueue = MetalRender.device.makeCommandQueue()
    private lazy var samplerState: MTLSamplerState? = {
        let samplerDescriptor = MTLSamplerDescriptor()
        samplerDescriptor.minFilter = .linear
        samplerDescriptor.magFilter = .linear
        return MetalRender.device.makeSamplerState(descriptor: samplerDescriptor)
    }()

    private lazy var colorConversion601VideoRangeMatrixBuffer: MTLBuffer? = kvImage_YpCbCrToARGBMatrix_ITU_R_601_4.pointee.videoRange.buffer

    private lazy var colorConversion601FullRangeMatrixBuffer: MTLBuffer? = kvImage_YpCbCrToARGBMatrix_ITU_R_601_4.pointee.buffer

    private lazy var colorConversion709VideoRangeMatrixBuffer: MTLBuffer? = kvImage_YpCbCrToARGBMatrix_ITU_R_709_2.pointee.videoRange.buffer

    private lazy var colorConversion709FullRangeMatrixBuffer: MTLBuffer? = kvImage_YpCbCrToARGBMatrix_ITU_R_709_2.pointee.buffer

    private lazy var colorConversionSMPTE240MVideoRangeMatrixBuffer: MTLBuffer? = kvImage_YpCbCrToARGBMatrix_SMPTE_240M_1995.videoRange.buffer

    private lazy var colorConversionSMPTE240MFullRangeMatrixBuffer: MTLBuffer? = kvImage_YpCbCrToARGBMatrix_SMPTE_240M_1995.buffer

    private lazy var colorConversion2020VideoRangeMatrixBuffer: MTLBuffer? = kvImage_YpCbCrToARGBMatrix_ITU_R_2020.videoRange.buffer

    private lazy var colorConversion2020FullRangeMatrixBuffer: MTLBuffer? = kvImage_YpCbCrToARGBMatrix_ITU_R_2020.buffer

    private lazy var colorOffsetVideoRangeMatrixBuffer: MTLBuffer? = {
        var firstColumn = SIMD3<Float>(-16.0 / 255.0, -128.0 / 255.0, -128.0 / 255.0)
        let buffer = MetalRender.device.makeBuffer(bytes: &firstColumn, length: MemoryLayout<SIMD3<Float>>.size)
        buffer?.label = "colorOffset"
        return buffer
    }()

    private lazy var colorOffsetFullRangeMatrixBuffer: MTLBuffer? = {
        var firstColumn = SIMD3<Float>(0, -128.0 / 255.0, -128.0 / 255.0)
        let buffer = MetalRender.device.makeBuffer(bytes: &firstColumn, length: MemoryLayout<SIMD3<Float>>.size)
        buffer?.label = "colorOffset"
        return buffer
    }()

    private lazy var leftShiftMatrixBuffer: MTLBuffer? = {
        var firstColumn = SIMD3<UInt8>(1, 1, 1)
        let buffer = MetalRender.device.makeBuffer(bytes: &firstColumn, length: MemoryLayout<SIMD3<UInt8>>.size)
        buffer?.label = "leftShit"
        return buffer
    }()

    private lazy var leftShiftSixMatrixBuffer: MTLBuffer? = {
        var firstColumn = SIMD3<UInt8>(64, 64, 64)
        let buffer = MetalRender.device.makeBuffer(bytes: &firstColumn, length: MemoryLayout<SIMD3<UInt8>>.size)
        buffer?.label = "leftShit"
        return buffer
    }()
    
    private lazy var customDataBuffer: MTLBuffer? = {
        let buffer = MetalRender.device.makeBuffer(length: MemoryLayout<CustomData>.size, options: .storageModeShared)
        buffer?.label = "customData"
        return buffer
    }()

    public init() {
        rightHandInfo = HandTrackingInfo()
        leftHandInfo = HandTrackingInfo()
        
        // DynamicUniformBuffer
        let uniformBufferSize = alignedUniformsSize * maxBuffersInFlight
        self.dynamicUniformBuffer = MetalRender.device.makeBuffer(length:uniformBufferSize, options:[MTLResourceOptions.storageModeShared])!
        self.dynamicUniformBuffer.label = "UniformBuffer"
        uniforms = UnsafeMutableRawPointer(dynamicUniformBuffer.contents()).bindMemory(to:UniformsArray.self, capacity:1)
        
        // DepthStencilState
        let depthStateDescriptor = MTLDepthStencilDescriptor()
        depthStateDescriptor.depthCompareFunction = MTLCompareFunction.greater
        depthStateDescriptor.isDepthWriteEnabled = true
        self.depthState = MetalRender.device.makeDepthStencilState(descriptor: depthStateDescriptor)!
    }
    
    func clear(drawable: MTLDrawable) {
        guard let passDescriptor = lastPassDescriptor else {
            return
        }
        passDescriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        guard let commandBuffer = commandQueue?.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: passDescriptor)
        else {
            return
        }
        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
    }

    func drawPlane(pixelBuffer: PixelBufferProtocol, display: DisplayEnum = .plane, drawable: CAMetalDrawable, size: CGSize) {
        let inputTextures = pixelBuffer.textures()
        lastPassDescriptor = planePassDescriptor
        planePassDescriptor.colorAttachments[0].texture = drawable.texture
        planePassDescriptor.renderTargetArrayLength = 1
        guard !inputTextures.isEmpty, let commandBuffer = commandQueue?.makeCommandBuffer(), let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: planePassDescriptor) else {
            return
        }
        encoder.pushDebugGroup("RenderFrame")
        let state = display.pipeline(planeCount: pixelBuffer.planeCount, bitDepth: pixelBuffer.bitDepth)
        if MetalRender.device.supportsVertexAmplificationCount(2) {
            var viewMappings = (0..<2).map {
                MTLVertexAmplificationViewMapping(viewportArrayIndexOffset: UInt32($0),
                                                  renderTargetArrayIndexOffset: UInt32($0))
            }
            
            encoder.setVertexAmplificationCount(2, viewMappings: &viewMappings)
        }
        encoder.setRenderPipelineState(state)
        encoder.setFragmentSamplerState(samplerState, index: 0)
        for (index, texture) in inputTextures.enumerated() {
            texture.label = "texture\(index)"
            encoder.setFragmentTexture(texture, index: index)
        }
        setBuffer(pixelBuffer: pixelBuffer, encoder: encoder)
        display.set(encoder: encoder, size: size)
        encoder.popDebugGroup()
        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
    }
    
    func drawImmersive(pixelBuffer: PixelBufferProtocol, display: DisplayEnum = .plane, size: CGSize) {
        guard let layerRenderer = MetalRender.options?.layerRenderer else {
            return
        }
        guard let frame = layerRenderer.queryNextFrame() else { return }
        
        frame.startUpdate()
        
        frame.endUpdate()
        
        guard let timing = frame.predictTiming() else { return }
        LayerRenderer.Clock().wait(until: timing.optimalInputTime)
        
        guard let drawable = frame.queryDrawable() else { return }
        
        _ = inFlightSemaphore.wait(timeout: DispatchTime.distantFuture)
        
        frame.startSubmission()
        
        let time = LayerRenderer.Clock.Instant.epoch.duration(to: drawable.frameTiming.presentationTime).timeInterval
        if let worldTracking = MoonOptions.worldTracking {
            let deviceAnchor = worldTracking.queryDeviceAnchor(atTimestamp: time)
            drawable.deviceAnchor = deviceAnchor
            self.updateDynamicBufferState()
            self.uniforms[0].uniforms.0 = uniforms(drawable: drawable, deviceAnchor: deviceAnchor, forViewIndex: 0)
            if drawable.views.count > 1 {
                self.uniforms[0].uniforms.1 = uniforms(drawable: drawable, deviceAnchor: deviceAnchor, forViewIndex: 1)
            }
        }
        
        if let handTracking = MoonOptions.handTracking {
            let anchors = handTracking.latestAnchors
            
            updateHandTrackingInfo(anchors.leftHand, info: &leftHandInfo, atTimestamp: time)
            updateHandTrackingInfo(anchors.rightHand, info: &rightHandInfo, atTimestamp: time)
        }
    
        let inputTextures = pixelBuffer.textures()
        lastPassDescriptor = immersivePassDescriptor
        immersivePassDescriptor.colorAttachments[0].texture = drawable.colorTextures[0]
        immersivePassDescriptor.colorAttachments[0].loadAction = .clear
        immersivePassDescriptor.colorAttachments[0].storeAction = .store
        immersivePassDescriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0.0, green: 0.0, blue: 0.0, alpha: 0.0)
        immersivePassDescriptor.depthAttachment.texture = drawable.depthTextures[0]
        immersivePassDescriptor.depthAttachment.loadAction = .clear
        immersivePassDescriptor.depthAttachment.storeAction = .store
        immersivePassDescriptor.depthAttachment.clearDepth = 0.0
        immersivePassDescriptor.rasterizationRateMap = drawable.rasterizationRateMaps.first
        if layerRenderer.configuration.layout == .layered {
            immersivePassDescriptor.renderTargetArrayLength = drawable.views.count
        }
        
        guard !inputTextures.isEmpty, let commandBuffer = commandQueue!.makeCommandBuffer(), let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: immersivePassDescriptor) else {
            return
        }
        
        let semaphore = inFlightSemaphore
        commandBuffer.addCompletedHandler { (_ commandBuffer)-> Swift.Void in
            semaphore.signal()
        }
        
        encoder.pushDebugGroup("RenderFrame")
        let state = display.pipeline(planeCount: pixelBuffer.planeCount, bitDepth: pixelBuffer.bitDepth)
        encoder.setRenderPipelineState(state)
        encoder.setDepthStencilState(depthState)
        
        encoder.setVertexBuffer(dynamicUniformBuffer, offset: uniformBufferOffset, index: 9)
        let viewports = drawable.views.map { $0.textureMap.viewport }
        encoder.setViewports(viewports)
        if drawable.views.count > 1 {
            var viewMappings = (0..<drawable.views.count).map {
                MTLVertexAmplificationViewMapping(viewportArrayIndexOffset: UInt32($0),
                                                  renderTargetArrayIndexOffset: UInt32($0))
            }
            encoder.setVertexAmplificationCount(viewports.count, viewMappings: &viewMappings)
        }
        
//        let simdDeviceAnchor = deviceAnchor?.originFromAnchorTransform ?? matrix_identity_float4x4
//        let viewMatrix = (simdDeviceAnchor * drawable.views[0].transform).inverse
        
        encoder.setFragmentSamplerState(samplerState, index: 0)
        for (index, texture) in inputTextures.enumerated() {
            texture.label = "texture\(index)"
            encoder.setFragmentTexture(texture, index: index)
        }
        setBuffer(pixelBuffer: pixelBuffer, encoder: encoder)
        
        display.set(encoder: encoder, size: size)
        encoder.popDebugGroup()
        encoder.endEncoding()
        drawable.encodePresent(commandBuffer: commandBuffer)
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        
        frame.endSubmission()
    }
    
    func updateCustomDataBuffer() {
        MetalRender.customBuffer.stereoMode = Int32((MetalRender.options?.stereo.rawValue)!)
        MetalRender.customBuffer.swapEyes = (MetalRender.options?.playbackSettings.swapEyes)! ? 1:0
        MetalRender.customBuffer.ipd = MetalRender.options?.playbackSettings.ipd ?? 0.0
        let bufferPointer = customDataBuffer?.contents()
        bufferPointer!.copyMemory(from: &MetalRender.customBuffer, byteCount: MemoryLayout<CustomData>.size)
    }

    private func setBuffer(pixelBuffer: PixelBufferProtocol, encoder: MTLRenderCommandEncoder) {
        if pixelBuffer.planeCount > 1 {
            let buffer: MTLBuffer?
            let yCbCrMatrix = pixelBuffer.yCbCrMatrix
            let isFullRangeVideo = pixelBuffer.isFullRangeVideo
            if yCbCrMatrix == kCVImageBufferYCbCrMatrix_ITU_R_709_2 {
                buffer = isFullRangeVideo ? colorConversion709FullRangeMatrixBuffer : colorConversion709VideoRangeMatrixBuffer
            } else if yCbCrMatrix == kCVImageBufferYCbCrMatrix_SMPTE_240M_1995 {
                buffer = isFullRangeVideo ? colorConversionSMPTE240MFullRangeMatrixBuffer : colorConversionSMPTE240MVideoRangeMatrixBuffer
            } else if yCbCrMatrix == kCVImageBufferYCbCrMatrix_ITU_R_2020 {
                buffer = isFullRangeVideo ? colorConversion2020FullRangeMatrixBuffer : colorConversion2020VideoRangeMatrixBuffer
            } else {
                buffer = isFullRangeVideo ? colorConversion601FullRangeMatrixBuffer : colorConversion601VideoRangeMatrixBuffer
            }
            encoder.setFragmentBuffer(buffer, offset: 0, index: 0)
            let colorOffset = isFullRangeVideo ? colorOffsetFullRangeMatrixBuffer : colorOffsetVideoRangeMatrixBuffer
            encoder.setFragmentBuffer(colorOffset, offset: 0, index: 1)
            let leftShift = pixelBuffer.leftShift == 0 ? leftShiftMatrixBuffer : leftShiftSixMatrixBuffer
            encoder.setFragmentBuffer(leftShift, offset: 0, index: 2)
            
        }
        
        // Custom data
        updateCustomDataBuffer()
        encoder.setVertexBuffer(customDataBuffer, offset: 0, index: 3)
        encoder.setFragmentBuffer(customDataBuffer, offset: 0, index: 3)
        
        // Size
    }
    
    private func updateDynamicBufferState() {
        uniformBufferIndex = (uniformBufferIndex + 1) % maxBuffersInFlight
        uniformBufferOffset = alignedUniformsSize * uniformBufferIndex
        uniforms = UnsafeMutableRawPointer(dynamicUniformBuffer.contents() + uniformBufferOffset).bindMemory(to:UniformsArray.self, capacity:1)
    }
    
    private func updateHandTrackingInfo(_ hand: HandAnchor?, info: inout HandTrackingInfo, atTimestamp: TimeInterval) {
        guard let hand else {
            return
        }
        
        guard let skeleton = hand.handSkeleton else {
            return
        }
        
        let originFromThumbTipTransform = matrix_multiply(hand.originFromAnchorTransform, skeleton.joint(.thumbTip).anchorFromJointTransform).columns.3
        
        let originFromMiddleTipTransform = matrix_multiply(hand.originFromAnchorTransform, skeleton.joint(.middleFingerTip).anchorFromJointTransform).columns.3
        
        let pinchDistance = distance(originFromMiddleTipTransform, originFromThumbTipTransform)
        
        // When pinched
        if pinchDistance <= 0.015 {
            if info.pinchStart {
                info.pinchStart = false
                info.pinching = true
            } else if info.pinching {
                // nothing here
            } else {
                info.pinchStart = true
            }
        } else {
            if info.pinching {
                info.pinchEnd = true
                print("pinch end")
            } else if info.pinchEnd {
                info.pinchEnd = false
                //info.tapped = true
                //
                if atTimestamp - info.lastTapTimestamp < 0.6 {
                    // double tapped
                    //info.doubleTapped = true
                    info.lastTapTimestamp = 0
                    print("double tapped")
                    MoonOptions.doubleMiddleTapHandler()
                } else {
                    // just tapped
                    info.lastTapTimestamp = atTimestamp
                    MoonOptions.singleMiddleTapHandler()
                }
            } 
//            else if info.tapped {
//                info.tapped = false
//                info.doubleTapped = false
//            }
            info.pinchStart = false
            info.pinching = false
        }
    }
    
    private func uniforms(drawable: LayerRenderer.Drawable, deviceAnchor: DeviceAnchor?, forViewIndex viewIndex: Int) -> Uniforms {
        let translationMatrix = matrix4x4_translation(0,
                                                      Float(MetalRender.options!.playbackSettings.screenHeight ?? 0), 
                                                      Float(MetalRender.options!.playbackSettings
                                                        .screenZoom ?? 0))
        let rotationMatrix = simd_float4x4(rotationX: radians_from_degrees(Float(MetalRender.options!.playbackSettings.screenTilt ?? 0)))
    
        let modelMatrix = translationMatrix * rotationMatrix
        
        let simdDeviceAnchor = deviceAnchor?.originFromAnchorTransform ?? matrix_identity_float4x4
        let view = drawable.views[viewIndex]
        let viewMatrix = (simdDeviceAnchor * view.transform).inverse
        let projection = ProjectiveTransform3D(leftTangent: Double(view.tangents[0]),
                                               rightTangent: Double(view.tangents[1]),
                                               topTangent: Double(view.tangents[2]),
                                               bottomTangent: Double(view.tangents[3]),
                                               nearZ: Double(drawable.depthRange.y),
                                               farZ: Double(drawable.depthRange.x),
                                               reverseZ: true)
        

        
        var modelViewMatrix = viewMatrix * modelMatrix
        
        let uniforms = Uniforms(projectionMatrix: .init(projection), modelViewMatrix: modelViewMatrix)
        return uniforms
    }
    
    // Generic matrix math utility functions
    private func matrix4x4_rotation(radians: Float, axis: SIMD3<Float>) -> matrix_float4x4 {
        let unitAxis = normalize(axis)
        let ct = cosf(radians)
        let st = sinf(radians)
        let ci = 1 - ct
        let x = unitAxis.x, y = unitAxis.y, z = unitAxis.z
        return matrix_float4x4.init(columns:(vector_float4(    ct + x * x * ci, y * x * ci + z * st, z * x * ci - y * st, 0),
                                             vector_float4(x * y * ci - z * st,     ct + y * y * ci, z * y * ci + x * st, 0),
                                             vector_float4(x * z * ci + y * st, y * z * ci - x * st,     ct + z * z * ci, 0),
                                             vector_float4(                  0,                   0,                   0, 1)))
    }

    private func matrix4x4_translation(_ translationX: Float, _ translationY: Float, _ translationZ: Float) -> matrix_float4x4 {
        return matrix_float4x4.init(columns:(vector_float4(1, 0, 0, 0),
                                             vector_float4(0, 1, 0, 0),
                                             vector_float4(0, 0, 1, 0),
                                             vector_float4(translationX, translationY, translationZ, 1)))
    }

    private func radians_from_degrees(_ degrees: Float) -> Float {
        return (degrees / 180) * .pi
    }

    static func makePipelineState(fragmentFunction: String, isSphere: Bool = false, bitDepth: Int32 = 8) -> MTLRenderPipelineState {
        
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.colorAttachments[0].pixelFormat = MoonOptions.colorPixelFormat(bitDepth: bitDepth)
        descriptor.vertexFunction = library.makeFunction(name: isSphere ? "mapSphereTexture" : "mapTexture")
        descriptor.fragmentFunction = library.makeFunction(name: fragmentFunction)
        
//        if isSphere {
//            if let layerRenderer = MetalRender.options?.layerRenderer {
//                descriptor.depthAttachmentPixelFormat = layerRenderer.configuration.depthFormat
//                descriptor.maxVertexAmplificationCount = layerRenderer.properties.viewCount
//            }
//        } else {
//            descriptor.depthAttachmentPixelFormat = .invalid
//            descriptor.maxVertexAmplificationCount = MetalRender.device.supportsVertexAmplificationCount(2) ? 2 : 1
//        }
        if let layerRenderer = MetalRender.options?.layerRenderer {
            descriptor.depthAttachmentPixelFormat = layerRenderer.configuration.depthFormat
            descriptor.maxVertexAmplificationCount = layerRenderer.properties.viewCount
        } else {
            descriptor.depthAttachmentPixelFormat = .invalid
            descriptor.maxVertexAmplificationCount = MetalRender.device.supportsVertexAmplificationCount(2) ? 2 : 1
        }
        
        let vertexDescriptor = MTLVertexDescriptor()
        vertexDescriptor.attributes[0].format = .float3
        vertexDescriptor.attributes[0].bufferIndex = 0
        vertexDescriptor.attributes[0].offset = 0
        vertexDescriptor.attributes[1].format = .float2
        vertexDescriptor.attributes[1].bufferIndex = 1
        vertexDescriptor.attributes[1].offset = 0
        vertexDescriptor.layouts[0].stride = 12
        vertexDescriptor.layouts[1].stride = 8
        descriptor.vertexDescriptor = vertexDescriptor
        // swiftlint:disable force_try
        return try! library.device.makeRenderPipelineState(descriptor: descriptor)
        // swftlint:enable force_try
    }

    static func texture(pixelBuffer: CVPixelBuffer) -> [MTLTexture] {
        guard let iosurface = CVPixelBufferGetIOSurface(pixelBuffer)?.takeUnretainedValue() else {
            return []
        }
        let formats = MoonOptions.pixelFormat(planeCount: pixelBuffer.planeCount, bitDepth: pixelBuffer.bitDepth)
        return (0 ..< pixelBuffer.planeCount).compactMap { index in
            let width = pixelBuffer.widthOfPlane(at: index)
            let height = pixelBuffer.heightOfPlane(at: index)
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: formats[index], width: width, height: height, mipmapped: false)
            return device.makeTexture(descriptor: descriptor, iosurface: iosurface, plane: index)
        }
    }

    static func textures(formats: [MTLPixelFormat], widths: [Int], heights: [Int], buffers: [MTLBuffer?], lineSizes: [Int]) -> [MTLTexture] {
        (0 ..< formats.count).compactMap { i in
            guard let buffer = buffers[i] else {
                return nil
            }
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: formats[i], width: widths[i], height: heights[i], mipmapped: false)
            descriptor.storageMode = buffer.storageMode
            return buffer.makeTexture(descriptor: descriptor, offset: 0, bytesPerRow: lineSizes[i])
        }
    }
}

// swiftlint:disable identifier_name
// private let kvImage_YpCbCrToARGBMatrix_ITU_R_601_4 = vImage_YpCbCrToARGBMatrix(Kr: 0.299, Kb: 0.114)
// private let kvImage_YpCbCrToARGBMatrix_ITU_R_709_2 = vImage_YpCbCrToARGBMatrix(Kr: 0.2126, Kb: 0.0722)
private let kvImage_YpCbCrToARGBMatrix_SMPTE_240M_1995 = vImage_YpCbCrToARGBMatrix(Kr: 0.212, Kb: 0.087)
private let kvImage_YpCbCrToARGBMatrix_ITU_R_2020 = vImage_YpCbCrToARGBMatrix(Kr: 0.2627, Kb: 0.0593)
extension vImage_YpCbCrToARGBMatrix {
    /**
     https://en.wikipedia.org/wiki/YCbCr
     @textblock
            | R |    | 1    0                                                            2-2Kr |   | Y' |
            | G | = | 1   -Kb * (2 - 2 * Kb) / Kg   -Kr * (2 - 2 * Kr) / Kg |  | Cb |
            | B |    | 1   2 - 2 * Kb                                                     0  |  | Cr |
     @/textblock
     */
    init(Kr: Float, Kb: Float) {
        let Kg = 1 - Kr - Kb
        self.init(Yp: 1, Cr_R: 2 - 2 * Kr, Cr_G: -Kr * (2 - 2 * Kr) / Kg, Cb_G: -Kb * (2 - 2 * Kb) / Kg, Cb_B: 2 - 2 * Kb)
    }

    var videoRange: vImage_YpCbCrToARGBMatrix {
        vImage_YpCbCrToARGBMatrix(Yp: 255 / 219 * Yp, Cr_R: 255 / 224 * Cr_R, Cr_G: 255 / 224 * Cr_G, Cb_G: 255 / 224 * Cb_G, Cb_B: 255 / 224 * Cb_B)
    }

    var buffer: MTLBuffer? {
        var matrix = simd_float3x3([Yp, Yp, Yp], [0.0, Cb_G, Cb_B], [Cr_R, Cr_G, 0.0])
        let buffer = MetalRender.device.makeBuffer(bytes: &matrix, length: MemoryLayout<simd_float3x3>.size)
        buffer?.label = "colorConversionMatrix"
        return buffer
    }
}

// swiftlint:enable identifier_name
