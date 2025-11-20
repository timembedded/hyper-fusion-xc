/*
 * SPDX-FileCopyrightText: 2021-2025 Espressif Systems (Shanghai) CO LTD
 *
 * SPDX-License-Identifier: CC0-1.0
 */

#include <stdio.h>
#include <string.h>
#include "sdkconfig.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "driver/i2s_std.h"
#include "driver/gpio.h"
#include "esp_system.h"
#include "esp_codec_dev_defaults.h"
#include "esp_codec_dev.h"
#include "esp_codec_dev_vol.h"
#include "esp_check.h"
#include "dac.h"

#define CONFIG_I2S_MODE_MUSIC   1   // 1 to play audio
#define CONFIG_I2S_MODE_ECHO    0   // 1 to enable echo mode

/* Example configurations */
#define I2S_RECV_BUF_SIZE   (2400)
#define I2S_SAMPLE_RATE     (22050)
#define I2S_MCLK_MULTIPLE   (384) // If not using 24-bit data width, 256 should be enough
#define I2S_MCLK_FREQ_HZ    (I2S_SAMPLE_RATE * I2S_MCLK_MULTIPLE)

/* I2S port and GPIOs */
#define I2S_NUM         (0)
#define I2S_MCK_IO      18
#define I2S_BCK_IO      8
#define I2S_WS_IO       3
#define I2S_DO_IO       46
#define I2S_DI_IO       9

static const char *TAG = "i2s_dac";
static const char err_reason[][30] = {"input param is invalid",
                                      "operation timeout"
                                     };

/* Import music file as buffer */
#if CONFIG_I2S_MODE_MUSIC
extern const uint8_t music_pcm_start[] asm("_binary_canon_pcm_start");
extern const uint8_t music_pcm_end[]   asm("_binary_canon_pcm_end");
#endif

static esp_err_t dac_codec_init(i2s_chan_handle_t tx_handle, i2s_chan_handle_t rx_handle)
{
    /* Create data interface with I2S bus handle */
    audio_codec_i2s_cfg_t i2s_cfg = {
        .port = I2S_NUM,
        .rx_handle = rx_handle,
        .tx_handle = tx_handle,
    };
    const audio_codec_data_if_t *data_if = audio_codec_new_i2s_data(&i2s_cfg);
    assert(data_if);

    /* Create DAC interface handle */
    dac_codec_cfg_t dac_cfg = {
        .codec_mode = ESP_CODEC_DEV_WORK_MODE_BOTH,
        .master_mode = false,
        .use_mclk = I2S_MCK_IO >= 0,
        .mclk_div = I2S_MCLK_MULTIPLE,
    };
    const audio_codec_if_t *dac_if = dac_codec_new(&dac_cfg);
    assert(dac_if);

    /* Create the top codec handle with DAC interface handle and data interface */
    esp_codec_dev_cfg_t dev_cfg = {
        .dev_type = ESP_CODEC_DEV_TYPE_IN_OUT,
        .codec_if = dac_if,
        .data_if = data_if,
    };
    esp_codec_dev_handle_t codec_handle = esp_codec_dev_new(&dev_cfg);
    assert(codec_handle);

    /* Specify the sample configurations and open the device */
    esp_codec_dev_sample_info_t sample_cfg = {
        .bits_per_sample = I2S_DATA_BIT_WIDTH_16BIT,
        .channel = 2,
        .channel_mask = 0x03,
        .sample_rate = I2S_SAMPLE_RATE,
    };
    if (esp_codec_dev_open(codec_handle, &sample_cfg) != ESP_CODEC_DEV_OK) {
        ESP_LOGE(TAG, "Open codec device failed");
        return ESP_FAIL;
    }

    return ESP_OK;
}

