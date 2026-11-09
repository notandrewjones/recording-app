#import "DeckLinkBridge.h"
#include "DeckLinkAPI.h"
#include "DeckLinkAPIVersion.h"
#include <atomic>
#include <map>
#include <mutex>
#include <time.h>

static NSError *DLError(NSString *message, HRESULT result) {
    return [NSError errorWithDomain:@"DeckLinkBridge" code:result userInfo:@{NSLocalizedDescriptionKey: message}];
}

static DLFormat DLFormatFromMode(IDeckLinkDisplayMode *mode) {
    DLFormat format{};
    format.width = (int32_t)mode->GetWidth();
    format.height = (int32_t)mode->GetHeight();
    BMDTimeValue duration = 0;
    BMDTimeScale scale = 0;
    mode->GetFrameRate(&duration, &scale);
    format.frameDuration = duration;
    format.timeScale = scale;
    switch (mode->GetFieldDominance()) {
        case bmdUpperFieldFirst: format.scan = DLScanModeInterlacedTopFirst; break;
        case bmdLowerFieldFirst: format.scan = DLScanModeInterlacedBottomFirst; break;
        case bmdProgressiveSegmentedFrame: format.scan = DLScanModeProgressiveSegmented; break;
        default: format.scan = DLScanModeProgressive; break;
    }
    return format;
}

class DLInputCallback final : public IDeckLinkInputCallback {
public:
    DLInputCallback(IDeckLinkInput *input, BMDPixelFormat pixelFormat, DLFrameHandler frameHandler, DLFormatHandler formatHandler)
        : input_(input), pixelFormat_(pixelFormat), frameHandler_(frameHandler), formatHandler_(formatHandler) {}

    HRESULT QueryInterface(REFIID, LPVOID *ppv) override {
        *ppv = nullptr;
        return E_NOINTERFACE;
    }
    ULONG AddRef() override { return ++refCount_; }
    ULONG Release() override {
        ULONG count = --refCount_;
        if (count == 0) delete this;
        return count;
    }

    HRESULT VideoInputFormatChanged(BMDVideoInputFormatChangedEvents, IDeckLinkDisplayMode *mode, BMDDetectedVideoInputFormatFlags) override {
        input_->PauseStreams();
        input_->EnableVideoInput(mode->GetDisplayMode(), pixelFormat_, bmdVideoInputEnableFormatDetection);
        input_->FlushStreams();
        input_->StartStreams();
        formatHandler_(DLFormatFromMode(mode));
        return S_OK;
    }

    HRESULT VideoInputFrameArrived(IDeckLinkVideoInputFrame *frame, IDeckLinkAudioInputPacket *audio) override {
        if (frame == nullptr) return S_OK;
        const uint64_t hostTime = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);

        IDeckLinkVideoBuffer *buffer = nullptr;
        if (frame->QueryInterface(IID_IDeckLinkVideoBuffer, (void **)&buffer) != S_OK) return S_OK;

        void *videoBytes = nullptr;
        if (buffer->StartAccess(bmdBufferAccessRead) == S_OK) {
            if (buffer->GetBytes(&videoBytes) == S_OK && videoBytes != nullptr) {
                DLFrameInfo info{};
                info.rowBytes = (int32_t)frame->GetRowBytes();
                info.width = (int32_t)frame->GetWidth();
                info.height = (int32_t)frame->GetHeight();
                info.hasSignal = (frame->GetFlags() & bmdFrameHasNoInputSource) == 0;
                info.isTenBit = frame->GetPixelFormat() == bmdFormat10BitYUV;
                info.hostTimeNanos = hostTime;
                info.streamTimeScale = 240000;
                BMDTimeValue duration = 0;
                BMDTimeValue streamTime = 0;
                frame->GetStreamTime(&streamTime, &duration, info.streamTimeScale);
                info.streamTime = streamTime;
                readTimecode(frame, &info);

                void *audioBytes = nullptr;
                if (audio != nullptr && audio->GetBytes(&audioBytes) == S_OK) {
                    info.audioSampleFrames = (int32_t)audio->GetSampleFrameCount();
                }
                frameHandler_(&info, videoBytes, audioBytes);
            }
            buffer->EndAccess(bmdBufferAccessRead);
        }
        buffer->Release();
        return S_OK;
    }

private:
    static void readTimecode(IDeckLinkVideoInputFrame *frame, DLFrameInfo *info) {
        IDeckLinkTimecode *timecode = nullptr;
        if (frame->GetTimecode(bmdTimecodeRP188Any, &timecode) != S_OK || timecode == nullptr) {
            if (frame->GetTimecode(bmdTimecodeVITC, &timecode) != S_OK || timecode == nullptr) return;
        }
        info->hasTimecode = timecode->GetComponents(&info->timecodeHours, &info->timecodeMinutes, &info->timecodeSeconds, &info->timecodeFrames) == S_OK;
        info->timecodeIsDropFrame = (timecode->GetFlags() & bmdTimecodeIsDropFrame) != 0;
        timecode->Release();
    }

    std::atomic<ULONG> refCount_{1};
    IDeckLinkInput *input_;
    const BMDPixelFormat pixelFormat_;
    DLFrameHandler frameHandler_;
    DLFormatHandler formatHandler_;
};

