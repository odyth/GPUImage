

/*--------------------------------------------------------------------------------
 
 EAFWrite.h
 
 Copyright (C) 2009-2012 The DSP Dimension,
 Stephan M. Bernsee (SMB)
 All rights reserved
 *	Version 3.6
 
 --------------------------------------------------------------------------------*/

#include <AudioToolbox/AudioToolbox.h>

#ifndef __has_feature      // Optional.
#define __has_feature(x) 0 // Compatibility with non-clang compilers.
#endif

@interface EAFWrite : NSObject 
{
	ExtAudioFileRef mOutputAudioFile;
	
	UInt32	mAudioChannels;
	AudioStreamBasicDescription	mOutputFormat;
	
	AudioStreamBasicDescription	mStreamFormat;
	AudioFileTypeID mType;
	AudioFileID mAfid;
}

-(void)SetupStreamAndFileFormatForType:(AudioFileTypeID)aftid withSR:(float) sampleRate channels:(UInt32)numChannels wordlength:(UInt32)numBits;
- (OSStatus) openFileForWrite:(NSURL*)inPath sr:(Float64)sampleRate channels:(int)numChannels wordLength:(int)numBits type:(AudioFileTypeID)aftid;
- (void) closeFile;
-(OSStatus) writeFloats:(UInt32)numFrames fromArray:(float **)data;
-(OSStatus) writeShorts:(UInt32)numFrames fromArray:(short **)data;


@end