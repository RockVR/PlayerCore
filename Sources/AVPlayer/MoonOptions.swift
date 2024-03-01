import AVFoundation
import OSLog
#if canImport(UIKit)
import UIKit
#endif
import CompositorServices

open class MoonPlaybackSettings {
    public static let minScreenTilt: Double = -90.0
    public static let maxScreenTilt: Double = 90.0
    public static let minScreenHeight: Double = -4.0
    public static let maxScreenHeight: Double = 4.0
    public static let minScreenZoom: Double = -4.0
    public static let maxScreenZoom: Double = 4.0
    
    // Screen
    @Published public var screenTilt: Double = 0.0
    @Published public var screenHeight: Double = 0.0
    @Published public var screenZoom: Double = 0.0
    
    public init() {
        
    }
}

open class MoonOptions {
    public var layerRenderer: LayerRenderer?
    public var pixelFormat: MTLPixelFormat = .bgra8Unorm_srgb
    
    public var playbackSettings = MoonPlaybackSettings()
    
    public var isRoundRectangle = true
    public var cornerRadius: CGFloat = 40
    /// 最低缓存视频时间
    @Published
    public var preferredForwardBufferDuration = MoonOptions.preferredForwardBufferDuration
    /// 最大缓存视频时间
    public var maxBufferDuration = MoonOptions.maxBufferDuration
    /// 是否开启秒开
    public var isSecondOpen = MoonOptions.isSecondOpen
    /// 开启精确seek
    public var isAccurateSeek = MoonOptions.isAccurateSeek
    /// Applies to short videos only
    public var isLoopPlay = MoonOptions.isLoopPlay
    /// 是否自动播放，默认false
    public var isAutoPlay = MoonOptions.isAutoPlay
    /// seek完是否自动播放
    public var isSeekedAutoPlay = MoonOptions.isSeekedAutoPlay
    /*
     AVSEEK_FLAG_BACKWARD: 1
     AVSEEK_FLAG_BYTE: 2
     AVSEEK_FLAG_ANY: 4
     AVSEEK_FLAG_FRAME: 8
     */
    public var seekFlags = Int32(1)
    // ffmpeg only cache http
    public var cache = false
    //  record stream
    public var outputURL: URL?
    public var avOptions = [String: Any]()
    public var formatContextOptions = [String: Any]()
    public var decoderOptions = [String: Any]()
    public var probesize: Int64?
    public var maxAnalyzeDuration: Int64?
    public var lowres = UInt8(0)
    public var codecLowDelay = false
    public var startPlayTime: TimeInterval = 0
    public var startPlayRate: Float = 1.0
    public var registerRemoteControll: Bool = true // 默认支持来自系统控制中心的控制
    public var referer: String? {
        didSet {
            if let referer {
                formatContextOptions["referer"] = "Referer: \(referer)"
            } else {
                formatContextOptions["referer"] = nil
            }
        }
    }

    public var userAgent: String? {
        didSet {
            if let userAgent {
                formatContextOptions["user_agent"] = userAgent
            } else {
                formatContextOptions["user_agent"] = nil
            }
        }
    }

    // audio
    public var audioFilters = [String]()
    public var syncDecodeAudio = false
    // Locale(identifier: "en-US") Locale(identifier: "zh-CN")
    public var audioLocale: Locale?
    // sutile
    public var autoSelectEmbedSubtitle = true
    public var isSeekImageSubtitle = false
    // video
    public var display = DisplayEnum.plane
    public var stereo = StereoEnum.mono
    public var videoDelay = 0.0 // s
    public var autoDeInterlace = false
    public var autoRotate = true
    public var destinationDynamicRange: DynamicRange?
    public var videoAdaptable = true
    public var videoFilters = [String]()
    public var syncDecodeVideo = false
    public var hardwareDecode = MoonOptions.hardwareDecode
    public var asynchronousDecompression = MoonOptions.asynchronousDecompression
    public var videoDisable = false
    public var canStartPictureInPictureAutomaticallyFromInline = true
    public var automaticWindowResize = true
    @Published
    public var videoInterlacingType: VideoInterlacingType?
    private var videoClockDelayCount = 0

