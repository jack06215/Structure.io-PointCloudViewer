//
//  ViewController.m
//  KirakiraVIEW
//
//  Created by Nacho on 19/05/2015.
//  Copyright (c) 2015 Jack Cho. All rights reserved.
//




#import "ViewController.h"
#import "AnimationControl.h"
#import "PointCloudRender.h"

#import <AVFoundation/AVFoundation.h>
#import <Structure/StructureSLAM.h>
#include <algorithm>

#define RENDERER_CLASS PointCloudRenderer
#define DATA_COLS 640
#define DATA_ROWS 480


struct AppStatus
{
    NSString* const pleaseConnectSensorMessage = @"Please connect Structure Sensor.";
    NSString* const pleaseChargeSensorMessage = @"Please charge Structure Sensor.";
    NSString* const needColorCameraAccessMessage = @"This app requires camera access to capture color.\nAllow access by going to Settings → Privacy → Camera.";
    
    enum SensorStatus
    {
        SensorStatusOk,
        SensorStatusNeedsUserToConnect,
        SensorStatusNeedsUserToCharge,
    };
    

    // Structure Sensor status.
    SensorStatus sensorStatus = SensorStatusOk;

    
    // Whether iOS camera access was granted by the user.
    bool colorCameraIsAuthorized = true;
    
    // Whether there is currently a message to show.
    bool needsDisplayOfStatusMessage = false;
    
    // Flag to disable entirely status message display.
    bool statusMessageDisabled = false;
};

@interface ViewController () <AVCaptureVideoDataOutputSampleBufferDelegate, UIGestureRecognizerDelegate>
{
    
    STSensorController *_sensorController;
    
    AVCaptureSession *_avCaptureSession;
    AVCaptureDevice *_videoDevice;
    
    uint16_t *_linearizeBuffer;
    uint8_t *_coloredDepthBuffer;
    
    STFloatDepthFrame *_floatDepthFrame;
    STNormalEstimator *_normalsEstimator;
    
    UILabel* _statusLabel;
    
    AppStatus _appStatus;
    
    
    // Animation Control
    AnimationControl *_animation;
    
    // Point Cloud Rendering Class
    RENDERER_CLASS *_renderer;
    
    
}

@property (strong, nonatomic) EAGLContext *context;

- (BOOL)connectAndStartStreaming;
- (void)renderDepthFrame:(STDepthFrame*)depthFrame;
- (void)renderColorFrame:(CMSampleBufferRef)sampleBuffer;
- (void)setupColorCamera;
- (void)startColorCamera;
- (void)stopColorCamera;

@end

@implementation ViewController


- (void)viewDidLoad
{
    [super viewDidLoad];
    
    
    // GL setup
    _renderer = [[RENDERER_CLASS alloc] initWithCols:DATA_COLS rows:DATA_ROWS];
    if (!_renderer) {
        NSLog(@"Failed to create renderer.");
        return;
    }
    
    
    self.context = _renderer.context;
    
    
    
    // = (GLKView *)self.view;
    self.pointCloudView.context = self.context;
    self.pointCloudView.drawableDepthFormat = _renderer.drawableDepthFormat;
    
    _animation = new AnimationControl(self.pointCloudView.frame.size.width,
                                      self.pointCloudView.frame.size.height);

    
    
    _sensorController = [STSensorController sharedController];
    _sensorController.delegate = self;
    
    _linearizeBuffer = NULL;
    _coloredDepthBuffer = NULL;
    
    [self setupGestureRecognizer];
    [self setupColorCamera];
    
    // Sample usage of wireless debugging API
    NSError* error = nil;
    [STWirelessLog broadcastLogsToWirelessConsoleAtAddress:@"172.19.122.222" usingPort:4999 error:&error];
    
    if (error)
        NSLog(@"Oh no! Can't start wireless log: %@", [error localizedDescription]);
}

- (void)dealloc
{
    if (_linearizeBuffer)
        free(_linearizeBuffer);
    
    if (_coloredDepthBuffer)
        free(_coloredDepthBuffer);
}


