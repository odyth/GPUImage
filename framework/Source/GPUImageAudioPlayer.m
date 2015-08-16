//
//  GPUImageAudioPlayer.m
//  GPUImage
//
//  Created by odyth on 5/30/15.
//  Copyright (c) 2015 Brickroad Games LLC. All rights reserved.
//

#import "GPUImageAudioPlayer.h"
#import "TPCircularBuffer.h"

static const UInt32 kOutputBus = 0;
static const Float32 kSampleRate = 44100.0;
static const UInt32 kUnitSize = sizeof(SInt16);
static const UInt32 kBufferUnit = 655360;
static const UInt32 kTotalBufferSize = kBufferUnit * kUnitSize;
static const UInt32 kRescueBufferSize = kBufferUnit / 2;

static const UInt32 kNumberFrames = 512;

@interface GPUImageAudioPlayer()

@property (nonatomic) BOOL offline;
@property (nonatomic) AudioStreamBasicDescription outputFormat;
@property (nonatomic) UInt64 currentSampleTime;
@property (nonatomic) UInt32 rescueBufferSize;
@property (nonatomic) BOOL firstBufferReached;
@property (nonatomic) AUGraph processingGraph;
@property (nonatomic) AudioUnit mixerUnit;
@property (nonatomic) AudioUnit pitchUnit;
@property (nonatomic) AudioUnit outputUnit;
@property (nonatomic) TPCircularBuffer circularBuffer;
@property (nonatomic) void *rescueBuffer;

@property (nonatomic) BOOL hasBuffer;
@property (nonatomic) SInt32 bufferSize;
@property (nonatomic) BOOL readyForMoreBytes;
@property (nonatomic) BOOL initialized;

- (void)setReadyForMoreBytes;
- (TPCircularBuffer *)getBuffer;

@end

//sends the data to the mixer, which will pipe it from mixer, to pitch, then finally to output
static OSStatus playbackCallback(void *inRefCon, AudioUnitRenderActionFlags *ioActionFlags, const AudioTimeStamp *inTimeStamp, UInt32 inBusNumber, UInt32 inNumberFrames, AudioBufferList *ioData)
{
    SInt32 numberOfChannels = ioData->mBuffers[0].mNumberChannels;
    SInt16 *outSample = (SInt16 *)ioData->mBuffers[0].mData;
    
    // Zero-out all the output samples first
    memset(outSample, 0, ioData->mBuffers[0].mDataByteSize);
    
    GPUImageAudioPlayer *audioPlayer = (__bridge GPUImageAudioPlayer *)inRefCon;
    if (audioPlayer.hasBuffer)
    {
        SInt32 availableBytes;
        SInt16 *bufferTail = TPCircularBufferTail([audioPlayer getBuffer], &availableBytes);
        
        SInt32 requestedBytesSize = inNumberFrames * kUnitSize * numberOfChannels;
        
        SInt32 bytesToRead = MIN(availableBytes, requestedBytesSize);
        memcpy(outSample, bufferTail, bytesToRead);
        
        TPCircularBufferConsume([audioPlayer getBuffer], bytesToRead);
        
        if (availableBytes <= requestedBytesSize*2)
        {
            [audioPlayer setReadyForMoreBytes];
        }
        
        if (availableBytes <= requestedBytesSize)
        {
            audioPlayer.hasBuffer = NO;
        }
    }
    
    return noErr;
}

@implementation GPUImageAudioPlayer

-(instancetype)initForOfflinePlayback:(BOOL)offline
{
    self = [super init];
    if (self)
    {
        _firstBufferReached = NO;
        _rescueBuffer = nil;
        _rescueBufferSize = 0;
        _readyForMoreBytes = YES;
        _offline = offline;
        _currentSampleTime = 0;
        _initialized = NO;
    }
    
    return self;
}

- (void)dealloc
{
    DisposeAUGraph(_processingGraph);
    if (_rescueBuffer != nil)
    {
        free(_rescueBuffer);
    }
    
    TPCircularBufferCleanup(&_circularBuffer);
    [self stop];
}