    public internal(set) var formatName = ""
    public internal(set) var prepareTime = 0.0
    public internal(set) var dnsStartTime = 0.0
    public internal(set) var tcpStartTime = 0.0
    public internal(set) var tcpConnectedTime = 0.0
    public internal(set) var openTime = 0.0
    public internal(set) var findTime = 0.0
    public internal(set) var readyTime = 0.0
    public internal(set) var readAudioTime = 0.0
    public internal(set) var readVideoTime = 0.0
    public internal(set) var decodeAudioTime = 0.0
    public internal(set) var decodeVideoTime = 0.0
    public init() {
        // 参数的配置可以参考protocols.texi 和 http.c
        formatContextOptions["scan_all_pmts"] = 1
        formatContextOptions["auto_convert"] = 0
        formatContextOptions["fps_probe_size"] = 3
        // 默认情况下允许所有协议，只有嵌套协议才需要指定这个协议子集，例如m3u8里面有http。
//        formatContextOptions["protocol_whitelist"] = "file,http,https,tcp,tls,crypto,async,cache,data,httpproxy"
//        formatContextOptions["max_analyze_duration"] = 300 * 1000
        formatContextOptions["reconnect"] = 1
        // 开启这个，纯ipv6地址会无法播放。并且有些视频结束了，但还会一直尝试重连。所以这个值默认不设置
//        formatContextOptions["reconnect_at_eof"] = 1
        formatContextOptions["reconnect_streamed"] = 1
        formatContextOptions["multiple_requests"] = 1
        // 开启这个，会导致tcp Failed to resolve hostname 还会一直重试
//        formatContextOptions["reconnect_on_network_error"] = 1
        // There is total different meaning for 'listen_timeout' option in rtmp
        // set 'listen_timeout' = -1 for rtmp、rtsp
//        formatContextOptions["listen_timeout"] = 3
        formatContextOptions["rw_timeout"] = 10_000_000
        decoderOptions["threads"] = "auto"
        decoderOptions["refcounted_frames"] = "1"
    }

    /**
     you can add http-header or other options which mentions in https://developer.apple.com/reference/avfoundation/avurlasset/initialization_options

     to add http-header init options like this
     ```
     options.appendHeader(["Referer":"https:www.xxx.com"])
     ```
     */
    public func appendHeader(_ header: [String: String]) {
        var oldValue = avOptions["AVURLAssetHTTPHeaderFieldsKey"] as? [String: String] ?? [
            String: String
        ]()
        oldValue.merge(header) { _, new in new }
        avOptions["AVURLAssetHTTPHeaderFieldsKey"] = oldValue
        var str = formatContextOptions["headers"] as? String ?? ""
        for (key, value) in header {
            str.append("\(key):\(value)\r\n")
        }
        formatContextOptions["headers"] = str
    }

    public func setCookie(_ cookies: [HTTPCookie]) {
        avOptions[AVURLAssetHTTPCookiesKey] = cookies
        let cookieStr = cookies.map { cookie in "\(cookie.name)=\(cookie.value)" }.joined(separator: "; ")
        appendHeader(["Cookie": cookieStr])
    }

    // 缓冲算法函数
    open func playable(capacitys: [CapacityProtocol], isFirst: Bool, isSeek: Bool) -> LoadingState {
        let packetCount = capacitys.map(\.packetCount).min() ?? 0
        let frameCount = capacitys.map(\.frameCount).min() ?? 0
        let isEndOfFile = capacitys.allSatisfy(\.isEndOfFile)
        let loadedTime = capacitys.map(\.loadedTime).min() ?? 0
        let progress = loadedTime * 100.0 / preferredForwardBufferDuration
        let isPlayable = capacitys.allSatisfy { capacity in
            if capacity.isEndOfFile && capacity.packetCount == 0 {
                return true
            }
            guard capacity.frameCount >= 2 else {
                return false
            }
            if capacity.isEndOfFile {
                return true
            }
            if (syncDecodeVideo && capacity.mediaType == .video) || (syncDecodeAudio && capacity.mediaType == .audio) {
                return true
            }
            if isFirst || isSeek {
                // 让纯音频能更快的打开
                if capacity.mediaType == .audio || isSecondOpen {
                    if isFirst {
                        return true
                    } else {
                        return capacity.loadedTime >= preferredForwardBufferDuration / 2
                    }
                }
            }
            return capacity.loadedTime >= preferredForwardBufferDuration
        }
        return LoadingState(loadedTime: loadedTime, progress: progress, packetCount: packetCount,
                            frameCount: frameCount, isEndOfFile: isEndOfFile, isPlayable: isPlayable,
                            isFirst: isFirst, isSeek: isSeek)
    }

