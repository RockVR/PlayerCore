//
//  MetalPlayView.swift
//  KSPlayer
//
//  Created by kintan on 2018/3/11.
//

import AVFoundation
import Combine
import CoreMedia
#if canImport(MetalKit)
import MetalKit
#endif
public protocol DisplayLayerDelegate: NSObjectProtocol {
    func change(displayLayer: AVSampleBufferDisplayLayer)
}

public protocol VideoOutput: FrameOutput {
    var displayLayerDelegate: DisplayLayerDelegate? { get set }
    var options: MoonOptions { get set }
    var displayLayer: AVSampleBufferDisplayLayer { get }
    var pixelBuffer: PixelBufferProtocol? { get }
    init(options: MoonOptions)
    func invalidate()
    func play()
    func readNextFrame()
    func resize()
}

public final class MetalPlayView: UIView, VideoOutput {
    public var displayLayer: AVSampleBufferDisplayLayer {
        displayView.displayLayer
    }

    private var isDovi: Bool = false
    private var formatDescription: CMFormatDescription? {
        didSet {
            options.updateVideo(refreshRate: fps, isDovi: isDovi, formatDescription: formatDescription)
        }
    }

    private var fps = Float(60) {
        didSet {
            if fps != oldValue {
                let preferredFramesPerSecond = Int(ceil(fps))
                displayLink.preferredFramesPerSecond = preferredFramesPerSecond << 1
                #if os(iOS)
                if #available(iOS 15.0, tvOS 15.0, *) {
                    displayLink.preferredFrameRateRange = CAFrameRateRange(minimum: Float(preferredFramesPerSecond), maximum: Float(preferredFramesPerSecond << 1))
                }
                #endif
                options.updateVideo(refreshRate: fps, isDovi: isDovi, formatDescription: formatDescription)
            }
        }
    }

    public private(set) var pixelBuffer: PixelBufferProtocol?
    /// 用displayLink会导致锁屏无法draw，
    /// 用DispatchSourceTimer的话，在播放4k视频的时候repeat的时间会变长,
    /// 用MTKView的draw(in:)也是不行，会卡顿
    private var displayLink: CADisplayLink!
    private var idleLink: CADisplayLink!