- (void)viewDidAppear:(BOOL)animated
{
    static BOOL fromLaunch = true;
    if(fromLaunch)
    {
        
        //
        // Create a UILabel in the center of our view to display status messages
        //
        
        // We do this here instead of in viewDidLoad so that we get the correctly size/rotation view bounds
        if (!_statusLabel) {
            
            _statusLabel = [[UILabel alloc] initWithFrame:self.view.bounds];
            _statusLabel.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.7];
            _statusLabel.textAlignment = NSTextAlignmentCenter;
            _statusLabel.font = [UIFont systemFontOfSize:35.0];
            _statusLabel.numberOfLines = 2;
            _statusLabel.textColor = [UIColor whiteColor];
            
            [self updateAppStatusMessage];
            [self.view addSubview: _statusLabel];
        }
        
        [self connectAndStartStreaming];
        fromLaunch = false;
        
        // From now on, make sure we get notified when the app becomes active to restore the sensor state if necessary.
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(appDidBecomeActive)
                                                     name:UIApplicationDidBecomeActiveNotification
                                                   object:nil];
    }
}


- (void)appDidBecomeActive
{
    [self connectAndStartStreaming];
}


- (void)didReceiveMemoryWarning
{
    [super didReceiveMemoryWarning];
    // Dispose of any resources that can be recreated.
}


- (BOOL)connectAndStartStreaming
{
    
    STSensorControllerInitStatus result = [_sensorController initializeSensorConnection];
    
    BOOL didSucceed = (result == STSensorControllerInitStatusSuccess || result == STSensorControllerInitStatusAlreadyInitialized);
    
    
    if (didSucceed)
    {
        // There's no status about the sensor that we need to display anymore
        _appStatus.sensorStatus = AppStatus::SensorStatusOk;
        [self updateAppStatusMessage];
        
        // Start the color camera, setup if needed
        [self startColorCamera];
        
        // Set sensor stream quality
        STStreamConfig streamConfig = STStreamConfigDepth320x240;
        
        // Request that we receive depth frames with synchronized color pairs
        // After this call, we will start to receive frames through the delegate methods
        NSError* error = nil;
        BOOL optionsAreValid = [_sensorController startStreamingWithOptions:@{kSTStreamConfigKey : @(streamConfig),
                                                                              kSTFrameSyncConfigKey : @(STFrameSyncDepthAndRgb)} error:&error];
        if (!optionsAreValid)
        {
            NSLog(@"Error during streaming start: %s", [[error localizedDescription] UTF8String]);
            return false;
        }
        // Allocate the depth (shift) -> to depth (millimeters) converter class
        _floatDepthFrame = [[STFloatDepthFrame alloc] init];
        
        // Allocate the depth -> surface normals converter class
        _normalsEstimator = [[STNormalEstimator alloc] initWithStreamInfo:[_sensorController getStreamInfo:streamConfig]];
    }
    else
    {
        if (result == STSensorControllerInitStatusSensorNotFound)
            NSLog(@"[Debug] No Structure Sensor found!");
        else if (result == STSensorControllerInitStatusOpenFailed)
            NSLog(@"[Error] Structure Sensor open failed.");
        else if (result == STSensorControllerInitStatusSensorIsWakingUp)
            NSLog(@"[Debug] Structure Sensor is waking from low power.");
        else if (result != STSensorControllerInitStatusSuccess)
            NSLog(@"[Debug] Structure Sensor failed to init with status %d.", (int)result);
        
        _appStatus.sensorStatus = AppStatus::SensorStatusNeedsUserToConnect;
        [self updateAppStatusMessage];
    }
    
    return didSucceed;
    
}

- (void)showAppStatusMessage:(NSString *)msg
{
    _appStatus.needsDisplayOfStatusMessage = true;
    [self.view.layer removeAllAnimations];
    
    [_statusLabel setText:msg];
    [_statusLabel setHidden:NO];
    
    // Progressively show the message label.
    [self.view setUserInteractionEnabled:false];
    
    [UIView animateWithDuration:0.5f
                     animations:^()
     {
         _statusLabel.alpha = 1.0f;
     }
                     completion:nil
     ];
}

- (void)hideAppStatusMessage
{
    
    _appStatus.needsDisplayOfStatusMessage = false;
    [self.view.layer removeAllAnimations];
    
    [UIView animateWithDuration:0.5f
                     animations:^()
     {
         _statusLabel.alpha = 0.0f;
     }
                     completion:^(BOOL finished)
     {
         // If nobody called showAppStatusMessage before the end of the animation, do not hide it.
         if (!_appStatus.needsDisplayOfStatusMessage)
         {
             [_statusLabel setHidden:YES];
             [self.view setUserInteractionEnabled:true];
         }
     }];
}