    open func adaptable(state: VideoAdaptationState?) -> (Int64, Int64)? {
        guard let state, let last = state.bitRateStates.last, CACurrentMediaTime() - last.time > maxBufferDuration / 2, let index = state.bitRates.firstIndex(of: last.bitRate) else {
            return nil
        }
        let isUp = state.loadedCount > Int(Double(state.fps) * maxBufferDuration / 2)
        if isUp != state.isPlayable {
            return nil
        }
        if isUp {
            if index < state.bitRates.endIndex - 1 {
                return (last.bitRate, state.bitRates[index + 1])
            }
        } else {
            if index > state.bitRates.startIndex {
                return (last.bitRate, state.bitRates[index - 1])
            }
        }
        return nil
    }

    ///  wanted video stream index, or nil for automatic selection
    /// - Parameter : video track
    /// - Returns: The index of the track
    open func wantedVideo(tracks _: [MediaPlayerTrack]) -> Int? {
        nil
    }

    /// wanted audio stream index, or nil for automatic selection
    /// - Parameter :  audio track
    /// - Returns: The index of the track
    open func wantedAudio(tracks _: [MediaPlayerTrack]) -> Int? {
        nil
    }

    open func videoFrameMaxCount(fps _: Float, naturalSize _: CGSize, isLive: Bool) -> UInt8 {
        isLive ? 4 : 16
    }

    open func audioFrameMaxCount(fps: Float, channelCount: Int) -> UInt8 {
        let count = (Int(fps) * channelCount) >> 2
        if count >= UInt8.max {
            return UInt8.max
        } else {
            return UInt8(count)
        }
    }

    /// customize dar
    /// - Parameters:
    ///   - sar: SAR(Sample Aspect Ratio)
    ///   - dar: PAR(Pixel Aspect Ratio)
    /// - Returns: DAR(Display Aspect Ratio)
    open func customizeDar(sar _: CGSize, par _: CGSize) -> CGSize? {
        nil
    }

    // 虽然只有iOS才支持PIP。但是因为AVSampleBufferDisplayLayer能够支持HDR10+。所以默认还是推荐用AVSampleBufferDisplayLayer
    open func isUseDisplayLayer() -> Bool {
        display == .plane && stereo == .mono
    }

    open func urlIO(log: String) {
        if log.starts(with: "Original list of addresses"), dnsStartTime == 0 {
            dnsStartTime = CACurrentMediaTime()
        } else if log.starts(with: "Starting connection attempt to"), tcpStartTime == 0 {
            tcpStartTime = CACurrentMediaTime()
        } else if log.starts(with: "Successfully connected to"), tcpConnectedTime == 0 {
            tcpConnectedTime = CACurrentMediaTime()
        }
    }

    private var idetTypeMap = [VideoInterlacingType: Int]()
    open func filter(log: String) {
        if log.starts(with: "Repeated Field:") {
            log.split(separator: ",").forEach { str in
                let map = str.split(separator: ":")
                if map.count >= 2 {
                    if String(map[0].trimmingCharacters(in: .whitespaces)) == "Multi frame" {
                        if let type = VideoInterlacingType(rawValue: map[1].trimmingCharacters(in: .whitespacesAndNewlines)) {
                            idetTypeMap[type] = (idetTypeMap[type] ?? 0) + 1
                            let tff = idetTypeMap[.tff] ?? 0
                            let bff = idetTypeMap[.bff] ?? 0
                            let progressive = idetTypeMap[.progressive] ?? 0
                            let undetermined = idetTypeMap[.undetermined] ?? 0
                            if progressive - tff - bff > 100 {
                                videoInterlacingType = .progressive
                                autoDeInterlace = false
                            } else if bff - progressive > 100 {
                                videoInterlacingType = .bff
                                autoDeInterlace = false
                            } else if tff - progressive > 100 {
                                videoInterlacingType = .tff
                                autoDeInterlace = false
                            } else if undetermined - progressive - tff - bff > 100 {
                                videoInterlacingType = .undetermined
                                autoDeInterlace = false
                            }
                        }
                    }
                }
            }
        }
    }

    open func sei(string: String) {
        UILog("sei \(string)")
    }

