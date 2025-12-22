/*****************************************************************************
** $Source: /cvsroot/bluemsx/blueMSX/Src/SoundChips/AudioMixer.c,v $
**
** $Revision: 1.17 $
**
** $Date: 2008/03/30 18:38:45 $
**
** More info: http://www.bluemsx.com
**
** Copyright (C) 2003-2006 Daniel Vik
**
** This program is free software; you can redistribute it and/or modify
** it under the terms of the GNU General Public License as published by
** the Free Software Foundation; either version 2 of the License, or
** (at your option) any later version.
**
** This program is distributed in the hope that it will be useful,
** but WITHOUT ANY WARRANTY; without even the implied warranty of
** MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
** GNU General Public License for more details.
**
** You should have received a copy of the GNU General Public License
** along with this program; if not, write to the Free Software
** Foundation, Inc., 675 Mass Ave, Cambridge, MA 02139, USA.
**
******************************************************************************
*/
#include "AudioMixer.h"

#include "ArchTimer.h"
#include <stdlib.h>
#include <stdio.h>
#include <math.h>
#include <string.h>

#include "freertos/FreeRTOS.h"
#include "esp_log.h"

static const char TAG[] = "AudioMixer";

#define BITSPERSAMPLE     16

#define str2ul(s) ((UInt32)s[0]<<0|(UInt32)s[1]<<8|(UInt32)s[2]<<16|(UInt32)s[3]<<24)

#define MIN(a, b) ((a) < (b) ? (a) : (b))
#define MAX(a, b) ((a) > (b) ? (a) : (b))

typedef struct {
    UInt32 riff;
    UInt32 fileSize;
    UInt32 wave;
    struct {
        UInt32 fmt;
        UInt32 chunkSize;
        UInt16 formatType;
        UInt16 channels;
        UInt32 samplesPerSec;
        UInt32 avgBytesPerSec;
        UInt16 blockAlign;
        UInt16 bitsPerSample;
    } wavHeader;
    UInt32 data;
    UInt32 dataSize;
} WavHeader;

typedef struct {
    Int32 volume;
    Int32 pan;
    Int32 enable;
} AudioTypeInfo;

typedef struct {
    Int32 handle;
    MixerUpdateCallback updateCallback;
    void* ref;
    MixerAudioType type;
    // User config
    Int32 volume;
    Int32 pan;
    Int32 enable;
    Int32 stereo;
    // Internal config
    Int32 volumeLeft;
    Int32 volumeRight;
    // Intermediate volume info
    Int32 volIntLeft;
    Int32 volIntRight;
    Int32 volCntLeft;
    Int32 volCntRight;
} MixerChannel;

struct Mixer
{
    GetSamplesToGenerateCallback samplesCallback;
    void*  samplesRef;
    MixerWriteCallback writeCallback;
    void*  writeRef;
    Int32  fragmentSize;
    UInt32 begin;
    UInt32 index;
    UInt32 volIndex;
    Int32   genBuffer[AUDIO_STEREO_BUFFER_SIZE];
    Int32   mixBuffer[AUDIO_STEREO_BUFFER_SIZE];
    Int16   buffer[AUDIO_STEREO_BUFFER_SIZE];
    AudioTypeInfo audioTypeInfo[MIXER_CHANNEL_TYPE_COUNT];
    MixerChannel channels[MAX_CHANNELS];
    Int32   channelCount;
    Int32   handleCount;
    UInt32  oldTick;
    double  masterVolume;
    Int32   masterEnable;
    Int32   volIntLeft;
    Int32   volIntRight;
    Int32   volCntLeft;
    Int32   volCntRight;
    FILE*   file;
    int     enable;
    SemaphoreHandle_t sync_sem;
};


static void recalculateChannelVolume(Mixer* mixer, MixerChannel* channel);
static void updateVolumes(Mixer* mixer);


///////////////////////////////////////////////////////

static void mixerRecalculateType(Mixer* mixer, int audioType)
{
    AudioTypeInfo* type    = mixer->audioTypeInfo + audioType;
    int i;

    for (i = 0; i < mixer->channelCount; i++) {
        MixerChannel* channel = mixer->channels + i;
        if (channel->type == audioType) {
            channel->enable         = type->enable;
            channel->volume         = type->volume;
            channel->pan            = type->pan;
            recalculateChannelVolume(mixer, channel);
        }
    }
}

