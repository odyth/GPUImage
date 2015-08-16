//
//  GPUImageAudioPlayer.h
//  GPUImage
//
//  Created by Uzi Refaeli on 03/09/2013.
//  Copyright (c) 2013 Brad Larson. All rights reserved.
//

#import <Foundation/Foundation.h>
#include <AudioUnit/AudioUnit.h>
#import <AudioToolbox/AudioToolbox.h>
#import <AVFoundation/AVFoundation.h>

@interface GPUImageAudioPlayer : NSObject

@property(nonatomic, readonly) BOOL hasBuffer;
@property(nonatomic, readonly) SInt32 bufferSize;
@property(nonatomic, readonly) BOOL readyForMoreBytes;
@property (nonatomic) NSInteger pitch;

-(instancetype)initForOfflinePlayback:(BOOL)offline;
- (void)initAudio:(CMSampleBufferRef)sampleAudio;
- (void)start;
- (void)stop;
- (void)copyBuffer:(CMSampleBufferRef)buffer;
-(CMSampleBufferRef)processOutput;

@end