//    private let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.main)
    public var options: MoonOptions
    public weak var renderSource: OutputRenderSourceDelegate?
    // AVSampleBufferAudioRenderer AVSampleBufferRenderSynchronizer AVSampleBufferDisplayLayer
    var displayView = AVSampleBufferDisplayView() {
        didSet {
            displayLayerDelegate?.change(displayLayer: displayView.displayLayer)
        }
    }

    private let metalView = MetalView()
    private var lastSize: CGSize = .zero
    private var metalViewWidthConstraint: NSLayoutConstraint
    private var metalViewHeightConstraint: NSLayoutConstraint
    private var displayViewWidthConstraint: NSLayoutConstraint
    private var displayViewHeightConstraint: NSLayoutConstraint
    public weak var displayLayerDelegate: DisplayLayerDelegate?
    public init(options: MoonOptions) {
        self.options = options
        self.metalViewWidthConstraint = metalView.widthAnchor.constraint(equalToConstant: 1)
        self.metalViewHeightConstraint = metalView.heightAnchor.constraint(equalToConstant: 1)
        self.displayViewWidthConstraint = displayView.widthAnchor.constraint(equalToConstant: 1)
        self.displayViewHeightConstraint = displayView.heightAnchor.constraint(equalToConstant: 1)
        super.init(frame: .zero)
        addSubview(displayView)
        addSubview(metalView)
        metalView.options = options
        metalView.isHidden = true
        //        displayLink = CADisplayLink(block: renderFrame)
        displayLink = CADisplayLink(target: self, selector: #selector(renderFrame))
        idleLink = CADisplayLink(target: self, selector: #selector(renderIdle))
        // 一定要用common。不然在视频上面操作view的话，那就会卡顿了。
        displayLink.add(to: .main, forMode: .common)
        idleLink.add(to: .main, forMode: .common)
    }

    public func play() {
        displayLink.isPaused = false
        idleLink.isPaused = true
        resize()
    }

    public func pause() {
        displayLink.isPaused = true
        idleLink.isPaused = false
    }

    @available(*, unavailable)
    required init(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override public func didAddSubview(_ subview: UIView) {
        super.didAddSubview(subview)
        subview.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            subview.centerXAnchor.constraint(equalTo: self.centerXAnchor),
            subview.centerYAnchor.constraint(equalTo: self.centerYAnchor),
        ])
    }
    
    override public func layoutSubviews() {
        super.layoutSubviews()
        
        if lastSize != bounds.size {
            lastSize = bounds.size
            resize()
        }
    }

    override public var contentMode: UIViewContentMode {
        didSet {
            metalView.contentMode = contentMode
            switch contentMode {
            case .scaleToFill:
                displayView.displayLayer.videoGravity = .resize
            case .scaleAspectFit, .center:
                displayView.displayLayer.videoGravity = .resizeAspect
            case .scaleAspectFill:
                displayView.displayLayer.videoGravity = .resizeAspectFill
            default:
                break
            }
        }
    }


    public func flush() {
        pixelBuffer = nil
        if displayView.isHidden {
            metalView.clear()
        } else {
            displayView.displayLayer.flushAndRemoveImage()
        }
    }

    public func invalidate() {
        displayLink.invalidate()
        idleLink.invalidate()
    }

    public func readNextFrame() {
        draw(force: true)
    }

    public func resize() {
        guard let frame = renderSource?.getVideoOutputRender(force: true) else {
            return
        }
        pixelBuffer = frame.corePixelBuffer
        guard let pixelBuffer else {
            return
        }
        let par = pixelBuffer.size
        let sar = pixelBuffer.aspectRatio
        let frameWidth = bounds.size.width
        let frameHeight = bounds.size.height
        let frameRatio = frameWidth / frameHeight
        var displayWidth = par.width * (sar.width / sar.height)
        var displayHeight = par.height
        let displayRatio = displayWidth / displayHeight
        if options.isRoundRectangle {
            metalView.layer.cornerRadius = options.cornerRadius
            metalView.layer.masksToBounds = true
            displayView.layer.cornerRadius = options.cornerRadius
            displayView.layer.masksToBounds = true
        }
        if frameRatio > displayRatio {
            displayHeight = frameHeight
            displayWidth = frameHeight * displayRatio
        } else {
            displayWidth = frameWidth
            displayHeight = frameWidth / displayRatio
        }
        
        NSLayoutConstraint.deactivate([
            metalViewWidthConstraint,
            metalViewHeightConstraint,
            displayViewWidthConstraint,
            displayViewHeightConstraint
        ])
        
        metalViewWidthConstraint = metalView.widthAnchor.constraint(equalToConstant: displayWidth)
        metalViewHeightConstraint = metalView.heightAnchor.constraint(equalToConstant: displayHeight)
        displayViewWidthConstraint = displayView.widthAnchor.constraint(equalToConstant: displayWidth)
        displayViewHeightConstraint = displayView.heightAnchor.constraint(equalToConstant: displayHeight)

        NSLayoutConstraint.activate([
            metalViewWidthConstraint,
            metalViewHeightConstraint,
            
            displayViewWidthConstraint,
            displayViewHeightConstraint
        ])
    }
//    deinit {
//        print()
//    }
}

extension MetalPlayView {
    @objc private func renderFrame() {
        draw(force: false)
    }
    
    @objc private func renderIdle() {
        idle()
    }

