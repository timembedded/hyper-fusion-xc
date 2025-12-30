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

#include <freertos/FreeRTOS.h>
#include <esp_log.h>

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
    bool  enable;
} AudioTypeInfo;

typedef struct {
    Int32 handle;
    MixerUpdateCallback updateCallback[2];
    void* ref;
    MixerAudioType type;
    MixerAudioType connectedType;
    // User config
    Int32 volume;
    Int32 pan;
    bool  enable;
    bool  stereo;
    // Internal config
    Int32 volumeLeft;
    Int32 volumeRight;
    // Intermediate volume info
    Int32 volIntLeft;
    Int32 volIntRight;
    Int32 volCntLeft;
    Int32 volCntRight;
} MixerChannel;

struct Mixer;
typedef struct {
    struct Mixer* mixer;
    int core;
    SemaphoreHandle_t semStart;
    SemaphoreHandle_t semDone;
    Int32   genBuffer[AUDIO_STEREO_BUFFER_SIZE];
} MixerTaskData;

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
    Int32   mixBuffer[AUDIO_STEREO_BUFFER_SIZE];
    Int16   buffer[AUDIO_STEREO_BUFFER_SIZE];
    AudioTypeInfo audioTypeInfo[MIXER_CHANNEL_TYPE_COUNT];
    MixerChannel channels[MAX_CHANNELS];
    Int32   channelCount;
    Int32   handleCount;
    UInt32  oldTick;
    double  masterVolume;
    bool    masterEnable;
    Int32   volIntLeft;
    Int32   volIntRight;
    Int32   volCntLeft;
    Int32   volCntRight;
    FILE*   file;
    bool    enable;
    SemaphoreHandle_t sync_sem;
    MixerTaskData taskData[2];
    volatile UInt32  samplesToMix;
    SemaphoreHandle_t semMix;
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