#pragma mark - methods

- (void)initAudio:(CMSampleBufferRef)sampleAudio
{
    if(self.initialized == YES)
    {
        return;
    }
    
    self.initialized = YES;
    
    NSError *error = nil;
    AVAudioSession *session = [AVAudioSession sharedInstance];
    [session setCategory:AVAudioSessionCategoryAmbient error:nil];
    [session setActive:YES error:&error];
    
    // create a new AUGraph
    CheckError(NewAUGraph(&_processingGraph), @"NewAUGraph");
    
    // AUNodes represent AudioUnits on the AUGraph and provide an
    // easy means for connecting audioUnits together.
    AUNode outputNode;
    AUNode mixerNode;
    AUNode pitchNode;
    
    // Create AudioComponentDescriptions for the AUs we want in the graph
    // mixer component
    AudioComponentDescription mixer_desc;
    mixer_desc.componentType = kAudioUnitType_Mixer;
    mixer_desc.componentSubType = kAudioUnitSubType_AU3DMixerEmbedded;
    mixer_desc.componentFlags = 0;
    mixer_desc.componentFlagsMask = 0;
    mixer_desc.componentManufacturer = kAudioUnitManufacturer_Apple;
    
    AudioComponentDescription pitch_desc;
    pitch_desc.componentType = kAudioUnitType_FormatConverter;
    pitch_desc.componentSubType = kAudioUnitSubType_NewTimePitch;
    pitch_desc.componentFlags = 0;
    pitch_desc.componentFlagsMask = 0;
    pitch_desc.componentManufacturer = kAudioUnitManufacturer_Apple;
    
    //  output component
    AudioComponentDescription output_desc;
    output_desc.componentType = kAudioUnitType_Output;
    output_desc.componentSubType = (self.offline ? kAudioUnitSubType_GenericOutput : kAudioUnitSubType_RemoteIO);
    output_desc.componentFlags = 0;
    output_desc.componentFlagsMask = 0;
    output_desc.componentManufacturer = kAudioUnitManufacturer_Apple;
    
    // Add nodes to the graph to hold our AudioUnits,
    // You pass in a reference to the  AudioComponentDescription
    // and get back an  AudioUnit
    CheckError(AUGraphAddNode(_processingGraph, &mixer_desc, &mixerNode), @"AUGraphAddNode mixer");
    CheckError(AUGraphAddNode(_processingGraph, &pitch_desc, &pitchNode), @"AUGraphAddNode pitch");
    CheckError(AUGraphAddNode(_processingGraph, &output_desc, &outputNode), @"AUGraphAddNode output");
    
    // Now we can manage connections using nodes in the graph.
    // Connect the mixer node's output to the output node's input
    CheckError(AUGraphConnectNodeInput(_processingGraph, mixerNode, 0, pitchNode, 0), @"AUGraphConnectNodeInput mixer->pitch");
    CheckError(AUGraphConnectNodeInput(_processingGraph, pitchNode, 0, outputNode, 0), @"AUGraphConnectNodeInput pitch->output");
    
    // open the graph AudioUnits are open but not initialized (no resource allocation occurs here)
    CheckError(AUGraphOpen(_processingGraph), @"AUGraphOpen");
    
    // Get a link to the mixer AU so we can talk to it later
    CheckError(AUGraphNodeInfo(_processingGraph, mixerNode, NULL, &_mixerUnit), @"AUGraphNodeInfo mixer");
    CheckError(AUGraphNodeInfo(_processingGraph, pitchNode, NULL, &_pitchUnit), @"AUGraphNodeInfo pitch");
    CheckError(AUGraphNodeInfo(_processingGraph, outputNode, NULL, &_outputUnit), @"AUGraphNodeInfo output");
    
    UInt32 elementCount = 1;
    CheckError(AudioUnitSetProperty(_mixerUnit, kAudioUnitProperty_ElementCount, kAudioUnitScope_Input, 0, &elementCount, sizeof(elementCount)), @"AudioUnitSetProperty mixer elementCount");
    // Set input callback
    AURenderCallbackStruct callbackStruct;
    callbackStruct.inputProc = playbackCallback;
    callbackStruct.inputProcRefCon = (__bridge void *)(self);
    CheckError(AUGraphSetNodeInputCallback(_processingGraph, mixerNode, 0, &callbackStruct), @"AUGraphSetNodeInputCallback mixer");
    
    self.pitch = -500;
    
    // Describe format
    AudioStreamBasicDescription audioFormat;
    if(sampleAudio != NULL)
    {
        CMFormatDescriptionRef formatDescription = CMSampleBufferGetFormatDescription(sampleAudio);
        audioFormat = *CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription);
    }
    else
    {
        audioFormat.mFormatID	= kAudioFormatLinearPCM;
        audioFormat.mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked;
        audioFormat.mSampleRate = kSampleRate;
        audioFormat.mReserved = 0;
        audioFormat.mBytesPerPacket = 2;
        audioFormat.mFramesPerPacket = 1;
        audioFormat.mBytesPerFrame = 2;
        audioFormat.mChannelsPerFrame = 1;
        audioFormat.mBitsPerChannel = 16;
    }
    
    // Apply format
    CheckError(AudioUnitSetProperty(_mixerUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, kOutputBus, &audioFormat, sizeof(audioFormat)), @"AudioUnitSetProperty mixer streamFormat input");
    
    AudioStreamBasicDescription streamFormat;
    UInt32 propertySize = sizeof (streamFormat);
    CheckError(AudioUnitGetProperty(_pitchUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, kOutputBus, &streamFormat, &propertySize), @"AudioUnitGetProperty pitch streamFormat");
    CheckError(AudioUnitSetProperty(_mixerUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, kOutputBus, &streamFormat, sizeof(streamFormat)), @"AudioUnitSetProperty mixer streamFormat output");
    
    CheckError(AudioUnitSetParameter(_mixerUnit, k3DMixerParam_Gain, kAudioUnitScope_Output, kOutputBus, 8, 0), @"AudioUnitSetParameter mixerUnit gain");
    
    self.outputFormat = streamFormat;
    
    //init the processing graph
    CheckError(AUGraphInitialize(_processingGraph), @"AUGraphInitialize");
    
    TPCircularBufferInit(&_circularBuffer, kTotalBufferSize);
    self.hasBuffer = NO;
}