@implementation DLInput {
    IDeckLink *_deckLink;
    IDeckLinkInput *_input;
    DLInputCallback *_callback;
}

- (nullable instancetype)initWithDeckLink:(IDeckLink *)deckLink {
    self = [super init];
    if (!self) return nil;

    IDeckLinkProfileAttributes *attributes = nullptr;
    if (deckLink->QueryInterface(IID_IDeckLinkProfileAttributes, (void **)&attributes) != S_OK) return nil;

    int64_t ioSupport = 0;
    int64_t duplex = bmdDuplexFull;
    attributes->GetInt(BMDDeckLinkVideoIOSupport, &ioSupport);
    attributes->GetInt(BMDDeckLinkDuplex, &duplex);
    if ((ioSupport & bmdDeviceSupportsCapture) == 0 || duplex == bmdDuplexInactive) {
        attributes->Release();
        return nil;
    }
    if (deckLink->QueryInterface(IID_IDeckLinkInput, (void **)&_input) != S_OK) {
        attributes->Release();
        return nil;
    }

    _deckLink = deckLink;
    _deckLink->AddRef();

    CFStringRef displayName = nullptr;
    CFStringRef modelName = nullptr;
    deckLink->GetDisplayName(&displayName);
    deckLink->GetModelName(&modelName);
    _displayName = displayName ? (NSString *)CFBridgingRelease(displayName) : @"DeckLink";
    _modelName = modelName ? (NSString *)CFBridgingRelease(modelName) : @"DeckLink";

    int64_t maxChannels = 2;
    attributes->GetInt(BMDDeckLinkMaximumAudioChannels, &maxChannels);
    _maxAudioChannels = (int32_t)maxChannels;

    bool detection = false;
    attributes->GetFlag(BMDDeckLinkSupportsInputFormatDetection, &detection);
    _supportsFormatDetection = detection;
    _captureTenBit = YES;

    // Sub-devices of one card can share a persistent ID, so the sub-device index is part of identity.
    int64_t persistentID = 0;
    int64_t topologicalID = 0;
    int64_t subDevice = 0;
    BOOL hasPersistent = attributes->GetInt(BMDDeckLinkPersistentID, &persistentID) == S_OK;
    attributes->GetInt(BMDDeckLinkTopologicalID, &topologicalID);
    attributes->GetInt(BMDDeckLinkSubDeviceIndex, &subDevice);
    _identifier = [NSString stringWithFormat:@"decklink-%llx-%lld", hasPersistent ? persistentID : topologicalID, subDevice];

    attributes->Release();
    return self;
}

- (void)dealloc {
    [self stop];
    if (_input) _input->Release();
    if (_deckLink) _deckLink->Release();
}

- (IDeckLink *)deckLink {
    return _deckLink;
}

- (BOOL)startWithAudioChannels:(int32_t)audioChannels
                  frameHandler:(DLFrameHandler)frameHandler
                 formatHandler:(DLFormatHandler)formatHandler
                         error:(NSError **)error {
    [self stop];

    const BMDDisplayMode initialMode = bmdModeHD1080p5994;
    BMDVideoInputFlags flags = _supportsFormatDetection ? bmdVideoInputEnableFormatDetection : bmdVideoInputFlagDefault;
    const BMDPixelFormat pixelFormat = _captureTenBit ? bmdFormat10BitYUV : bmdFormat8BitYUV;

    HRESULT result = _input->EnableVideoInput(initialMode, pixelFormat, flags);
    if (result != S_OK) {
        if (error) *error = DLError(@"Could not enable video input. It may be in use by another application.", result);
        return NO;
    }
    if (audioChannels > 0) {
        result = _input->EnableAudioInput(bmdAudioSampleRate48kHz, bmdAudioSampleType32bitInteger, audioChannels);
        if (result != S_OK) {
            _input->DisableVideoInput();
            if (error) *error = DLError(@"Could not enable audio input.", result);
            return NO;
        }
    }

    _callback = new DLInputCallback(_input, pixelFormat, frameHandler, formatHandler);
    _input->SetCallback(_callback);
    result = _input->StartStreams();
    if (result != S_OK) {
        [self stop];
        if (error) *error = DLError(@"Could not start capture streams.", result);
        return NO;
    }

    IDeckLinkDisplayMode *mode = nullptr;
    if (_input->GetDisplayMode(initialMode, &mode) == S_OK && mode != nullptr) {
        formatHandler(DLFormatFromMode(mode));
        mode->Release();
    }
    return YES;
}

- (void)stop {
    if (_callback == nullptr) return;
    _input->StopStreams();
    _input->SetCallback(nullptr);
    _input->DisableVideoInput();
    _input->DisableAudioInput();
    _callback->Release();
    _callback = nullptr;
}

@end