-(void)updateAppStatusMessage
{
    // Skip everything if we should not show app status messages (e.g. in viewing state).
    if (_appStatus.statusMessageDisabled)
    {
        [self hideAppStatusMessage];
        return;
    }
    
    // First show sensor issues, if any.
    switch (_appStatus.sensorStatus)
    {
        case AppStatus::SensorStatusOk:
        {
            break;
        }
            
        case AppStatus::SensorStatusNeedsUserToConnect:
        {
            [self showAppStatusMessage:_appStatus.pleaseConnectSensorMessage];
            return;
        }
            
        case AppStatus::SensorStatusNeedsUserToCharge:
        {
            [self showAppStatusMessage:_appStatus.pleaseChargeSensorMessage];
            return;
        }
    }
    
    // Then show color camera permission issues, if any.
    if (!_appStatus.colorCameraIsAuthorized)
    {
        [self showAppStatusMessage:_appStatus.needColorCameraAccessMessage];
        return;
    }
    
    // If we reach this point, no status to show.
    [self hideAppStatusMessage];
}

-(bool) isConnectedAndCharged
{
    return [_sensorController isConnected] && ![_sensorController isLowPower];
}


- (void) setupGestureRecognizer
{
    UIPinchGestureRecognizer *pinchScaleGesture = [[UIPinchGestureRecognizer alloc]
                                                   initWithTarget:self
                                                   action:@selector(pinchScaleGesture:)];
    [pinchScaleGesture setDelegate:self];
    [self.pointCloudView addGestureRecognizer:pinchScaleGesture];
    
    UIPanGestureRecognizer *panRotGesture = [[UIPanGestureRecognizer alloc]
                                             initWithTarget:self
                                             action:@selector(panRotGesture:)];
    [panRotGesture setDelegate:self];
    [panRotGesture setMaximumNumberOfTouches:1];
    [self.pointCloudView addGestureRecognizer:panRotGesture];
    
    UIPanGestureRecognizer *panTransGesture = [[UIPanGestureRecognizer alloc]
                                               initWithTarget:self
                                               action:@selector(panTransGesture:)];
    [panTransGesture setDelegate:self];
    [panTransGesture setMaximumNumberOfTouches:2];
    [panTransGesture setMinimumNumberOfTouches:2];
    [self.pointCloudView addGestureRecognizer:panTransGesture];
}

#pragma mark - GLKView and GLKViewController delegate methods

- (void)update
{
    [_renderer updateWithBounds:self.pointCloudView.bounds
                     projection:_animation->currentProjRt()
                      modelView:_animation->currentModelView()
                       invScale:1.0f / _animation->currentScale()];
}

- (void)glkView:(GLKView *)view drawInRect:(CGRect)rect
{
    [_renderer glkView:view drawInRect:rect];
}

#pragma mark -
#pragma mark Structure SDK Delegate Methods

- (void)sensorDidDisconnect
{
    NSLog(@"Structure Sensor disconnected!");
    
    _appStatus.sensorStatus = AppStatus::SensorStatusNeedsUserToConnect;
    [self updateAppStatusMessage];
    
    // Stop the color camera when there isn't a connected Structure Sensor
    [self stopColorCamera];
}

- (void)sensorDidConnect
{
    NSLog(@"Structure Sensor connected!");
    [self connectAndStartStreaming];
}

- (void)sensorDidLeaveLowPowerMode
{
    _appStatus.sensorStatus = AppStatus::SensorStatusNeedsUserToConnect;
    [self updateAppStatusMessage];
}


- (void)sensorBatteryNeedsCharging
{
    // Notify the user that the sensor needs to be charged.
    _appStatus.sensorStatus = AppStatus::SensorStatusNeedsUserToCharge;
    [self updateAppStatusMessage];
}

- (void)sensorDidStopStreaming:(STSensorControllerDidStopStreamingReason)reason
{
    //If needed, change any UI elements to account for the stopped stream
    
    // Stop the color camera when we're not streaming from the Structure Sensor
    [self stopColorCamera];
    
}