-(void)setPitch:(NSInteger)pitch
{
    if(_pitch != pitch)
    {
        _pitch = pitch;
        CheckError(AudioUnitSetParameter(_pitchUnit, kNewTimePitchParam_Pitch, kAudioUnitScope_Global, 0, _pitch, 0), @"AudioUnitSetParameter pitch pitch");
    }
}

- (void)start
{
    CheckError(AUGraphStart(_processingGraph), @"AUGraphStart");
}

- (void)stop
{
    CheckError(AUGraphStop(_processingGraph), @"AUGraphStop");
}


- (void)copyBuffer:(CMSampleBufferRef)buffer
{
    if (self.readyForMoreBytes == NO)
    {
        return;
    }
    
    AudioBufferList abl;
    CMBlockBufferRef blockBuffer;
    //    CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(buf, NULL, &abl, sizeof(abl), NULL, NULL, kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment, &blockBuffer);
    CheckError(CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(buffer, NULL, &abl, sizeof(abl), NULL, NULL, 0, &blockBuffer), @"CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer");
    
    UInt32 size = (unsigned int)CMSampleBufferGetTotalSampleSize(buffer);
    BOOL bytesCopied = TPCircularBufferProduceBytes(&_circularBuffer, abl.mBuffers[0].mData, size);
    
    if (bytesCopied == NO)
    {
        self.readyForMoreBytes = NO;
        
        if (size > kRescueBufferSize)
        {
            NSLog(@"Unable to allocate enought space for rescue buffer, dropping audio frame");
        }
        else
        {
            if (self.rescueBuffer == nil)
            {
                self.rescueBuffer = malloc(kRescueBufferSize);
            }
            
            self.rescueBufferSize = size;
            memcpy(self.rescueBuffer, abl.mBuffers[0].mData, size);
        }
    }
    
    CFRelease(blockBuffer);
    if (self.hasBuffer == NO && bytesCopied > 0)
    {
        self.hasBuffer = YES;
    }
}