class DLProfileCallback final : public IDeckLinkProfileCallback {
public:
    explicit DLProfileCallback(void (^activated)(void)) : activated_(activated) {}

    HRESULT QueryInterface(REFIID, LPVOID *ppv) override {
        *ppv = nullptr;
        return E_NOINTERFACE;
    }
    ULONG AddRef() override { return ++refCount_; }
    ULONG Release() override {
        ULONG count = --refCount_;
        if (count == 0) delete this;
        return count;
    }

    HRESULT ProfileChanging(IDeckLinkProfile *, bool) override { return S_OK; }
    HRESULT ProfileActivated(IDeckLinkProfile *) override {
        activated_();
        return S_OK;
    }

private:
    std::atomic<ULONG> refCount_{1};
    void (^activated_)(void);
};

class DLDiscoveryCallback final : public IDeckLinkDeviceNotificationCallback {
public:
    DLDiscoveryCallback(void (^arrived)(DLInput *), void (^removed)(DLInput *), void (^profileChanged)(void))
        : arrived_(arrived), removed_(removed), profileCallback_(new DLProfileCallback(profileChanged)) {}

    ~DLDiscoveryCallback() {
        std::lock_guard<std::mutex> lock(mutex_);
        for (auto &entry : managers_) {
            entry.second->SetCallback(nullptr);
            entry.second->Release();
        }
        profileCallback_->Release();
    }

    HRESULT QueryInterface(REFIID, LPVOID *ppv) override {
        *ppv = nullptr;
        return E_NOINTERFACE;
    }
    ULONG AddRef() override { return ++refCount_; }
    ULONG Release() override {
        ULONG count = --refCount_;
        if (count == 0) delete this;
        return count;
    }

    HRESULT DeckLinkDeviceArrived(IDeckLink *deckLink) override {
        watchProfiles(deckLink);
        DLInput *input = [[DLInput alloc] initWithDeckLink:deckLink];
        if (input == nil) return S_OK;
        {
            std::lock_guard<std::mutex> lock(mutex_);
            inputs_[deckLink] = input;
        }
        arrived_(input);
        return S_OK;
    }

    HRESULT DeckLinkDeviceRemoved(IDeckLink *deckLink) override {
        DLInput *input = nil;
        {
            std::lock_guard<std::mutex> lock(mutex_);
            auto manager = managers_.find(deckLink);
            if (manager != managers_.end()) {
                manager->second->SetCallback(nullptr);
                manager->second->Release();
                managers_.erase(manager);
            }
            auto found = inputs_.find(deckLink);
            if (found == inputs_.end()) return S_OK;
            input = found->second;
            inputs_.erase(found);
        }
        removed_(input);
        return S_OK;
    }

private:
    /// Watches every device, including ones with no active input, since a profile change can add inputs.
    void watchProfiles(IDeckLink *deckLink) {
        IDeckLinkProfileManager *manager = nullptr;
        if (deckLink->QueryInterface(IID_IDeckLinkProfileManager, (void **)&manager) != S_OK) return;
        manager->SetCallback(profileCallback_);
        std::lock_guard<std::mutex> lock(mutex_);
        managers_[deckLink] = manager;
    }

    std::atomic<ULONG> refCount_{1};
    std::mutex mutex_;
    std::map<IDeckLink *, DLInput *> inputs_;
    std::map<IDeckLink *, IDeckLinkProfileManager *> managers_;
    void (^arrived_)(DLInput *);
    void (^removed_)(DLInput *);
    DLProfileCallback *profileCallback_;
};

@implementation DLDiscovery {
    IDeckLinkDiscovery *_discovery;
    DLDiscoveryCallback *_callback;
}

+ (nullable NSString *)driverVersion {
    IDeckLinkAPIInformation *information = CreateDeckLinkAPIInformationInstance();
    if (information == nullptr) return nil;
    CFStringRef version = nullptr;
    HRESULT result = information->GetString(BMDDeckLinkAPIVersion, &version);
    information->Release();
    return result == S_OK && version ? (NSString *)CFBridgingRelease(version) : nil;
}

+ (NSString *)sdkVersion {
    return @BLACKMAGIC_DECKLINK_API_VERSION_STRING;
}

- (BOOL)startWithArrived:(void (^)(DLInput *))arrived
                 removed:(void (^)(DLInput *))removed
          profileChanged:(void (^)(void))profileChanged {
    [self stop];
    _discovery = CreateDeckLinkDiscoveryInstance();
    if (_discovery == nullptr) return NO;
    _callback = new DLDiscoveryCallback(arrived, removed, profileChanged);
    if (_discovery->InstallDeviceNotifications(_callback) != S_OK) {
        [self stop];
        return NO;
    }
    return YES;
}

- (void)stop {
    if (_discovery != nullptr) {
        _discovery->UninstallDeviceNotifications();
        _discovery->Release();
        _discovery = nullptr;
    }
    if (_callback != nullptr) {
        _callback->Release();
        _callback = nullptr;
    }
}

- (void)dealloc {
    [self stop];
}

@end
