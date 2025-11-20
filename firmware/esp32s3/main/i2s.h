#pragma once

#include "driver/i2s_std.h"

void i2s_init(i2s_chan_handle_t *tx_handle, i2s_chan_handle_t *rx_handle);

void i2s_play_music(i2s_chan_handle_t tx_handle);