-(CMSampleBufferRef)processOutput
{
    if(self.offline == NO)
    {
        return NULL;
    }
    
    AudioUnitRenderActionFlags flags = 0;
    AudioTimeStamp timeStamp;
    memset(&timeStamp, 0, sizeof(AudioTimeStamp));
    timeStamp.mSampleTime = self.currentSampleTime;
    timeStamp.mFlags = kAudioTimeStampSampleTimeValid;
    
    UInt32 channelCount = self.outputFormat.mChannelsPerFrame;
    AudioBufferList *bufferList = (AudioBufferList*)malloc(sizeof(AudioBufferList)+sizeof(AudioBuffer)*(channelCount-1));
    bufferList->mNumberBuffers = channelCount;
    for (UInt32 j=0; j<channelCount; j++)
    {
        AudioBuffer buffer = {0};
        buffer.mNumberChannels = 1;
        buffer.mDataByteSize = kNumberFrames * self.outputFormat.mBytesPerFrame;
        buffer.mData = calloc(kNumberFrames, self.outputFormat.mBytesPerFrame);
        
        bufferList->mBuffers[j] = buffer;
    }
    
    CheckError(AudioUnitRender(_outputUnit, &flags, &timeStamp, kOutputBus, kNumberFrames, bufferList), @"AudioUnitRender outputUnit");
    
    CMSampleBufferRef sampleBufferRef = NULL;
    CMFormatDescriptionRef format = NULL;
    CMSampleTimingInfo timing = { CMTimeMake(1, 44100), kCMTimeZero, kCMTimeInvalid };
    AudioStreamBasicDescription outputFormat = self.outputFormat;
    CheckError(CMAudioFormatDescriptionCreate(kCFAllocatorDefault, &outputFormat, 0, NULL, 0, NULL, NULL, &format), @"CMAudioFormatDescriptionCreate");
    CheckError(CMSampleBufferCreate(kCFAllocatorDefault, NULL, false, NULL, NULL, format, kNumberFrames, 1, &timing, 0, NULL, &sampleBufferRef), @"CMSampleBufferCreate");
    
    CheckError(CMSampleBufferSetDataBufferFromAudioBufferList(sampleBufferRef, kCFAllocatorDefault, kCFAllocatorDefault, 0, bufferList), @"CMSampleBufferSetDataBufferFromAudioBufferList");
    
    UInt32 framesRead = bufferList->mBuffers[0].mDataByteSize/self.outputFormat.mBytesPerFrame;
    self.currentSampleTime += framesRead;
    
    free(bufferList);
    return sampleBufferRef;
}

- (TPCircularBuffer *)getBuffer
{
    return &_circularBuffer;
}

- (void)setReadyForMoreBytes
{
    if (self.rescueBufferSize > 0)
    {
        BOOL bytesCopied = TPCircularBufferProduceBytes(&_circularBuffer, self.rescueBuffer, self.rescueBufferSize);
        if (bytesCopied == NO)
        {
            NSLog(@"Unable to copy resuce buffer into main buffer, dropping frame");
        }
        self.rescueBufferSize = 0;
    }
    
    self.readyForMoreBytes = YES;
}

static inline void CheckError(OSStatus status, NSString *errorMessage)
{
    if(status != noErr)
    {
        NSLog(@"%@ %d", errorMessage, (int)status);
    }
}

@end