- (void)sensorDidOutputDepthFrame:(STDepthFrame *)depthFrame
{
    [self renderDepthFrame:depthFrame];
    //[_renderer updatePointsWithDepth:_floatDepthFrame image:nil];
}

// This synchronized API will only be called when two frames match. Typically, timestamps are within 1ms of each other.
// Two important things have to happen for this method to be called:
// Tell the SDK we want framesync with options @{kSTFrameSyncConfigKey : @(STFrameSyncDepthAndRgb)} in [STSensorController startStreamingWithOptions:error:]
// Give the SDK color frames as they come in:     [_ocSensorController frameSyncNewColorBuffer:sampleBuffer];
- (void)sensorDidOutputSynchronizedDepthFrame:(STDepthFrame*)depthFrame
                               andColorBuffer:(CMSampleBufferRef)sampleBuffer
{
    [self renderDepthFrame:depthFrame];
    [self renderColorFrame:sampleBuffer];
    //[_renderer updatePointsWithDepth:_floatDepthFrame image:_cameraImageView.image.CGImage];
}


#pragma mark -
#pragma mark Rendering

const uint16_t maxShiftValue = 2048;

- (void)populateLinearizeBuffer
{
    _linearizeBuffer = (uint16_t*)malloc((maxShiftValue + 1) * sizeof(uint16_t));
    
    for (int i=0; i <= maxShiftValue; i++)
    {
        float v = i/ (float)maxShiftValue;
        v = powf(v, 3)* 6;
        _linearizeBuffer[i] = v*6*256;
    }
}

// This function is equivalent to calling [STDepthAsRgba convertDepthFrameToRgba] with the
// STDepthToRgbaStrategyRedToBlueGradient strategy. Not using the SDK here for didactic purposes.
- (void)convertShiftToRGBA:(const uint16_t*)shiftValues depthValuesCount:(size_t)depthValuesCount
{
    for (size_t i = 0; i < depthValuesCount; i++)
    {
        // We should not get higher values than maxShiftValue, but let's stay on the safe side.
        uint16_t boundedShift = std::min (shiftValues[i], maxShiftValue);
        
        // Use a lookup table to make the non-linear input values vary more linearly with metric depth
        int linearizedDepth = _linearizeBuffer[boundedShift];
        
        // Use the upper byte of the linearized shift value to choose a base color
        // Base colors range from: (closest) White, Red, Orange, Yellow, Green, Cyan, Blue, Black (farthest)
        int lowerByte = (linearizedDepth & 0xff);
        
        // Use the lower byte to scale between the base colors
        int upperByte = (linearizedDepth >> 8);
        
        switch (upperByte)
        {
            case 0:
                _coloredDepthBuffer[4*i+0] = 255;
                _coloredDepthBuffer[4*i+1] = 255-lowerByte;
                _coloredDepthBuffer[4*i+2] = 255-lowerByte;
                _coloredDepthBuffer[4*i+3] = 255;
                break;
            case 1:
                _coloredDepthBuffer[4*i+0] = 255;
                _coloredDepthBuffer[4*i+1] = lowerByte;
                _coloredDepthBuffer[4*i+2] = 0;
                break;
            case 2:
                _coloredDepthBuffer[4*i+0] = 255-lowerByte;
                _coloredDepthBuffer[4*i+1] = 255;
                _coloredDepthBuffer[4*i+2] = 0;
                break;
            case 3:
                _coloredDepthBuffer[4*i+0] = 0;
                _coloredDepthBuffer[4*i+1] = 255;
                _coloredDepthBuffer[4*i+2] = lowerByte;
                break;
            case 4:
                _coloredDepthBuffer[4*i+0] = 0;
                _coloredDepthBuffer[4*i+1] = 255-lowerByte;
                _coloredDepthBuffer[4*i+2] = 255;
                break;
            case 5:
                _coloredDepthBuffer[4*i+0] = 0;
                _coloredDepthBuffer[4*i+1] = 0;
                _coloredDepthBuffer[4*i+2] = 255-lowerByte;
                break;
            default:
                _coloredDepthBuffer[4*i+0] = 0;
                _coloredDepthBuffer[4*i+1] = 0;
                _coloredDepthBuffer[4*i+2] = 0;
                break;
        }
    }
}