    /**
            在创建解码器之前可以对KSOptions和assetTrack做一些处理。例如判断fieldOrder为tt或bb的话，那就自动加videofilters
     */
    open func process(assetTrack: some MediaPlayerTrack) {
        if assetTrack.mediaType == .video {
            if [FFmpegFieldOrder.bb, .bt, .tt, .tb].contains(assetTrack.fieldOrder) {
                // todo 先不要用yadif_videotoolbox，不然会crash。这个后续在看下要怎么解决
                hardwareDecode = false
                asynchronousDecompression = false
                let yadif = hardwareDecode ? "yadif_videotoolbox" : "yadif"
                videoFilters.append("\(yadif)=mode=\(MoonOptions.yadifMode):parity=-1:deint=1")
            }
        }
    }

    open func updateVideo(refreshRate: Float, isDovi _: Bool, formatDescription: CMFormatDescription?) {
        #if os(tvOS) || os(xrOS)
        guard let displayManager = UIApplication.shared.windows.first?.avDisplayManager,
              displayManager.isDisplayCriteriaMatchingEnabled
        else {
            return
        }
//        快速更改preferredDisplayCriteria，会导致isDisplayModeSwitchInProgress变成true，例如退出一个视频，然后在3s内重新进入的话，
        if let formatDescription {
            if MoonOptions.displayCriteriaFormatDescriptionEnabled, #available(tvOS 17.0, *) {
                displayManager.preferredDisplayCriteria = AVDisplayCriteria(refreshRate: refreshRate, formatDescription: formatDescription)
            } else {
//                let dynamicRange = isDovi ? .dolbyVision : formatDescription.dynamicRange
//                displayManager.preferredDisplayCriteria = AVDisplayCriteria(refreshRate: refreshRate, videoDynamicRange: dynamicRange.rawValue)
            }
        }
        #endif
    }

//    private var lastMediaTime = CACurrentMediaTime()
    open func videoClockSync(main: KSClock, nextVideoTime: TimeInterval, fps: Float, frameCount: Int) -> (Double, ClockProcessType) {
        var desire = main.getTime() - videoDelay
        #if !os(macOS)
        desire -= AVAudioSession.sharedInstance().outputLatency
        #endif
        let diff = nextVideoTime - desire
//        print("[video] video diff \(diff) audio \(main.positionTime) interval \(CACurrentMediaTime() - main.lastMediaTime) render interval \(CACurrentMediaTime() - lastMediaTime)")
        // 最大刷新率上限
        if diff >= 1 / 120 {
            videoClockDelayCount = 0
            return (diff, .remain)
        } else {
            if diff < -4 / Double(fps) {
                videoClockDelayCount += 1
                let log = "[video] video delay=\(diff), clock=\(desire), delay count=\(videoClockDelayCount), frameCount=\(frameCount)"
                if frameCount == 1 {
                    if diff < -1, videoClockDelayCount % 10 == 0 {
                        UILog("\(log) drop gop Packet")
                        return (diff, .dropGOPPacket)
                    } else if videoClockDelayCount % 5 == 0 {
                        UILog("\(log) drop next frame")
                        return (diff, .dropNextFrame)
                    } else {
                        return (diff, .next)
                    }
                } else {
                    if diff < -8, videoClockDelayCount % 100 == 0 {
                        UILog("\(log) seek video track")
                        return (diff, .seek)
                    }
                    if diff < -1, videoClockDelayCount % 10 == 0 {
                        UILog("\(log) flush video track")
                        return (diff, .flush)
                    }
                    if videoClockDelayCount % 2 == 0 {
                        UILog("\(log) drop next frame")
                        return (diff, .dropNextFrame)
                    } else {
                        return (diff, .next)
                    }
                }
            } else {
                videoClockDelayCount = 0
//                print("[video] video interval \(CACurrentMediaTime() - lastMediaTime)")
//                lastMediaTime = CACurrentMediaTime()
                return (diff, .next)
            }
        }
    }

    open func availableDynamicRange(_ cotentRange: DynamicRange?) -> DynamicRange? {
        #if canImport(UIKit)
        let availableHDRModes = AVPlayer.availableHDRModes
        if let preferedDynamicRange = destinationDynamicRange {
            // value of 0 indicates that no HDR modes are supported.
            if availableHDRModes == AVPlayer.HDRMode(rawValue: 0) {
                return .sdr
            } else if availableHDRModes.contains(preferedDynamicRange.hdrMode) {
                return preferedDynamicRange
            } else if let cotentRange,
                      availableHDRModes.contains(cotentRange.hdrMode)
            {
                return cotentRange
            } else if preferedDynamicRange != .sdr { // trying update to HDR mode
                return availableHDRModes.dynamicRange
            }
        }
        #endif
        return cotentRange
    }

    open func playerLayerDeinit() {
        #if os(tvOS) || os(xrOS)
        UIApplication.shared.windows.first?.avDisplayManager.preferredDisplayCriteria = nil
        #endif
    }

    open func liveAdaptivePlaybackRate(loadingState _: LoadingState) -> Float? {
        nil
//        if loadingState.isFirst {
//            return nil
//        }
//        if loadingState.loadedTime > preferredForwardBufferDuration + 5 {
//            return 1.2
//        } else if loadingState.loadedTime < preferredForwardBufferDuration / 2 {
//            return 0.8
//        } else {
//            return 1
//        }
    }
}

