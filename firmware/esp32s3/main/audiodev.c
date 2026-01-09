/*****************************************************************************
**  MSX Audio Device Emulation
**
**    AY8910 - PSG
**    YM2413 - MSX-MUSIC
**
**  Copyright (C) 2025 Tim Brugman
**
**  This program is free software; you can redistribute it and/or modify
**  it under the terms of the GNU General Public License as published by
**  the Free Software Foundation; either version 2 of the License, or
**  (at your option) any later version.
** 
**  This program is distributed in the hope that it will be useful,
**  but WITHOUT ANY WARRANTY; without even the implied warranty of
**  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
**  GNU General Public License for more details.
**
**  You should have received a copy of the GNU General Public License
**  along with this program; if not, write to the Free Software
**  Foundation, Inc., 675 Mass Ave, Cambridge, MA 02139, USA.
**
******************************************************************************/
#include "audiodev.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <freertos/FreeRTOS.h>
#include <esp_log.h>

#include "emutimer.h"

#include "bluemsx/Board.h"
#include "bluemsx/IoPort.h"
#include "bluemsx/AudioMixer.h"
#include "bluemsx/AY8910.h"
#include "bluemsx/YM2413.h"
#include "bluemsx/MsxAudio.h"
#include "bluemsx/Moonsound.h"

static const char TAG[] = "audiodev";

/// Audio devices data
struct audiodev_t {
    fpga_handle_t fpga_handle;
    read_input_callback_t read_input_callback;
    write_output_callback_t write_output_callback;
    int16_t inputBuffer[AUDIO_STEREO_BUFFER_SIZE];
    SemaphoreHandle_t mixer_sem;
    emutimer_handle_t timer_mixer;
    bool mixer_reset;
    bool use_stereo;
    Mixer *mixer;
    AY8910 *psg;
    YM_2413 *ym2413;
    MsxAudioHndl msxaudio;
    Moonsound *moonsound;
};
typedef struct audiodev_t audiodev_t;

static void audio_mixer_task(void *args);

static void io_register_callback(uint8_t port, IoPortProperties_t prop, void* ref)
{
    fpga_io_register((fpga_handle_t)ref, port, prop);
}

static void io_unregister_callback(uint8_t port, void* ref)
{
    fpga_io_unregister((fpga_handle_t)ref, port);
}

static void irq_set_callback(void *ref)
{
    fpga_irq_set((fpga_handle_t)ref);
}

static void irq_clear_callback(void *ref)
{
    fpga_irq_reset((fpga_handle_t)ref);
}

audiodev_handle_t audiodev_create(fpga_handle_t fpga_handle, read_input_callback_t read_callback, write_output_callback_t write_callback)
{
    // Allocate data
    audiodev_t *audiodev = (audiodev_t *)calloc(1, sizeof(audiodev_t));

    audiodev->fpga_handle = fpga_handle;
    audiodev->read_input_callback = read_callback;
    audiodev->write_output_callback = write_callback;

    // Setup 'Board' IRQ callbacks
    boardSetIrqCallbacks(irq_set_callback, irq_clear_callback, fpga_handle);

    // Init IoPort manager
    ioPortInit(io_register_callback, io_unregister_callback, fpga_handle);

    // Init mixer mutex
    audiodev->mixer_sem = xSemaphoreCreateBinary();
    assert(audiodev->mixer_sem != NULL);

    // Start the audio task
    xTaskCreatePinnedToCore(audio_mixer_task, "audio_mixer_task", 4096, audiodev, 6, NULL, 0);

    // Start mixer
    audiodev_start(audiodev);

    return audiodev;
}

static uint32_t IRAM_ATTR mixer_get_samples_callback(void *ref)
{
    audiodev_handle_t audiodev = (audiodev_handle_t)ref;

    // Get the amount of samples to generate
    uint32_t count = timer_get_duration(audiodev->timer_mixer);
    if (count >= AUDIO_MONO_BUFFER_SIZE/4) {
        ESP_LOGI(TAG, "mix %d", count);
        if (count > AUDIO_MONO_BUFFER_SIZE/2) {
            count = AUDIO_MONO_BUFFER_SIZE/2;
        }
    }

    return count;
}