void mixerSetMasterVolume(Mixer* mixer, Int32 volume)
{
    int i;

    mixer->masterVolume = pow(10.0, (volume - 100) / 60.0) - pow(10.0, -100 / 60.0);

    for (i = 0; i < MIXER_CHANNEL_TYPE_COUNT; i++) {
        mixerRecalculateType(mixer, i);
    }
}

void mixerEnableMaster(Mixer* mixer, Int32 enable)
{
    int i;

    mixer->masterEnable = enable ? 1 : 0;

    for (i = 0; i < MIXER_CHANNEL_TYPE_COUNT; i++) {
        mixerRecalculateType(mixer, i);
    }
}

void mixerSetChannelTypeVolume(Mixer* mixer, Int32 type, Int32 volume)
{
    mixer->audioTypeInfo[type].volume = volume;
    mixerRecalculateType(mixer, type);
}

void mixerSetChannelTypePan(Mixer* mixer, Int32 type, Int32 pan)
{
    mixer->audioTypeInfo[type].pan = pan;
    mixerRecalculateType(mixer, type);
}

void mixerEnableChannelType(Mixer* mixer, Int32 type, Int32 enable)
{
    mixer->audioTypeInfo[type].enable = enable;
    mixerRecalculateType(mixer, type);
}

Int32 mixerGetChannelTypeVolume(Mixer* mixer, Int32 type, int leftRight)
{
    int i;
    Int32 volume = 0;

    updateVolumes(mixer);

    for (i = 0; i < mixer->channelCount; i++) {
        if (mixer->channels[i].type == type) {
            Int32 channelVol = leftRight ?
                               mixer->channels[i].volIntRight :
                               mixer->channels[i].volIntLeft;
            if (channelVol > volume) {
                volume = channelVol;
            }
        }
    }

    return volume;
}

///////////////////////////////////////////////////////

static void recalculateChannelVolume(Mixer* mixer, MixerChannel* channel)
{
    double volume        = pow(10.0, (channel->volume - 100) / 60.0) - pow(10.0, -100 / 60.0);
    double panLeft       = pow(10.0, (MIN(100 - channel->pan, 50) - 50) / 30.0) - pow(10.0, -50 / 30.0);
    double panRight      = pow(10.0, (MIN(channel->pan, 50) - 50) / 30.0) - pow(10.0, -50 / 30.0);

    channel->volumeLeft  = channel->enable * mixer->masterEnable * (Int32)(1024 * mixer->masterVolume * volume * panLeft);
    channel->volumeRight = channel->enable * mixer->masterEnable * (Int32)(1024 * mixer->masterVolume * volume * panRight);
}

static void updateVolumes(Mixer* mixer)
{
    int i;
    int diff = archGetSystemUpTime(50) - mixer->oldTick;

    if (diff) {
        int newVol = mixer->volIntLeft - diff;
        if (newVol < 0) newVol = 0;
        mixer->volIntLeft = newVol;

        newVol = mixer->volIntRight - diff;
        if (newVol < 0) newVol = 0;
        mixer->volIntRight = newVol;

        for (i = 0; i < mixer->channelCount; i++) {
            int newVol = mixer->channels[i].volIntLeft - diff;
            if (newVol < 0) newVol = 0;
            mixer->channels[i].volIntLeft = newVol;

            newVol = mixer->channels[i].volIntRight - diff;
            if (newVol < 0) newVol = 0;
            mixer->channels[i].volIntRight = newVol;
        }

        mixer->oldTick += diff;
    }
}

static Mixer* globalMixer = NULL;

Mixer* mixerGetGlobalMixer()
{
    return globalMixer;
}