public enum VideoInterlacingType: String {
    case tff
    case bff
    case progressive
    case undetermined
}

public extension MoonOptions {
    static var firstPlayerType: MediaPlayerProtocol.Type = MoonAVPlayer.self
    static var secondPlayerType: MediaPlayerProtocol.Type?
    /// 最低缓存视频时间
    static var preferredForwardBufferDuration = 3.0
    /// 最大缓存视频时间
    static var maxBufferDuration = 30.0
    /// 是否开启秒开
    static var isSecondOpen = false
    /// 开启精确seek
    static var isAccurateSeek = false
    /// Applies to short videos only
    static var isLoopPlay = false
    /// 是否自动播放，默认false
    static var isAutoPlay = false
    /// seek完是否自动播放
    static var isSeekedAutoPlay = true
    static var hardwareDecode = true
    static var asynchronousDecompression = true
    static var isPipPopViewController = false
    static var displayCriteriaFormatDescriptionEnabled = false
    /// 日志级别
    static var logLevel = LogLevel.warning
    static var logger: LogHandler = OSLog(lable: "MOON")
    internal static func deviceCpuCount() -> Int {
        var ncpu = UInt(0)
        var len: size_t = MemoryLayout.size(ofValue: ncpu)
        sysctlbyname("hw.ncpu", &ncpu, &len, nil, 0)
        return Int(ncpu)
    }

    static func setAudioSession() {
        #if os(macOS)
//        try? AVAudioSession.sharedInstance().setRouteSharingPolicy(.longFormAudio)
        #else
        let category = AVAudioSession.sharedInstance().category
        if category == .playback || category == .playAndRecord {
            try? AVAudioSession.sharedInstance().setCategory(category, mode: .moviePlayback, policy: .longFormAudio)
        } else {
            try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback, policy: .longFormAudio)
        }
        try? AVAudioSession.sharedInstance().setActive(true)
        #endif
    }

    #if !os(macOS)
    static func isSpatialAudioEnabled(channelCount _: AVAudioChannelCount) -> Bool {
        if #available(tvOS 15.0, iOS 15.0, *) {
            let isSpatialAudioEnabled = AVAudioSession.sharedInstance().currentRoute.outputs.contains { $0.isSpatialAudioEnabled }
            try? AVAudioSession.sharedInstance().setSupportsMultichannelContent(isSpatialAudioEnabled)
            return isSpatialAudioEnabled
        } else {
            return false
        }
    }

    static func outputNumberOfChannels(channelCount: AVAudioChannelCount) -> AVAudioChannelCount {
        let maximumOutputNumberOfChannels = AVAudioChannelCount(AVAudioSession.sharedInstance().maximumOutputNumberOfChannels)
        let preferredOutputNumberOfChannels = AVAudioChannelCount(AVAudioSession.sharedInstance().preferredOutputNumberOfChannels)
        let isSpatialAudioEnabled = isSpatialAudioEnabled(channelCount: channelCount)
        let isUseAudioRenderer = MoonOptions.audioPlayerType == AudioRendererPlayer.self
        UILog("[audio] maximumOutputNumberOfChannels: \(maximumOutputNumberOfChannels), preferredOutputNumberOfChannels: \(preferredOutputNumberOfChannels), isSpatialAudioEnabled: \(isSpatialAudioEnabled), isUseAudioRenderer: \(isUseAudioRenderer) ")
        let maxRouteChannelsCount = AVAudioSession.sharedInstance().currentRoute.outputs.compactMap {
            $0.channels?.count
        }.max() ?? 2
        UILog("[audio] currentRoute max channels: \(maxRouteChannelsCount)")
        var channelCount = channelCount
        if channelCount > 2 {
            let minChannels = min(maximumOutputNumberOfChannels, channelCount)
            // iOS 有空间音频功能，所以不用处理
            #if os(tvOS) || targetEnvironment(simulator)
            if !(isUseAudioRenderer && isSpatialAudioEnabled) {
                // 不要用maxRouteChannelsCount来判断，有可能会不准。导致多音道设备也返回2（一开始播放一个2声道，就容易出现），也不能用outputNumberOfChannels来判断，有可能会返回2
//                channelCount = AVAudioChannelCount(min(AVAudioSession.sharedInstance().outputNumberOfChannels, maxRouteChannelsCount))
                channelCount = minChannels
            }
            #endif
        } else {
            channelCount = 2
        }
        UILog("[audio] outputNumberOfChannels: \(AVAudioSession.sharedInstance().outputNumberOfChannels) output channelCount: \(channelCount)")
        return channelCount
    }
    #endif
}

