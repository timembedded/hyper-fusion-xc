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
    write_samples_callback_t write_samples_callback;
    SemaphoreHandle_t mixer_sem;
    emutimer_handle_t timer_mixer;
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

audiodev_handle_t audiodev_create(fpga_handle_t fpga_handle, write_samples_callback_t callback)
{
    // Allocate data
    audiodev_t *audiodev = (audiodev_t *)calloc(1, sizeof(audiodev_t));

    audiodev->fpga_handle = fpga_handle;
    audiodev->write_samples_callback = callback;

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
    if (count >= 1000) {
        ESP_LOGI(TAG, "mix %d", count);
    }

    return count;
}

static Int32 IRAM_ATTR mixer_write_samples_callback(void* arg, Int16* buffer, UInt32 count)
{
    audiodev_handle_t audiodev = (audiodev_handle_t)arg;
    return audiodev->write_samples_callback(arg, buffer, count);
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

    // Create sound chips
    audiodev->psg = ay8910Create(audiodev->mixer, AY8910_MSX, PSGTYPE_AY8910);
    audiodev->ym2413 = ym2413Create(audiodev->mixer);
    audiodev->msxaudio = msxaudioCreate(audiodev->mixer);
    audiodev->moonsound = moonsoundCreate(audiodev->mixer, (uint8_t*)moonsound_rom_start, ((uint8_t*)moonsound_rom_end - (uint8_t*)moonsound_rom_start), 1024);

    // Configure mixer
    mixerSetWriteCallback(audiodev->mixer, mixer_write_samples_callback, audiodev);
    mixerSetMasterVolume(audiodev->mixer, 100);
    mixerEnableMaster(audiodev->mixer, 1);
    mixerSetChannelTypeVolume(audiodev->mixer, MIXER_CHANNEL_PSG, 100);
    mixerSetChannelTypeVolume(audiodev->mixer, MIXER_CHANNEL_MSXMUSIC, 100);
    mixerSetChannelTypeVolume(audiodev->mixer, MIXER_CHANNEL_MSXAUDIO, 100);
    mixerSetChannelTypeVolume(audiodev->mixer, MIXER_CHANNEL_YMF262, 100);
    mixerSetChannelTypeVolume(audiodev->mixer, MIXER_CHANNEL_YMF278, 100);
    mixerSetChannelTypePan(audiodev->mixer, MIXER_CHANNEL_PSG, 50);
    mixerSetChannelTypePan(audiodev->mixer, MIXER_CHANNEL_MSXMUSIC, 0);
    mixerSetChannelTypePan(audiodev->mixer, MIXER_CHANNEL_MSXAUDIO, 100);
    mixerSetChannelTypePan(audiodev->mixer, MIXER_CHANNEL_YMF262, 50);
    mixerSetChannelTypePan(audiodev->mixer, MIXER_CHANNEL_YMF278, 50);
    mixerEnableChannelType(audiodev->mixer, MIXER_CHANNEL_PSG, 1);
    mixerEnableChannelType(audiodev->mixer, MIXER_CHANNEL_MSXMUSIC, 1);
    mixerEnableChannelType(audiodev->mixer, MIXER_CHANNEL_MSXAUDIO, 1);
    mixerEnableChannelType(audiodev->mixer, MIXER_CHANNEL_YMF262, 1);
    mixerEnableChannelType(audiodev->mixer, MIXER_CHANNEL_YMF278, 1);

    // Pre-fill I2S buffer
    Int16 buffer[128];
    int written = 0;
    memset(buffer, 0, sizeof(buffer));
    for(int i = 0; i < 8; i++) {
        written += mixer_write_samples_callback(audiodev, buffer, sizeof(buffer) / sizeof(Int16));
    }
    ESP_LOGI(TAG, "Pre-filled %d samples", written);

    // Enable mixer
    mixerSetEnable(audiodev->mixer, true);

    // Reset timers
    timer_reset(audiodev->timer_mixer);

    // Start mixer thread
    xSemaphoreGive(audiodev->mixer_sem);
}

static void IRAM_ATTR audio_mixer_task(void *args)
{
    audiodev_handle_t audiodev = (audiodev_handle_t)args;
    uint32_t tdiffprev = 0;

    /* Enable the TX channel */
    while (1) {
        xSemaphoreTake(audiodev->mixer_sem, portMAX_DELAY);
        uint32_t tbefore = xTaskGetTickCount();
        mixerSync(audiodev->mixer);
        uint32_t tafter = xTaskGetTickCount();
        xSemaphoreGive(audiodev->mixer_sem);

        uint32_t tdiff = tafter - tbefore;
        if (tdiff != tdiffprev) {
            tdiffprev = tdiff;
            printf("Mixer CPU Load: %lu\n", tdiff);
        }
        vTaskDelay(1);
    }
    vTaskDelete(NULL);
}