Mixer* mixerCreate(GetSamplesToGenerateCallback callback, void* ref)
{
    Mixer* mixer = (Mixer*)calloc(1, sizeof(Mixer));

    mixer->sync_sem = xSemaphoreCreateBinary();
    assert(mixer->sync_sem != NULL);
    xSemaphoreGive(mixer->sync_sem);

    mixer->samplesCallback = callback;
    mixer->samplesRef = ref;
    mixer->fragmentSize = 512;
    mixer->enable = 1;
    if (globalMixer == NULL) globalMixer = mixer;

    return mixer;
}

void mixerDestroy(Mixer* mixer)
{
    vSemaphoreDelete(mixer->sync_sem);
    globalMixer = NULL;
    free(mixer);
}


void mixerSetWriteCallback(Mixer* mixer, MixerWriteCallback callback, void* ref, int fragmentSize)
{
    mixer->fragmentSize = fragmentSize;
    mixer->writeCallback = callback;
    mixer->writeRef = ref;

    if (mixer->fragmentSize <= 0) {
        mixer->fragmentSize = 512;
    }
}

Int32 mixerRegisterChannel(Mixer* mixer, Int32 audioType, Int32 stereo, MixerUpdateCallback callback, void* ref)
{
    MixerChannel*  channel = mixer->channels + mixer->channelCount;
    AudioTypeInfo* type    = mixer->audioTypeInfo + audioType;

    if (mixer->channelCount == MAX_CHANNELS - 1) {
        return 0;
    }

    mixer->channelCount++;

    channel->updateCallback = callback;
    channel->ref            = ref;
    channel->type           = audioType;
    channel->stereo         = stereo;
    channel->enable         = type->enable;
    channel->volume         = type->volume;
    channel->pan            = type->pan;
    channel->handle         = ++mixer->handleCount;

    recalculateChannelVolume(mixer, channel);

    return channel->handle;
}

void mixerUnregisterChannel(Mixer* mixer, Int32 handle)
{
    int i;

    if (mixer->channelCount == 0) {
        return;
    }

    for (i = 0; i < mixer->channelCount; i++) {
        if (mixer->channels[i].handle == handle) {
            break;
        }
    }

    if (i == mixer->channelCount) {
        return;
    }

    mixer->channelCount--;
    while (i < mixer->channelCount) {
        mixer->channels[i] = mixer->channels[i + 1];
        i++;
    }
}

Int32 mixerGetMasterVolume(Mixer* mixer, int leftRight)
{
    updateVolumes(mixer);
    return leftRight ? mixer->volIntRight : mixer->volIntLeft;
}

void mixerReset(Mixer* mixer)
{
    mixer->begin = 0;
    mixer->index = 0;
}

