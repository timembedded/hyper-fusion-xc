/*****************************************************************************
**  MSX I/O extender, emulating:
**    - AY8910 - PSG
**    - YM2413 - MSX-MUSIC
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

#include <freertos/FreeRTOS.h>
#include <sdkconfig.h>
#include <esp_log.h>

#include "i2s.h"
#include "fpga.h"
#include "audiodev.h"

static const char TAG[] = "main";

static i2s_chan_handle_t tx_handle;
static i2s_chan_handle_t rx_handle;
static audiodev_handle_t audiodev;
static fpga_handle_t fpga;

static void i2s_read_input_callback(void* arg, int16_t* buffer, uint32_t count)
{
    size_t bytes_done = 0;
    esp_err_t ret = i2s_channel_read(rx_handle, buffer, count * sizeof(int16_t), &bytes_done, 0);
    if (ret != ESP_OK && ret != ESP_ERR_TIMEOUT) {
        ESP_LOGE(TAG, "i2s read failed");
    }
    if (bytes_done != count * sizeof(int16_t)) {
        ESP_LOGW(TAG, "i2s read mismatch: requested %d bytes, got %d bytes", count * sizeof(int16_t), bytes_done);
        memset(buffer + bytes_done, 0, count * sizeof(int16_t) - bytes_done);
    }
}

static uint32_t i2s_write_output_callback(void* arg, int16_t* buffer, uint32_t count)
{
    size_t bytes_done = 0;

    esp_err_t ret = i2s_channel_write(tx_handle, buffer, count * sizeof(int16_t), &bytes_done, 0);
    if (ret != ESP_OK && ret != ESP_ERR_TIMEOUT) {
        ESP_LOGE(TAG, "i2s write failed");
        return 0;
    }

    return bytes_done / sizeof(int16_t);
}

void reset_callback(void* ref)
{
    audiodev_handle_t audiodev = (audiodev_handle_t)ref;
    audiodev_stop(audiodev);
    audiodev_start(audiodev);
}

void ipc_main(void)
{
    i2s_init(&tx_handle, &rx_handle);

    fpga = fpga_create();
    if (fpga == NULL)
        return;

    audiodev = audiodev_create(fpga, i2s_read_input_callback, i2s_write_output_callback);

    fpga_set_reset_callback(fpga, reset_callback, audiodev);
}

void app_main(void)
{
    ipc_main();

    while (1) {
        vTaskDelay(100);
    }
}