static Int32 IRAM_ATTR mixer_write_output_callback(void* arg, Int16* buffer, UInt32 count)
{
    audiodev_handle_t audiodev = (audiodev_handle_t)arg;
    return audiodev->write_output_callback(arg, buffer, count);
}

static Int32* fpga_input_sync(void* ref, Int32 *buffer, UInt32 count) 
{
    audiodev_handle_t audiodev = (audiodev_handle_t)ref;

    (void)audiodev->read_input_callback(audiodev->fpga_handle, audiodev->inputBuffer, count * 2);
    for (UInt32 i = 0; i < count * 2; i++) {
        buffer[i] = audiodev->inputBuffer[i];
    }

#if 1
    static Int16 minsampl = 0;
    static Int16 maxsampl = 0;
    static Int16 minsampr = 0;
    static Int16 maxsampr = 0;
    bool report = false;
    for (UInt32 i = 0; i < count * 2; i+=2) {
        if (buffer[i] < minsampl) {
            minsampl = buffer[i];
            report = true;
        }
        if (buffer[i] > maxsampl) {
            maxsampl = buffer[i];
            report = true;
        }
        if (buffer[i+1] < minsampr) {
            minsampr = buffer[i+1];
            report = true;
        }
        if (buffer[i+1] > maxsampr) {
            maxsampr = buffer[i+1];
            report = true;
        }
    }
    if (report) {
        ESP_LOGI(TAG, "Input sample range: left: %d .. %d, right %d .. %d", minsampl, maxsampl, minsampr, maxsampr);
    }
#endif
    return buffer;
}

void audiodev_stop(audiodev_handle_t audiodev)
{
    // Stop mixer thread
    xSemaphoreTake(audiodev->mixer_sem, portMAX_DELAY);
    mixerSetEnable(audiodev->mixer, false);

    // Remove timers
    timer_destroy(audiodev->timer_mixer);

    // Disable FPGA IO handling
    fpga_io_stop(audiodev->fpga_handle);

    // Cleanup
    if (audiodev->moonsound) {
        moonsoundDestroy(audiodev->moonsound);
        audiodev->moonsound = NULL;
    }
    if (audiodev->msxaudio) {
        msxaudioDestroy(audiodev->msxaudio);
        audiodev->msxaudio = NULL;
    }
    if (audiodev->ym2413) {
        ym2413Destroy(audiodev->ym2413);
        audiodev->ym2413 = NULL;
    }
    if (audiodev->psg) {
        ay8910Destroy(audiodev->psg);
        audiodev->psg = NULL;
    }
    if (audiodev->mixer) {
        mixerDestroy(audiodev->mixer);
        audiodev->mixer = NULL;
    }
}

extern const uint8_t moonsound_rom_start[] asm("_binary_MOONSOUND_rom_start");
extern const uint8_t moonsound_rom_end[]   asm("_binary_MOONSOUND_rom_end");