- (void)renderDepthFrame:(STDepthFrame *)depthFrame
{
    size_t cols = depthFrame.width;
    size_t rows = depthFrame.height;
    
    if (_linearizeBuffer == NULL )
    {
        [self populateLinearizeBuffer];
        _coloredDepthBuffer = (uint8_t*)malloc(cols * rows * 4);
    }
    
    // Conversion of 16-bit non-linear shift depth values to 32-bit RGBA
    //
    // Adapted from: https://github.com/OpenKinect/libfreenect/blob/master/examples/glview.c
    //
    [self convertShiftToRGBA:depthFrame.data depthValuesCount:cols * rows];
    
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    
    CGBitmapInfo bitmapInfo;
    bitmapInfo = (CGBitmapInfo)kCGImageAlphaNoneSkipLast;
    bitmapInfo |= kCGBitmapByteOrder32Big;
    
    NSData *data = [NSData dataWithBytes:_coloredDepthBuffer length:cols * rows * 4];
    CGDataProviderRef provider = CGDataProviderCreateWithCFData((CFDataRef)data); //toll-free ARC bridging
    
    CGImageRef imageRef = CGImageCreate(cols,                        //width
                                        rows,                        //height
                                        8,                           //bits per component
                                        8 * 4,                       //bits per pixel
                                        cols * 4,                    //bytes per row
                                        colorSpace,                  //Quartz color space
                                        bitmapInfo,                  //Bitmap info (alpha channel?, order, etc)
                                        provider,                    //Source of data for bitmap
                                        NULL,                        //decode
                                        false,                       //pixel interpolation
                                        kCGRenderingIntentDefault);  //rendering intent
    
    // Assign CGImage to UIImage
    _depthImageView.image = [UIImage imageWithCGImage:imageRef];
    
    CGImageRelease(imageRef);
    CGDataProviderRelease(provider);
    CGColorSpaceRelease(colorSpace);
    
}

- (void)renderColorFrame:(CMSampleBufferRef)sampleBuffer
{
    
    CVImageBufferRef pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
    CVPixelBufferLockBaseAddress(pixelBuffer, 0);
    
    size_t cols = CVPixelBufferGetWidth(pixelBuffer);
    size_t rows = CVPixelBufferGetHeight(pixelBuffer);
    
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    
    unsigned char *ptr = (unsigned char *) CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0);
    
    NSData *data = [[NSData alloc] initWithBytes:ptr length:rows*cols*4];
    CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);
    
    CGBitmapInfo bitmapInfo;
    bitmapInfo = (CGBitmapInfo)kCGImageAlphaNoneSkipFirst;
    bitmapInfo |= kCGBitmapByteOrder32Little;
    
    CGDataProviderRef provider = CGDataProviderCreateWithCFData((CFDataRef)data);
    
    CGImageRef imageRef = CGImageCreate(cols,
                                        rows,
                                        8,
                                        8 * 4,
                                        cols*4,
                                        colorSpace,
                                        bitmapInfo,
                                        provider,
                                        NULL,
                                        false,
                                        kCGRenderingIntentDefault);
    
    self.cameraImageView.image = [[UIImage alloc] initWithCGImage:imageRef];
    
    CGImageRelease(imageRef);
    CGDataProviderRelease(provider);
    CGColorSpaceRelease(colorSpace);
    
}



#pragma mark -  AVFoundation

- (BOOL)queryCameraAuthorizationStatusAndNotifyUserIfNotGranted
{
    // This API was introduced in iOS 7, but in iOS 8 it's actually enforced.
    if ([AVCaptureDevice respondsToSelector:@selector(authorizationStatusForMediaType:)])
    {
        AVAuthorizationStatus authStatus = [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeVideo];
        
        if (authStatus != AVAuthorizationStatusAuthorized)
        {
            NSLog(@"Not authorized to use the camera!");
            
            [AVCaptureDevice requestAccessForMediaType:AVMediaTypeVideo
                                     completionHandler:^(BOOL granted)
             {
                 // This block fires on a separate thread, so we need to ensure any actions here
                 // are sent to the right place.
                 
                 // If the request is granted, let's try again to start an AVFoundation session. Otherwise, alert
                 // the user that things won't go well.
                 if (granted)
                 {
                     
                     dispatch_async(dispatch_get_main_queue(), ^(void) {
                         
                         [self startColorCamera];
                         
                         _appStatus.colorCameraIsAuthorized = true;
                         [self updateAppStatusMessage];
                         
                     });
                     
                 }
                 
             }];
            
            return false;
        }
        
    }
    
    return true;
    
}