    private func draw(force: Bool) {
        autoreleasepool {
            guard let frame = renderSource?.getVideoOutputRender(force: force) else {
                idle()
                return
            }
//            let output = renderSource?.getVideoOutputRender(force: force)
//            if output == nil {
//                if pixelBuffer != nil {
//                    if !options.isUseDisplayLayer() {
//                        metalView.draw(pixelBuffer: pixelBuffer!, display: options.display, size: lastSize)
//                    }
//                }
//                return
//            }
//            let frame = output!
            pixelBuffer = frame.corePixelBuffer
            guard let pixelBuffer else {
                return
            }
            isDovi = frame.isDovi
            fps = frame.fps
            let cmtime = frame.cmtime
            let par = pixelBuffer.size
            let sar = pixelBuffer.aspectRatio
            if let pixelBuffer = pixelBuffer.cvPixelBuffer, options.isUseDisplayLayer() {
                if displayView.isHidden {
                    displayView.isHidden = false
                    metalView.isHidden = true
                    metalView.clear()
                }
                if let dar = options.customizeDar(sar: sar, par: par) {
                    pixelBuffer.aspectRatio = CGSize(width: dar.width, height: dar.height * par.width / par.height)
                }
                checkFormatDescription(pixelBuffer: pixelBuffer)
                set(pixelBuffer: pixelBuffer, time: cmtime)
            } else {
                if !displayView.isHidden {
                    displayView.isHidden = true
                    metalView.isHidden = false
                    displayView.displayLayer.flushAndRemoveImage()
                }
                let size: CGSize
                if options.display == .plane || options.display == .immersive {
                    if let dar = options.customizeDar(sar: sar, par: par) {
                        size = CGSize(width: par.width, height: par.width * dar.height / dar.width)
                    } else {
                        size = CGSize(width: par.width, height: par.height * sar.height / sar.width)
                    }
                } else {
                    size = MoonOptions.sceneSize
                }
                checkFormatDescription(pixelBuffer: pixelBuffer)
                metalView.draw(pixelBuffer: pixelBuffer, display: options.display, size: size)
            }
            renderSource?.setVideo(time: cmtime)
        }
    }
    
    private func idle() {
        autoreleasepool {
            guard let pixelBuffer else {
                return
            }

            let par = pixelBuffer.size
            let sar = pixelBuffer.aspectRatio
            if let pixelBuffer = pixelBuffer.cvPixelBuffer, !options.isUseDisplayLayer() {
                if !displayView.isHidden {
                    displayView.isHidden = true
                    metalView.isHidden = false
                    displayView.displayLayer.flushAndRemoveImage()
                }
                let size: CGSize
                if options.display == .plane || options.display == .immersive {
                    if let dar = options.customizeDar(sar: sar, par: par) {
                        size = CGSize(width: par.width, height: par.width * dar.height / dar.width)
                    } else {
                        size = CGSize(width: par.width, height: par.height * sar.height / sar.width)
                    }
                } else {
                    size = MoonOptions.sceneSize
                }
                checkFormatDescription(pixelBuffer: pixelBuffer)
                metalView.draw(pixelBuffer: pixelBuffer, display: options.display, size: size)
            }
        }
    }

    private func checkFormatDescription(pixelBuffer: PixelBufferProtocol) {
        guard let pixelBuffer = pixelBuffer.cvPixelBuffer else {
            return
        }
        if formatDescription == nil || !CMVideoFormatDescriptionMatchesImageBuffer(formatDescription!, imageBuffer: pixelBuffer) {
            if formatDescription != nil {
                displayView.removeFromSuperview()
                displayView = AVSampleBufferDisplayView()
                addSubview(displayView)
            }
            let err = CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: pixelBuffer, formatDescriptionOut: &formatDescription)
            if err != noErr {
                UILog("Error at CMVideoFormatDescriptionCreateForImageBuffer \(err)")
            }
        }
    }

    private func set(pixelBuffer: CVPixelBuffer, time: CMTime) {
        guard let formatDescription else { return }
        displayView.enqueue(imageBuffer: pixelBuffer, formatDescription: formatDescription, time: time)
    }
}

class MetalView: UIView {
    public var options: MoonOptions? {
        willSet {
            MetalRender.options = newValue
        }
    }
    
    private let render = MetalRender()

    #if canImport(UIKit)
    override public class var layerClass: AnyClass { CAMetalLayer.self }
    #endif
    var metalLayer: CAMetalLayer {
        // swiftlint:disable force_cast
        layer as! CAMetalLayer
        // swiftlint:enable force_cast
    }

