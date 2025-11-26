/*****************************************************************************
**  CODEC stub device for DAC only functionality
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
#pragma once

#include <audio_codec_if.h>
#include <esp_codec_dev_vol.h>

#ifdef __cplusplus
extern "C" {
#endif

#define DAC_CODEC_DEFAULT_ADDR (0x30)

/**
 * @brief DAC codec configuration
 */
typedef struct {
    esp_codec_dec_work_mode_t    codec_mode;  /*!< Codec work mode: ADC or DAC */
    bool                         master_mode; /*!< Whether codec works as I2S master or not */
    bool                         use_mclk;    /*!< Whether use external MCLK clock */
    bool                         digital_mic; /*!< Whether use digital microphone */
    bool                         invert_mclk; /*!< MCLK clock signal inverted or not */
    bool                         invert_sclk; /*!< SCLK clock signal inverted or not */
    bool                         no_dac_ref;  /*!< When record 2 channel data
                                                   false: right channel filled with dac output
                                                   true: right channel leave empty
                                              */
    uint16_t                     mclk_div;    /*!< MCLK/LRCK default is 256 if not provided */
} dac_codec_cfg_t;

/**
 * @brief         New DAC codec interface
 * @param         codec_cfg: DAC codec configuration
 * @return        NULL: Fail to new DAC codec interface
 *                -Others: DAC codec interface
 */
const audio_codec_if_t *dac_codec_new(dac_codec_cfg_t *codec_cfg);

#ifdef __cplusplus
}
#endif