void audiodev_start(audiodev_handle_t audiodev)
{
    // Reset the I/O ports
    fpga_io_reset(audiodev->fpga_handle);

    // Create timers
    audiodev->timer_mixer = timer_create(AUDIO_SAMPLERATE);

    // Create mixer
    audiodev->mixer = mixerCreate(mixer_get_samples_callback, audiodev, 128);

    // By default use MSX-MUSIC separately MSX-AUDIO (mono)
    audiodev->use_stereo = false;

    // Create sound chips
    audiodev->psg = ay8910Create(audiodev->mixer, AY8910_MSX, PSGTYPE_AY8910);
    audiodev->ym2413 = ym2413Create(audiodev->mixer);
    audiodev->msxaudio = msxaudioCreate(audiodev->mixer);
    audiodev->moonsound = moonsoundCreate(audiodev->mixer, (uint8_t*)moonsound_rom_start, ((uint8_t*)moonsound_rom_end - (uint8_t*)moonsound_rom_start), 1024);

    // Connect I2S input from FPGA to mixer
    mixerRegisterChannel(audiodev->mixer, 0, MIXER_CHANNEL_KEYCLICK, MIXER_CHANNEL_SCC, false, fpga_input_sync, audiodev);

    // Basic mixer configuration
    mixerSetWriteCallback(audiodev->mixer, mixer_write_output_callback, audiodev);
    mixerSetMasterVolume(audiodev->mixer, 100);
    mixerEnableMaster(audiodev->mixer, 1);

    // Set volumes
    mixerSetChannelTypeVolume(audiodev->mixer, MIXER_CHANNEL_KEYCLICK, 100);
    mixerSetChannelTypeVolume(audiodev->mixer, MIXER_CHANNEL_SCC, 100);
    mixerSetChannelTypeVolume(audiodev->mixer, MIXER_CHANNEL_PSG, 100);
    mixerSetChannelTypeVolume(audiodev->mixer, MIXER_CHANNEL_MSXMUSIC_VOICE, 100);
    mixerSetChannelTypeVolume(audiodev->mixer, MIXER_CHANNEL_MSXMUSIC_DRUM, 100);
    mixerSetChannelTypeVolume(audiodev->mixer, MIXER_CHANNEL_MSXAUDIO_VOICE, 100);
    mixerSetChannelTypeVolume(audiodev->mixer, MIXER_CHANNEL_MSXAUDIO_DRUM, 100);
    mixerSetChannelTypeVolume(audiodev->mixer, MIXER_CHANNEL_YMF262, 100);
    mixerSetChannelTypeVolume(audiodev->mixer, MIXER_CHANNEL_YMF278, 100);

    // Set panning
    mixerSetChannelTypePan(audiodev->mixer, MIXER_CHANNEL_KEYCLICK, 50);
    mixerSetChannelTypePan(audiodev->mixer, MIXER_CHANNEL_SCC, 50);
    mixerSetChannelTypePan(audiodev->mixer, MIXER_CHANNEL_PSG, 50);
    mixerSetChannelTypePan(audiodev->mixer, MIXER_CHANNEL_MSXMUSIC_VOICE, 50);
    mixerSetChannelTypePan(audiodev->mixer, MIXER_CHANNEL_MSXMUSIC_DRUM, 50);
    mixerSetChannelTypePan(audiodev->mixer, MIXER_CHANNEL_MSXAUDIO_VOICE, 50);
    mixerSetChannelTypePan(audiodev->mixer, MIXER_CHANNEL_MSXAUDIO_DRUM, 50);
    mixerSetChannelTypePan(audiodev->mixer, MIXER_CHANNEL_YMF262, 50);
    mixerSetChannelTypePan(audiodev->mixer, MIXER_CHANNEL_YMF278, 50);

    // Enable all channels
    mixerEnableChannelType(audiodev->mixer, MIXER_CHANNEL_KEYCLICK, 1);
    mixerEnableChannelType(audiodev->mixer, MIXER_CHANNEL_SCC, 1);
    mixerEnableChannelType(audiodev->mixer, MIXER_CHANNEL_PSG, 1);
    mixerEnableChannelType(audiodev->mixer, MIXER_CHANNEL_MSXMUSIC_VOICE, 1);
    mixerEnableChannelType(audiodev->mixer, MIXER_CHANNEL_MSXMUSIC_DRUM, 1);
    mixerEnableChannelType(audiodev->mixer, MIXER_CHANNEL_MSXAUDIO_VOICE, 1);
    mixerEnableChannelType(audiodev->mixer, MIXER_CHANNEL_MSXAUDIO_DRUM, 1);
    mixerEnableChannelType(audiodev->mixer, MIXER_CHANNEL_YMF262, 1);
    mixerEnableChannelType(audiodev->mixer, MIXER_CHANNEL_YMF278, 1);

    // Pre-fill I2S buffer
    Int16 buffer[128];
    int written = 0;
    memset(buffer, 0, sizeof(buffer));
    for(int i = 0; i < 8; i++) {
        written += mixer_write_output_callback(audiodev, buffer, sizeof(buffer) / sizeof(Int16));
    }
    ESP_LOGI(TAG, "Pre-filled %d samples", written);

    // Enable mixer
    mixerSetEnable(audiodev->mixer, true);

    // Start mixer thread
    audiodev->mixer_reset = true;
    xSemaphoreGive(audiodev->mixer_sem);
}