- (void)setupColorCamera
{
    // If already setup, skip it
    if (_avCaptureSession)
        return;
    
    bool cameraAccessAuthorized = [self queryCameraAuthorizationStatusAndNotifyUserIfNotGranted];
    
    if (!cameraAccessAuthorized)
    {
        _appStatus.colorCameraIsAuthorized = false;
        [self updateAppStatusMessage];
        return;
    }
    
    // Use VGA color.
    NSString *sessionPreset = AVCaptureSessionPreset640x480;
    
    // Set up Capture Session.
    _avCaptureSession = [[AVCaptureSession alloc] init];
    [_avCaptureSession beginConfiguration];
    
    // Set preset session size.
    [_avCaptureSession setSessionPreset:sessionPreset];
    
    // Create a video device and input from that Device.  Add the input to the capture session.
    _videoDevice = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeVideo];
    if (_videoDevice == nil)
        assert(0);
    
    // Configure Focus, Exposure, and White Balance
    NSError *error;
    
    // iOS8 supports manual focus at near-infinity, but iOS7 doesn't.
#if __IPHONE_OS_VERSION_MAX_ALLOWED >= 80000
    bool avCaptureSupportsFocusNearInfinity = [_videoDevice respondsToSelector:@selector(setFocusModeLockedWithLensPosition:completionHandler:)];
#else
    bool avCaptureSupportsFocusNearInfinity = false;
#endif
    
    // Use auto-exposure, and auto-white balance and set the focus to infinity.
    if([_videoDevice lockForConfiguration:&error])
    {
        
        // Allow exposure to change
        if ([_videoDevice isExposureModeSupported:AVCaptureExposureModeContinuousAutoExposure])
            [_videoDevice setExposureMode:AVCaptureExposureModeContinuousAutoExposure];
        
        // Allow white balance to change
        if ([_videoDevice isWhiteBalanceModeSupported:AVCaptureWhiteBalanceModeContinuousAutoWhiteBalance])
            [_videoDevice setWhiteBalanceMode:AVCaptureWhiteBalanceModeContinuousAutoWhiteBalance];
        
        if (avCaptureSupportsFocusNearInfinity)
        {
            // Set focus at the maximum position allowable (e.g. "near-infinity") to get the
            // best color/depth alignment.
#if __IPHONE_OS_VERSION_MAX_ALLOWED >= 80000
            [_videoDevice setFocusModeLockedWithLensPosition:1.0f completionHandler:nil];
#endif
        }
        else
        {
            
            // Allow the focus to vary, but restrict the focus to far away subject matter
            if ([_videoDevice isAutoFocusRangeRestrictionSupported])
                [_videoDevice setAutoFocusRangeRestriction:AVCaptureAutoFocusRangeRestrictionFar];
            
            if ([_videoDevice isFocusModeSupported:AVCaptureFocusModeContinuousAutoFocus])
                [_videoDevice setFocusMode:AVCaptureFocusModeContinuousAutoFocus];
            
        }
        
        [_videoDevice unlockForConfiguration];
    }
    
    //  Add the device to the session.
    AVCaptureDeviceInput *input = [AVCaptureDeviceInput deviceInputWithDevice:_videoDevice error:&error];
    if (error)
    {
        NSLog(@"Cannot initialize AVCaptureDeviceInput");
        assert(0);
    }
    
    [_avCaptureSession addInput:input]; // After this point, captureSession captureOptions are filled.
    
    //  Create the output for the capture session.
    AVCaptureVideoDataOutput* dataOutput = [[AVCaptureVideoDataOutput alloc] init];
    
    // We don't want to process late frames.
    [dataOutput setAlwaysDiscardsLateVideoFrames:YES];
    
    // Use BGRA pixel format.
    [dataOutput setVideoSettings:[NSDictionary
                                  dictionaryWithObject:[NSNumber numberWithInt:kCVPixelFormatType_32BGRA]
                                  forKey:(id)kCVPixelBufferPixelFormatTypeKey]];
    
    // Set dispatch to be on the main thread so OpenGL can do things with the data
    [dataOutput setSampleBufferDelegate:self queue:dispatch_get_main_queue()];
    
    [_avCaptureSession addOutput:dataOutput];
    
    // Force the framerate to 30 FPS, to be in sync with Structure Sensor.
    if ([_videoDevice respondsToSelector:@selector(setActiveVideoMaxFrameDuration:)]
        && [_videoDevice respondsToSelector:@selector(setActiveVideoMinFrameDuration:)])
    {
        // Available since iOS 7.
        if([_videoDevice lockForConfiguration:&error])
        {
            [_videoDevice setActiveVideoMaxFrameDuration:CMTimeMake(1, 30)];
            [_videoDevice setActiveVideoMinFrameDuration:CMTimeMake(1, 30)];
            [_videoDevice unlockForConfiguration];
        }
    }
    else
    {
        NSLog(@"iOS 7 or higher is required. Camera not properly configured.");
        return;
    }
    
    [_avCaptureSession commitConfiguration];
}

