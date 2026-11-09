#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(int32_t, DLScanMode) {
    DLScanModeProgressive = 0,
    DLScanModeProgressiveSegmented = 1,
    DLScanModeInterlacedTopFirst = 2,
    DLScanModeInterlacedBottomFirst = 3,
};

typedef struct {
    int32_t width;
    int32_t height;
    int64_t frameDuration;
    int64_t timeScale;
    DLScanMode scan;
} DLFormat;

typedef struct {
    int32_t rowBytes;
    int32_t width;
    int32_t height;
    bool hasSignal;
    /// v210 when true, 8-bit UYVY when false. Read from each frame, so a frame is never mislabelled.
    bool isTenBit;
    uint64_t hostTimeNanos;
    int64_t streamTime;
    int64_t streamTimeScale;
    bool hasTimecode;
    bool timecodeIsDropFrame;
    uint8_t timecodeHours;
    uint8_t timecodeMinutes;
    uint8_t timecodeSeconds;
    uint8_t timecodeFrames;
    int32_t audioSampleFrames;
} DLFrameInfo;

/// Called on the SDK's capture thread. Pointers are valid only during the call. Must never block.
typedef void (^DLFrameHandler)(const DLFrameInfo *info, const void *videoBytes, const void *_Nullable audioBytes);
/// Called on the SDK's capture thread after the input has been reconfigured for the new format.
typedef void (^DLFormatHandler)(DLFormat format);

@interface DLInput : NSObject
@property (nonatomic, readonly) NSString *identifier;
@property (nonatomic, readonly) NSString *displayName;
@property (nonatomic, readonly) NSString *modelName;
@property (nonatomic, readonly) int32_t maxAudioChannels;
@property (nonatomic, readonly) BOOL supportsFormatDetection;
/// v210 when YES (the default), 8-bit UYVY when NO. Takes effect at the next start.
@property (nonatomic) BOOL captureTenBit;

/// Captures in the pixel format `captureTenBit` selects. With format detection the input follows the signal;
/// otherwise it stays at 1080p59.94.
- (BOOL)startWithAudioChannels:(int32_t)audioChannels
                  frameHandler:(DLFrameHandler)frameHandler
                 formatHandler:(DLFormatHandler)formatHandler
                         error:(NSError **)error;
- (void)stop;
@end

@interface DLDiscovery : NSObject
/// The installed driver's version, or nil when Desktop Video is not installed.
@property (class, nonatomic, readonly, nullable) NSString *driverVersion;
@property (class, nonatomic, readonly) NSString *sdkVersion;

/// Handlers run on an SDK thread, once per capture-capable sub-device, including those already present.
/// `profileChanged` fires when a device's profile is activated, which can change the set of inputs.
- (BOOL)startWithArrived:(void (^)(DLInput *input))arrived
                 removed:(void (^)(DLInput *input))removed
          profileChanged:(void (^)(void))profileChanged;
- (void)stop;
@end

NS_ASSUME_NONNULL_END