void mixerEnableMaster(Mixer* mixer, bool enable)
{
    int i;

    mixer->masterEnable = enable;

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

void mixerEnableChannelType(Mixer* mixer, Int32 type, bool enable)
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

    channel->volumeLeft  = (channel->enable && mixer->masterEnable)? (Int32)(1024 * mixer->masterVolume * volume * panLeft) : 0;
    channel->volumeRight = (channel->enable && mixer->masterEnable)? (Int32)(1024 * mixer->masterVolume * volume * panRight) : 0;
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

Mixer* mixerCreate(GetSamplesToGenerateCallback callback, void* ref, int fragmentSize)
{
    Mixer* mixer = (Mixer*)calloc(1, sizeof(Mixer));

    mixer->sync_sem = xSemaphoreCreateBinary();
    assert(mixer->sync_sem != NULL);
    xSemaphoreGive(mixer->sync_sem);

    mixer->samplesCallback = callback;
    mixer->samplesRef = ref;
    mixer->fragmentSize = fragmentSize;
    mixer->enable = false;

    mixer->samplesToMix = 0;
    mixer->semMix = xSemaphoreCreateBinary();
    xSemaphoreGive(mixer->semMix);

    for (int i = 0; i < 2; i++) {
        mixer->taskData[i].mixer = mixer;
        mixer->taskData[i].core = i;
        mixer->taskData[i].semStart = xSemaphoreCreateBinary(); // is taken by default
        mixer->taskData[i].semDone = xSemaphoreCreateBinary();
    }

    return mixer;
}

void mixerDestroy(Mixer* mixer)
{
    mixerSetEnable(mixer, false);
    vSemaphoreDelete(mixer->sync_sem);
    vSemaphoreDelete(mixer->semMix);
    for (int i = 0; i < 2; i++) {
        vSemaphoreDelete(mixer->taskData[i].semStart);
        vSemaphoreDelete(mixer->taskData[i].semDone);
    }
    free(mixer);
}

void mixerSetWriteCallback(Mixer* mixer, MixerWriteCallback callback, void* ref)
{
    mixer->writeCallback = callback;
    mixer->writeRef = ref;
}

Int32 mixerRegisterChannel(Mixer* mixer, int core, Int32 audioType, Int32 connectedType, bool stereo, MixerUpdateCallback callback, void* ref)
{
    MixerChannel*  channel = mixer->channels + mixer->channelCount;
    AudioTypeInfo* type    = mixer->audioTypeInfo + audioType;

    if (mixer->channelCount == MAX_CHANNELS - 1) {
        return 0;
    }

    mixer->channelCount++;

    channel->updateCallback[core] = callback;
    channel->ref            = ref;
    channel->type           = audioType;
    channel->connectedType  = connectedType? connectedType : MIXER_CHANNEL_TYPE_COUNT;
    channel->stereo         = stereo;
    channel->enable         = type->enable;
    channel->volume         = type->volume;
    channel->pan            = type->pan;
    channel->handle         = ++mixer->handleCount;

    if (connectedType) {
        MixerChannel* connected_channel = mixer->channels + mixer->channelCount;
        if (mixer->channelCount == MAX_CHANNELS - 1) {
            return 0;
        }
        mixer->channelCount++;
        connected_channel->type = connectedType;
        connected_channel->connectedType = MIXER_CHANNEL_TYPE_COUNT;
    }

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

void IRAM_ATTR MixerTask(void *args)
{
    MixerTaskData *task = (MixerTaskData*)args;
    Mixer* mixer = task->mixer;
    int core = task->core;

    ESP_LOGI(TAG, "Audio mixer task started on core %d", core);

    for(;;) {
        xSemaphoreTake(task->semStart, portMAX_DELAY);
        UInt32 count = mixer->samplesToMix;
        if (!mixer->enable) {
            xSemaphoreGive(task->semDone);
            ESP_LOGI(TAG, "Audio mixer task on core %d stopped", core);
            break;
        }
        if (count == 0) {
            ESP_LOGE(TAG, "Audio mixer got invalid count on core %d", core);
            break;
        }
        //ESP_LOGI(TAG, "Mix%d: Processing %d samples", core, count);
        for (int i = 0; i < mixer->channelCount; i++) {
            if (mixer->channels[i].updateCallback[core] == NULL) {
                continue;
            }

            Int32* gen = task->genBuffer;
            Int32* mix = mixer->mixBuffer;

            gen = mixer->channels[i].updateCallback[core](mixer->channels[i].ref, gen, count);
            if (gen == NULL) {
                continue;
            }

            xSemaphoreTake(mixer->semMix, portMAX_DELAY);

            for(int sample = 0; sample < count; sample++) {
                if (mixer->channels[i].connectedType != MIXER_CHANNEL_TYPE_COUNT) {
                    int connectedType = mixer->channels[i].connectedType;
                    int chanLeft;
                    int chanRight;

                    int tmp = *gen++;
                    chanLeft = mixer->channels[i].volumeLeft * tmp;
                    chanRight = mixer->channels[i].volumeRight * tmp;

                    tmp = *gen++;
                    chanLeft += mixer->channels[connectedType].volumeLeft * tmp;
                    chanRight += mixer->channels[connectedType].volumeRight * tmp;

                    mixer->channels[i].volCntLeft  += (chanLeft  > 0 ? chanLeft  : -chanLeft)  / 2048;
                    mixer->channels[i].volCntRight += (chanRight > 0 ? chanRight : -chanRight) / 2048;

                    *mix++ += chanLeft;
                    *mix++ += chanRight;
                }else{
                    int chanLeft;
                    int chanRight;

                    if (mixer->channels[i].stereo) {
                        chanLeft = mixer->channels[i].volumeLeft * *gen++;
                        chanRight = mixer->channels[i].volumeRight * *gen++;
                    }else{
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

            xSemaphoreGive(mixer->semMix);
        }
        xSemaphoreGive(task->semDone);
    }
    vTaskDelete(NULL);
}

void IRAM_ATTR mixerSync(Mixer* mixer)
{
    xSemaphoreTake(mixer->sync_sem, portMAX_DELAY);

    UInt32 count = mixer->samplesCallback(mixer->samplesRef);
    if (count == 0) {
        xSemaphoreGive(mixer->sync_sem);
        return;
    }
    if (count > AUDIO_MONO_BUFFER_SIZE) {
        ESP_LOGW(TAG, "Audio mixer overflow (%d)", count);
        xSemaphoreGive(mixer->sync_sem);
        return;
    }

    Int16* buffer = mixer->buffer;

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
    
    memset(mixer->mixBuffer, 0, sizeof(mixer->mixBuffer));

    // Set samples to mix for tasks
    mixer->samplesToMix = count;

    // Start mixing tasks
    for (int i = 0; i < 2; i++) {
        xSemaphoreGive(mixer->taskData[i].semStart);
    }
    taskYIELD();
    // Wait for mixing tasks to finish
    for (int i = 0; i < 2; i++) {
        xSemaphoreTake(mixer->taskData[i].semDone, portMAX_DELAY);
    }

    // Set to zero, will generate an error when tasks are used incorrectly
    mixer->samplesToMix = 0;

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

        for (int i = 0; i < mixer->channelCount; i++) {
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

void mixerSetEnable(Mixer* mixer, bool enable)
{
    if (!mixer->enable && enable) {
        // Start the audio tasks
        mixer->enable = true;
        xTaskCreatePinnedToCore(MixerTask, "audio_mixer_0", 4096, &mixer->taskData[0], 5, NULL, 0);
        xTaskCreatePinnedToCore(MixerTask, "audio_mixer_1", 4096, &mixer->taskData[1], 5, NULL, 1);
    }
    if (mixer->enable && !enable) {
        // Stop the audio tasks
        mixer->enable = false;
        for (int i = 0; i < 2; i++) {
            xSemaphoreGive(mixer->taskData[i].semStart);
        }
        for (int i = 0; i < 2; i++) {
            xSemaphoreTake(mixer->taskData[i].semDone, portMAX_DELAY);
        }
    }
}