public enum LogLevel: Int32, CustomStringConvertible {
    case panic = 0
    case fatal = 8
    case error = 16
    case warning = 24
    case info = 32
    case verbose = 40
    case debug = 48
    case trace = 56

    public var description: String {
        switch self {
        case .panic:
            return "panic"
        case .fatal:
            return "fault"
        case .error:
            return "error"
        case .warning:
            return "warning"
        case .info:
            return "info"
        case .verbose:
            return "verbose"
        case .debug:
            return "debug"
        case .trace:
            return "trace"
        }
    }
}

public extension LogLevel {
    var logType: OSLogType {
        switch self {
        case .panic, .fatal:
            return .fault
        case .error:
            return .error
        case .warning:
            return .debug
        case .info, .verbose, .debug:
            return .info
        case .trace:
            return .default
        }
    }
}

public protocol LogHandler {
    @inlinable
    func log(level: LogLevel, message: CustomStringConvertible, file: String, function: String, line: UInt)
}

public class OSLog: LogHandler {
    public let label: String
    public init(lable: String) {
        label = lable
    }

    @inlinable
    public func log(level: LogLevel, message: CustomStringConvertible, file: String, function: String, line: UInt) {
        os_log(level.logType, "%@ %@: %@:%d %@ | %@", level.description, label, file, line, function, message.description)
    }
}

public class FileLog: LogHandler {
    public let fileHandle: FileHandle
    public let formatter = DateFormatter()
    public init(fileHandle: FileHandle) {
        self.fileHandle = fileHandle
        formatter.dateFormat = "MM-dd HH:mm:ss.SSSSSS"
    }

    @inlinable
    public func log(level: LogLevel, message: CustomStringConvertible, file: String, function: String, line: UInt) {
        let string = String(format: "%@ %@ %@:%d %@ | %@\n", formatter.string(from: Date()), level.description, file, line, function, message.description)
        if let data = string.data(using: .utf8) {
            fileHandle.write(data)
        }
    }
}

@inlinable
public func UILog(_ error: @autoclosure () -> Error, file: String = #file, function: String = #function, line: UInt = #line) {
    UILog(level: .error, error().localizedDescription, file: file, function: function, line: line)
}

@inlinable
public func UILog(level: LogLevel = .warning, _ message: @autoclosure () -> CustomStringConvertible, file: String = #file, function: String = #function, line: UInt = #line) {
    if level.rawValue <= MoonOptions.logLevel.rawValue {
        let fileName = (file as NSString).lastPathComponent
        MoonOptions.logger.log(level: level, message: message(), file: fileName, function: function, line: line)
    }
}

@inlinable
public func UILog(level: LogLevel = .warning, dso: UnsafeRawPointer = #dsohandle, _ message: StaticString, _ args: CVarArg...) {
    if level.rawValue <= MoonOptions.logLevel.rawValue {
        os_log(level.logType, dso: dso, message, args)
    }
}

public extension Array {
    func toDictionary<Key: Hashable>(with selectKey: (Element) -> Key) -> [Key: Element] {
        var dict = [Key: Element]()
        forEach { element in
            dict[selectKey(element)] = element
        }
        return dict
    }
}

public struct KSClock {
    public private(set) var lastMediaTime = CACurrentMediaTime()
    public internal(set) var positionTime = CMTime.zero {
        didSet {
            lastMediaTime = CACurrentMediaTime()
        }
    }

    func getTime() -> TimeInterval {
        positionTime.seconds + CACurrentMediaTime() - lastMediaTime
    }
}