    init() {
        super.init(frame: .zero)
        #if !canImport(UIKit)
        layer = CAMetalLayer()
        #endif
        metalLayer.device = MetalRender.device
        metalLayer.framebufferOnly = true
//        metalLayer.displaySyncEnabled = false
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func clear() {
        if let drawable = metalLayer.nextDrawable() {
            render.clear(drawable: drawable)
        }
    }

    func draw(pixelBuffer: PixelBufferProtocol, display: DisplayEnum, size: CGSize) {
        metalLayer.drawableSize = size
        
        let colorPixelFormat = MoonOptions.colorPixelFormat(bitDepth: pixelBuffer.bitDepth)
        metalLayer.pixelFormat = colorPixelFormat
        options?.pixelFormat = colorPixelFormat
        let colorspace = pixelBuffer.colorspace
        if metalLayer.colorspace != colorspace {
            metalLayer.colorspace = colorspace
            UILog("[video] CAMetalLayer colorspace \(String(describing: colorspace))")
            #if !os(tvOS)
            if #available(iOS 16.0, *) {
                if let name = colorspace?.name, name != CGColorSpace.sRGB {
                    #if os(macOS)
                    metalLayer.wantsExtendedDynamicRangeContent = window?.screen?.maximumPotentialExtendedDynamicRangeColorComponentValue ?? 1.0 > 1.0
                    #else
                    metalLayer.wantsExtendedDynamicRangeContent = true
                    #endif
                } else {
                    metalLayer.wantsExtendedDynamicRangeContent = false
                }
                UILog("[video] CAMetalLayer wantsExtendedDynamicRangeContent \(metalLayer.wantsExtendedDynamicRangeContent)")
            }
            #endif
        }
        guard let drawable = metalLayer.nextDrawable() else {
            UILog("[video] CAMetalLayer not readyForMoreMediaData")
            return
        }
        if options?.display == .plane && options?.stereo == .mono {
            render.drawPlane(pixelBuffer: pixelBuffer, display: display, drawable: drawable, size: size)
        } else {
            render.drawImmersive(pixelBuffer: pixelBuffer, display: display, size: size)
        }
    }
}

class AVSampleBufferDisplayView: UIView {
    #if canImport(UIKit)
    override public class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }
    #endif
    var displayLayer: AVSampleBufferDisplayLayer {
        // swiftlint:disable force_cast
        layer as! AVSampleBufferDisplayLayer
        // swiftlint:enable force_cast
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        self.backgroundColor = .black
        #if !canImport(UIKit)
        layer = AVSampleBufferDisplayLayer()
        #endif
        var controlTimebase: CMTimebase?
        CMTimebaseCreateWithSourceClock(allocator: kCFAllocatorDefault, sourceClock: CMClockGetHostTimeClock(), timebaseOut: &controlTimebase)
        if let controlTimebase {
            displayLayer.controlTimebase = controlTimebase
            CMTimebaseSetTime(controlTimebase, time: .zero)
            CMTimebaseSetRate(controlTimebase, rate: 1.0)
        }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func enqueue(imageBuffer: CVPixelBuffer, formatDescription: CMVideoFormatDescription, time: CMTime) {
        let size = imageBuffer.size
        let width = size.width
        let height = size.height
        let timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        //        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: time, decodeTimeStamp: .invalid)
        var sampleBuffer: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: imageBuffer, formatDescription: formatDescription, sampleTiming: [timing], sampleBufferOut: &sampleBuffer)
        if let sampleBuffer {
            if let attachmentsArray = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true) as? [NSMutableDictionary], let dic = attachmentsArray.first {
                dic[kCMSampleAttachmentKey_DisplayImmediately] = true
            }
            if displayLayer.isReadyForMoreMediaData {
                displayLayer.enqueue(sampleBuffer)
            } else {
                UILog("[video] AVSampleBufferDisplayLayer not readyForMoreMediaData. video time \(time), controlTime \(displayLayer.timebase.time) ")
                displayLayer.enqueue(sampleBuffer)
            }
            if #available(macOS 11.0, iOS 14, tvOS 14, *) {
                if displayLayer.requiresFlushToResumeDecoding {
                    UILog("[video] AVSampleBufferDisplayLayer requiresFlushToResumeDecoding so flush")
                    displayLayer.flush()
                }
            }
            if displayLayer.status == .failed {
                UILog("[video] AVSampleBufferDisplayLayer status failed so flush")
                displayLayer.flush()
                //                    if let error = displayLayer.error as NSError?, error.code == -11847 {
                //                        displayLayer.stopRequestingMediaData()
                //                    }
            }
        }
    }
}
