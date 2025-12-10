/*****************************************************************************
** $Source: /cvsroot/bluemsx/blueMSX/Src/SoundChips/MsxAudio.cpp,v $
**
** $Revision: 1.8 $
**
** $Date: 2006/09/21 04:28:08 $
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
#include "MsxAudio.h"

#include <string.h>
#include "esp_log.h"

#include "OpenMsxY8950.h"
#include "IoPort.h"

#define FREQUENCY        3579545
 
#define OFFSETOF(s, a) ((int)(&((s*)0)->a))

struct MsxAudio {
    MsxAudio() :
        timer1(0), timerRef1(-1), timer2(0), timerRef2(-1) {
        memset(defaultBuffer, 0, sizeof(defaultBuffer));
    }

    Mixer* mixer;
    Int32  handle;

    Y8950* y8950;
    Int32  buffer[AUDIO_MONO_BUFFER_SIZE];
    Int32  defaultBuffer[AUDIO_MONO_BUFFER_SIZE];
    UInt32 timer1;
    UInt32 counter1;
    UInt8  timerRef1;
    UInt32 timer2;
    UInt32 counter2;
    UInt8  timerRef2;
    UInt8  registerLatch;
 };

MsxAudio* theMsxAudio = NULL;


extern "C" Int32* msxaudioSync(void* ref, UInt32 count) 
{
    MsxAudio* msxaudio = (MsxAudio*)ref;
    Int32* genBuf = NULL;

    genBuf = (Int32*)msxaudio->y8950->updateBuffer(count);
    if (genBuf == NULL) {
        genBuf = msxaudio->defaultBuffer;
    }
    return genBuf;
}

void msxaudioTimerSet(int timer, int count)
{
    if (timer == 1) {
        if (theMsxAudio->counter1 != -1) {
            theMsxAudio->counter1 = count;
        }
        theMsxAudio->timer1 = count;
    }
    else {
        if (theMsxAudio->counter2 != -1) {
            theMsxAudio->counter2 = count;
        }
        theMsxAudio->timer2 = count;
    }
}

void msxaudioTimerStart(int timer, int start, UInt8 ref)
{
    if (timer == 1) {
        theMsxAudio->timerRef1 = ref;
        theMsxAudio->counter1  = start ? theMsxAudio->timer1 : -1;
    }
    else {
        theMsxAudio->timerRef2 = ref;
        theMsxAudio->counter2  = start ? theMsxAudio->timer2 : -1;
    }
}

extern "C" void msxaudioTick(UInt32 elapsedTime) // 12.5 kHz timebase
{
    if (theMsxAudio != NULL) {
        while (elapsedTime--) {
            if (theMsxAudio->counter1 != -1) {
                if (theMsxAudio->counter1-- == 0) {
                    theMsxAudio->counter1 = theMsxAudio->timer1;
                    theMsxAudio->y8950->callback(theMsxAudio->timerRef1);
                }
            }

            if (theMsxAudio->counter2 != -1) {
                if (theMsxAudio->counter2-- == 0) {
                    theMsxAudio->counter2 = theMsxAudio->timer2;
                    theMsxAudio->y8950->callback(theMsxAudio->timerRef2);
                }
            }
        }
    }
}

extern "C" void msxaudioDestroy(MsxAudioHndl rm) {
    MsxAudio* msxaudio = (MsxAudio*)rm;

    ioPortUnregister(0xc0);
    ioPortUnregister(0xc1);

    mixerUnregisterChannel(msxaudio->mixer, msxaudio->handle);
    theMsxAudio = NULL;

    delete msxaudio->y8950;
}


extern "C" UInt8 msxaudioRead(MsxAudio* msxaudio, UInt16 ioPort)
{
    UInt8 result = 0xff;

    switch (ioPort & 0x01) {
    case 0:
        result = msxaudio->y8950->readStatus();
        Y8950Log(Y8950LogLevel_Debug, "s[%x]\n", result);
        break;
    case 1:
        mixerSync(msxaudio->mixer);
        result = msxaudio->y8950->readReg(msxaudio->registerLatch);
        Y8950Log(Y8950LogLevel_Debug, "[%x]->%x\n", msxaudio->registerLatch, result);
        break;
    }
    return result;
}

extern "C" void msxaudioWrite(MsxAudio* msxaudio, UInt16 ioPort, UInt8 value) 
{
    switch (ioPort & 0x01) {
    case 0:
        msxaudio->registerLatch = value;
        break;
    case 1:
        Y8950Log(Y8950LogLevel_Debug, "[%x]=%x\n", msxaudio->registerLatch, value);
        mixerSync(msxaudio->mixer);
        msxaudio->y8950->writeReg(msxaudio->registerLatch, value);
        break;
    }
}

extern "C" MsxAudioHndl msxaudioCreate(Mixer* mixer)
{
    MsxAudio* msxaudio = new MsxAudio;

    theMsxAudio = msxaudio;

    msxaudio->mixer = mixer;
    msxaudio->counter1 = -1;
    msxaudio->counter2 = -1;
    msxaudio->registerLatch = 0;

    msxaudio->handle = mixerRegisterChannel(mixer, MIXER_CHANNEL_MSXAUDIO, 0, msxaudioSync, msxaudio);

    msxaudio->y8950 = new Y8950("MsxAudio", 256*1024);
    msxaudio->y8950->setSampleRate(AUDIO_SAMPLERATE, boardGetY8950Oversampling);
    msxaudio->y8950->setVolume(32767);

    ioPortRegister(0xc0, (IoPortRead)msxaudioRead, (IoPortWrite)msxaudioWrite, msxaudio);
    ioPortRegister(0xc1, (IoPortRead)msxaudioRead, (IoPortWrite)msxaudioWrite, msxaudio);

    return (MsxAudioHndl)msxaudio;
}

// TODO
// --------------------------------------

// Not sure what these functions should do

extern "C" int switchGetAudio()
{
    return 0;
}