static void IRAM_ATTR audio_mixer_task(void *args)
{
    audiodev_handle_t audiodev = (audiodev_handle_t)args;
    uint32_t tdiffprev = 0, tdiffprev2 = 0;
    uint32_t loadmax = 0;

    // Audio mixing loop
    for(;;) {
        xSemaphoreTake(audiodev->mixer_sem, portMAX_DELAY);

        // Handle reset
        if (audiodev->mixer_reset) {
            // Reset timer and warm-up caches
            timer_reset(audiodev->timer_mixer);
            xSemaphoreGive(audiodev->mixer_sem);
            vTaskDelay(2);
            xSemaphoreTake(audiodev->mixer_sem, portMAX_DELAY);
            mixerSync(audiodev->mixer);
            audiodev->mixer_reset = false;
            xSemaphoreGive(audiodev->mixer_sem);
            continue;
        }

        // Mix audio
        uint32_t tbefore = xTaskGetTickCount();
        mixerSync(audiodev->mixer);
        uint32_t tafter = xTaskGetTickCount();
        xSemaphoreGive(audiodev->mixer_sem);

        // Automatically switch between mono and stereo mode for MSX-MUSIC+MSX-AUDIO
        bool msx_music_active = audiodev->ym2413 && !ym2413IsMuted(audiodev->ym2413);
        bool msx_audio_active = audiodev->msxaudio && !msxaudioIsMuted(audiodev->msxaudio);
        if (msx_music_active || msx_audio_active) {
            bool use_stereo = msx_music_active && msx_audio_active;
            if (use_stereo != audiodev->use_stereo) {
                audiodev->use_stereo = use_stereo;
                if (use_stereo) {
                    ESP_LOGI(TAG, "Switching to stereo mode for MSX-MUSIC + MSX-AUDIO");
                    mixerSetChannelTypePan(audiodev->mixer, MIXER_CHANNEL_MSXMUSIC_VOICE, 0);
                    mixerSetChannelTypePan(audiodev->mixer, MIXER_CHANNEL_MSXAUDIO_VOICE, 100);
                } else {
                    ESP_LOGI(TAG, "Switching to mono mode for MSX-MUSIC + MSX-AUDIO");
                    mixerSetChannelTypePan(audiodev->mixer, MIXER_CHANNEL_MSXMUSIC_VOICE, 50);
                    mixerSetChannelTypePan(audiodev->mixer, MIXER_CHANNEL_MSXAUDIO_VOICE, 50);
                }
            }
        }

        // Calculate and report CPU load
        uint32_t tdiff = tafter - tbefore;
        if (tdiff != tdiffprev) {
            bool report = true;
            if (tdiff == tdiffprev2) {
                report = false;
            }
            if (tdiff > loadmax) {
                loadmax = tdiff;
                report = true;
            }
            if (report) {
                if (tdiffprev != tdiff) {
                    tdiffprev2 = tdiffprev;
                    tdiffprev = tdiff;
                }
                printf("Mixer CPU Load: %lu, max = %lu\n", tdiff, loadmax);
            }
        }

        // Yield to other tasks
        vTaskDelay(1);
    }
    vTaskDelete(NULL);
}