void IRAM_ATTR mixerSync(Mixer* mixer)
{
    xSemaphoreTake(mixer->sync_sem, portMAX_DELAY);

    Int16* buffer = mixer->buffer;
    int i;

    UInt32 count = mixer->samplesCallback(mixer->samplesRef);

    if (count == 0 || count > AUDIO_MONO_BUFFER_SIZE) {
        xSemaphoreGive(mixer->sync_sem);
        return;
    }

    if (!mixer->enable) {
        while (count--) {
            buffer[mixer->index++] = 0;
            buffer[mixer->index++] = 0;
            if (mixer->index >= mixer->fragmentSize) {
                if (mixer->writeCallback != NULL) {
                    UInt32 written = mixer->writeCallback(mixer->writeRef, buffer, mixer->fragmentSize);
                    count += mixer->fragmentSize - written;
                }
                mixer->begin = 0;
                mixer->index = 0;
            }
        }
        xSemaphoreGive(mixer->sync_sem);
        return;
    }
    
    memset(mixer->mixBuffer, 0, sizeof(Int32) * count * 2);

    for (i = 0; i < mixer->channelCount; i++) {
        if (mixer->channels[i].updateCallback == NULL) {
            continue;
        }

        Int32* gen = mixer->genBuffer;
        Int32* mix = mixer->mixBuffer;

        gen = mixer->channels[i].updateCallback(mixer->channels[i].ref, gen, count);
        if (gen == NULL) {
            continue;
        }

        for(int sample = 0; sample < count; sample++) {
            Int32 chanLeft;
            Int32 chanRight;

            if (mixer->channels[i].stereo) {
                chanLeft = mixer->channels[i].volumeLeft * *gen++;
                chanRight = mixer->channels[i].volumeRight * *gen++;
            }
            else {
                Int32 tmp = *gen++;
                chanLeft = mixer->channels[i].volumeLeft * tmp;
                chanRight = mixer->channels[i].volumeRight * tmp;
            }

            mixer->channels[i].volCntLeft  += (chanLeft  > 0 ? chanLeft  : -chanLeft)  / 2048;
            mixer->channels[i].volCntRight += (chanRight > 0 ? chanRight : -chanRight) / 2048;

            *mix++ += chanLeft;
            *mix++ += chanRight;
        }
    }
    
    Int32* mix = mixer->mixBuffer;
    while(count--) {
        Int32 left = *mix++;
        Int32 right = *mix++;

        left  /= 4096;
        right /= 4096;

        mixer->volCntLeft  += left  > 0 ? left  : -left;
        mixer->volCntRight += right > 0 ? right : -right;

        if (left  >  32767) { left  = 32767; }
        if (left  < -32767) { left  = -32767; }
        if (right >  32767) { right = 32767; }
        if (right < -32767) { right = -32767; }

        buffer[mixer->index++] = (Int16)left;
        buffer[mixer->index++] = (Int16)right;

        if (mixer->index >= mixer->fragmentSize) {
            if (mixer->writeCallback != NULL) {
                UInt32 written = mixer->writeCallback(mixer->writeRef, &buffer[mixer->begin], mixer->fragmentSize);
                if (written != mixer->fragmentSize) {
                    mixer->begin += written;
                    if (mixer->index + mixer->fragmentSize >= AUDIO_STEREO_BUFFER_SIZE) {
                        // prevent overflow, need to copy
                        ESP_LOGW(TAG, "Unexpected audio buffer overflow prevention");
                        memcpy(buffer, &buffer[mixer->begin], (mixer->index - mixer->begin) * sizeof(UInt16));
                        mixer->index -= mixer->begin;
                        mixer->begin = 0;
                    }
                }else{
                    mixer->begin = 0;
                    mixer->index = 0;
                }
            }else{
                mixer->begin = 0;
                mixer->index = 0;
            }
        }

        mixer->volIndex++;
    }

    if (mixer->volIndex >= 441) {
        Int32 newVolumeLeft  = mixer->volCntLeft  / mixer->volIndex / 164;
        Int32 newVolumeRight = mixer->volCntRight / mixer->volIndex / 164;

        if (newVolumeLeft > 100) {
            newVolumeLeft = 100;
        }
        if (newVolumeLeft > mixer->volIntLeft) {
            mixer->volIntLeft  = newVolumeLeft;
        }

        if (newVolumeRight > 100) {
            newVolumeRight = 100;
        }
        if (newVolumeRight > mixer->volIntRight) {
            mixer->volIntRight  = newVolumeRight;
        }

        mixer->volCntLeft  = 0;
        mixer->volCntRight = 0;

        for (i = 0; i < mixer->channelCount; i++) {
            Int32 newVolumeLeft  = (Int32)(mixer->channels[i].volCntLeft  / mixer->masterVolume / mixer->volIndex / 328);
            Int32 newVolumeRight = (Int32)(mixer->channels[i].volCntRight / mixer->masterVolume / mixer->volIndex / 328);

            if (newVolumeLeft > 100) {
                newVolumeLeft = 100;
            }
            if (newVolumeLeft > mixer->channels[i].volIntLeft) {
                mixer->channels[i].volIntLeft  = newVolumeLeft;
            }

            if (newVolumeRight > 100) {
                newVolumeRight = 100;
            }
            if (newVolumeRight > mixer->channels[i].volIntRight) {
                mixer->channels[i].volIntRight  = newVolumeRight;
            }

            mixer->channels[i].volCntLeft  = 0;
            mixer->channels[i].volCntRight = 0;
        }
        mixer->volIndex = 0;
    }
    xSemaphoreGive(mixer->sync_sem);
}

void mixerSetEnable(Mixer* mixer, int enable)
{
    mixer->enable = enable;
//    printf("AUDIO: %s\n", enable?"enabled":"disabled");
}