static esp_err_t i2s_driver_init(i2s_chan_handle_t *tx_handle, i2s_chan_handle_t *rx_handle)
{
    i2s_chan_config_t chan_cfg = I2S_CHANNEL_DEFAULT_CONFIG(I2S_NUM, I2S_ROLE_MASTER);
    chan_cfg.auto_clear = true; // Auto clear the legacy data in the DMA buffer
    ESP_ERROR_CHECK(i2s_new_channel(&chan_cfg, tx_handle, rx_handle));
    i2s_std_config_t std_cfg = {
        .clk_cfg = I2S_STD_CLK_DEFAULT_CONFIG(I2S_SAMPLE_RATE),
        .slot_cfg = I2S_STD_PHILIPS_SLOT_DEFAULT_CONFIG(I2S_DATA_BIT_WIDTH_16BIT, I2S_SLOT_MODE_STEREO),
        .gpio_cfg = {
            .mclk = I2S_MCK_IO,
            .bclk = I2S_BCK_IO,
            .ws = I2S_WS_IO,
            .dout = I2S_DO_IO,
            .din = I2S_DI_IO,
            .invert_flags = {
                .mclk_inv = false,
                .bclk_inv = false,
                .ws_inv = false,
            },
        },
    };
    std_cfg.clk_cfg.mclk_multiple = I2S_MCLK_MULTIPLE;

    ESP_ERROR_CHECK(i2s_channel_init_std_mode(*tx_handle, &std_cfg));
    ESP_ERROR_CHECK(i2s_channel_init_std_mode(*rx_handle, &std_cfg));
    ESP_ERROR_CHECK(i2s_channel_enable(*tx_handle));
    ESP_ERROR_CHECK(i2s_channel_enable(*rx_handle));
    return ESP_OK;
}

#if CONFIG_I2S_MODE_MUSIC
static void i2s_music(void *args)
{
    i2s_chan_handle_t tx_handle = args;
    esp_err_t ret = ESP_OK;
    size_t bytes_write = 0;
    uint8_t *data_ptr = (uint8_t *)music_pcm_start;

    /* (Optional) Disable TX channel and preload the data before enabling the TX channel,
     * so that the valid data can be transmitted immediately */
    ESP_ERROR_CHECK(i2s_channel_disable(tx_handle));
    ESP_ERROR_CHECK(i2s_channel_preload_data(tx_handle, data_ptr, music_pcm_end - data_ptr, &bytes_write));
    data_ptr += bytes_write;  // Move forward the data pointer

    /* Enable the TX channel */
    ESP_ERROR_CHECK(i2s_channel_enable(tx_handle));

    /* Write music to earphone */
    ret = i2s_channel_write(tx_handle, data_ptr, music_pcm_end - data_ptr, &bytes_write, portMAX_DELAY);
    if (ret != ESP_OK) {
        /* Since we set timeout to 'portMAX_DELAY' in 'i2s_channel_write'
            so you won't reach here unless you set other timeout value,
            if timeout detected, it means write operation failed. */
        ESP_LOGE(TAG, "[music] i2s write failed, %s", err_reason[ret == ESP_ERR_TIMEOUT]);
        abort();
    }
    if (bytes_write > 0) {
        ESP_LOGI(TAG, "[music] i2s music played, %d bytes are written.", bytes_write);
    } else {
        ESP_LOGE(TAG, "[music] i2s music play failed.");
        abort();
    }

    vTaskDelete(NULL);
}
#endif

void i2s_play_music(i2s_chan_handle_t tx_handle)
{
#if CONFIG_I2S_MODE_MUSIC
    /* Play a piece of music in music mode */
    xTaskCreate(i2s_music, "i2s_music", 4096, tx_handle, 5, NULL);
#endif
}

void i2s_init(i2s_chan_handle_t *tx_handle, i2s_chan_handle_t *rx_handle)
{
    printf("i2s dac codec start\n-----------------------------\n");
    /* Initialize i2s peripheral */
    if (i2s_driver_init(tx_handle, rx_handle) != ESP_OK) {
        ESP_LOGE(TAG, "i2s driver init failed");
        abort();
    } else {
        ESP_LOGI(TAG, "i2s driver init success");
    }
    /* Initialize i2c peripheral and config dac codec by i2c */
    if (dac_codec_init(*tx_handle, *rx_handle) != ESP_OK) {
        ESP_LOGE(TAG, "dac codec init failed");
        abort();
    } else {
        ESP_LOGI(TAG, "dac codec init success");
    }
}
