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
    Mixer* mixer;
    Int32  handle;
    Y8950* y8950;
    UInt8  registerLatch;
};


extern "C" Int32* msxaudioSync(void* ref, Int32 *buffer, UInt32 count) 
{
    MsxAudio* msxaudio = (MsxAudio*)ref;
    return (Int32*)msxaudio->y8950->updateBuffer((int*)buffer, count);
}


extern "C" void msxaudioDestroy(MsxAudioHndl rm) {
    MsxAudio* msxaudio = (MsxAudio*)rm;

    ioPortUnregister(0xc0);
    ioPortUnregister(0xc1);

    mixerUnregisterChannel(msxaudio->mixer, msxaudio->handle);

    delete msxaudio->y8950;
    delete msxaudio;
}


extern "C" UInt8 msxaudioRead(MsxAudio* msxaudio, UInt16 /*ioPort*/)
{
    mixerSync(msxaudio->mixer);
    UInt8 result = msxaudio->y8950->readReg(msxaudio->registerLatch);
    Y8950Log(Y8950LogLevel_Debug, "[%x]->%x\n", msxaudio->registerLatch, result);

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

    msxaudio->mixer = mixer;
    msxaudio->registerLatch = 0;

    msxaudio->handle = mixerRegisterChannel(mixer, 0, MIXER_CHANNEL_MSXAUDIO, 0, msxaudioSync, msxaudio);

    msxaudio->y8950 = new Y8950(256*1024);
    msxaudio->y8950->setSampleRate(AUDIO_SAMPLERATE, boardGetY8950Oversampling);
    msxaudio->y8950->setVolume(32767);

    ioPortRegister(0xc0, NULL, (IoPortWrite)msxaudioWrite, msxaudio);
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