- (void)startColorCamera
{
    if (_avCaptureSession && [_avCaptureSession isRunning])
        return;
    
    // Re-setup so focus is lock even when back from background
    if (_avCaptureSession == nil)
        [self setupColorCamera];
    
    // Start streaming color images.
    [_avCaptureSession startRunning];
}

- (void)stopColorCamera
{
    if ([_avCaptureSession isRunning])
    {
        // Stop the session
        [_avCaptureSession stopRunning];
    }
    
    _avCaptureSession = nil;
    _videoDevice = nil;
}

- (void)captureOutput:(AVCaptureOutput *)captureOutput didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer fromConnection:(AVCaptureConnection *)connection
{
    // Pass into the driver. The sampleBuffer will return later with a synchronized depth or IR pair.
    [_sensorController frameSyncNewColorBuffer:sampleBuffer];
}

#pragma mark - UI Control

- (void) pinchScaleGesture: (UIPinchGestureRecognizer*) gestureRecognizer
{
    if ([gestureRecognizer state] == UIGestureRecognizerStateBegan)
        _animation->onTouchScaleBegan([gestureRecognizer scale]);
    else if ( [gestureRecognizer state] == UIGestureRecognizerStateChanged)
        _animation->onTouchScaleChanged([gestureRecognizer scale]);
}

- (void) panRotGesture: (UIPanGestureRecognizer*) gestureRecognizer
{
    CGPoint touchPos = [gestureRecognizer locationInView:self.view];
    CGPoint touchVel = [gestureRecognizer velocityInView:self.view];
    GLKVector2 touchPosVec = GLKVector2Make(touchPos.x, touchPos.y);
    GLKVector2 touchVelVec = GLKVector2Make(touchVel.x, touchVel.y);
    
    if([gestureRecognizer state] == UIGestureRecognizerStateBegan)
        _animation->onTouchRotBegan(touchPosVec);
    else if([gestureRecognizer state] == UIGestureRecognizerStateChanged)
        _animation->onTouchRotChanged(touchPosVec);
    else if([gestureRecognizer state] == UIGestureRecognizerStateEnded)
        _animation->onTouchRotEnded (touchVelVec);
}

- (void) panTransGesture: (UIPanGestureRecognizer*) gestureRecognizer
{
    if ([gestureRecognizer numberOfTouches] != 2)
        return;
    
    CGPoint touchPos = [gestureRecognizer locationInView:self.view];
    CGPoint touchVel = [gestureRecognizer velocityInView:self.view];
    GLKVector2 touchPosVec = GLKVector2Make(touchPos.x, touchPos.y);
    GLKVector2 touchVelVec = GLKVector2Make(touchVel.x, touchVel.y);
    
    if([gestureRecognizer state] == UIGestureRecognizerStateBegan)
        _animation->onTouchTransBegan(touchPosVec);
    else if([gestureRecognizer state] == UIGestureRecognizerStateChanged)
        _animation->onTouchTransChanged(touchPosVec);
    else if([gestureRecognizer state] == UIGestureRecognizerStateEnded)
        _animation->onTouchTransEnded (touchVelVec);
}

- (void) touchesBegan: (NSSet*)   touches
            withEvent: (UIEvent*) event
{
    _animation->onTouchStop();
}

@end

