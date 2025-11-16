/*
 * SPDX-FileCopyrightText: 2023 Espressif Systems (Shanghai) CO LTD
 *
 * SPDX-License-Identifier: Apache-2.0
 */
#include <string.h>
#include "dac.h"
#include "esp_log.h"
#include "../managed_components/espressif__esp_codec_dev/device/priv_include/es_common.h"

#define TAG          "DAC"

typedef struct {
    audio_codec_if_t   base;
    dac_codec_cfg_t cfg;
    bool               is_open;
    bool               enabled;
    float              hw_gain;
} audio_codec_dac_t;

typedef struct {
    audio_codec_dac_t *adc;
    audio_codec_dac_t *dac;
} paired_adc_codec_t;

static paired_adc_codec_t paired_adc;

static inline bool dac_is_used(void)
{
    if (paired_adc.adc || paired_adc.dac) {
        return true;
    }
    return false;
}

static inline void dac_add_pair(audio_codec_dac_t *codec)
{
    if (codec->cfg.codec_mode & ESP_CODEC_DEV_WORK_MODE_ADC) {
        if (paired_adc.adc == NULL) {
            paired_adc.adc = codec;
            return;
        }
    }
    if (codec->cfg.codec_mode & ESP_CODEC_DEV_WORK_MODE_DAC) {
        if (paired_adc.dac == NULL) {
            paired_adc.dac = codec;
            return;
        }
    }
}

static void dac_remove_pair(audio_codec_dac_t *codec)
{
    if (codec->cfg.codec_mode & ESP_CODEC_DEV_WORK_MODE_ADC) {
        if (paired_adc.adc == codec) {
            paired_adc.adc = NULL;
            return;
        }
    }
    if (codec->cfg.codec_mode & ESP_CODEC_DEV_WORK_MODE_DAC) {
        if (paired_adc.dac == codec) {
            paired_adc.dac = NULL;
            return;
        }
    }
}

static int dac_set_mute(const audio_codec_if_t *h, bool mute)
{
    return ESP_CODEC_DEV_OK;
}

static int dac_set_vol(const audio_codec_if_t *h, float db_value)
{
    return ESP_CODEC_DEV_OK;
}

static int dac_set_mic_gain(const audio_codec_if_t *h, float db)
{
    return ESP_CODEC_DEV_OK;
}

static int dac_open(const audio_codec_if_t *h, void *cfg, int cfg_size)
{
    audio_codec_dac_t *codec = (audio_codec_dac_t *) h;
    dac_codec_cfg_t *codec_cfg = (dac_codec_cfg_t *) cfg;
    if (codec == NULL || codec_cfg == NULL || cfg_size != sizeof(dac_codec_cfg_t)) {
        return ESP_CODEC_DEV_INVALID_ARG;
    }
    memcpy(&codec->cfg, cfg, sizeof(dac_codec_cfg_t));
    if (codec->cfg.mclk_div == 0) {
        codec->cfg.mclk_div = MCLK_DEFAULT_DIV;
    }
    codec->is_open = true;
    return ESP_CODEC_DEV_OK;
}

static int dac_close(const audio_codec_if_t *h)
{
    audio_codec_dac_t *codec = (audio_codec_dac_t *) h;
    if (codec == NULL) {
        return ESP_CODEC_DEV_INVALID_ARG;
    }
    if (codec->is_open) {
        dac_remove_pair(codec);
        codec->is_open = false;
    }
    return ESP_CODEC_DEV_OK;
}

static int dac_set_fs(const audio_codec_if_t *h, esp_codec_dev_sample_info_t *fs)
{
    audio_codec_dac_t *codec = (audio_codec_dac_t *) h;
    if (codec == NULL || codec->is_open == false) {
        return ESP_CODEC_DEV_INVALID_ARG;
    }
    return ESP_CODEC_DEV_OK;
}

static int dac_enable(const audio_codec_if_t *h, bool enable)
{
    int ret = ESP_CODEC_DEV_OK;
    audio_codec_dac_t *codec = (audio_codec_dac_t *) h;
    if (codec == NULL) {
        return ESP_CODEC_DEV_INVALID_ARG;
    }
    if (codec->is_open == false) {
        return ESP_CODEC_DEV_WRONG_STATE;
    }
    if (enable == codec->enabled) {
        return ESP_CODEC_DEV_OK;
    }
    if (ret == ESP_CODEC_DEV_OK) {
        codec->enabled = enable;
        ESP_LOGD(TAG, "Codec is %s", enable ? "enabled" : "disabled");
    }
    return ret;
}

static int dac_set_reg(const audio_codec_if_t *h, int reg, int value)
{
    return ESP_CODEC_DEV_OK;
}

static int dac_get_reg(const audio_codec_if_t *h, int reg, int *value)
{
    *value = 0;
    return ESP_CODEC_DEV_OK;
}

static void dac_dump(const audio_codec_if_t *h)
{
}

const audio_codec_if_t *dac_codec_new(dac_codec_cfg_t *codec_cfg)
{
    if (codec_cfg == NULL) {
        ESP_LOGE(TAG, "Wrong codec config");
        return NULL;
    }
    audio_codec_dac_t *codec = (audio_codec_dac_t *) calloc(1, sizeof(audio_codec_dac_t));
    if (codec == NULL) {
        CODEC_MEM_CHECK(codec);
        return NULL;
    }
    codec->base.open = dac_open;
    codec->base.enable = dac_enable;
    codec->base.set_fs = dac_set_fs;
    codec->base.set_vol = dac_set_vol;
    codec->base.set_mic_gain = dac_set_mic_gain;
    codec->base.mute = dac_set_mute;
    codec->base.set_reg = dac_set_reg;
    codec->base.get_reg = dac_get_reg;
    codec->base.dump_reg = dac_dump;
    codec->base.close = dac_close;
    do {
        int ret = codec->base.open(&codec->base, codec_cfg, sizeof(dac_codec_cfg_t));
        if (ret != 0) {
            ESP_LOGE(TAG, "Open fail");
            break;
        }
        return &codec->base;
    } while (0);
    if (codec) {
        free(codec);
    }
    return NULL;
}
