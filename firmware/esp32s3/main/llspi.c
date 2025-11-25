/*
    Low-Latency SPI master driver extension
*/
#include "llspi.h"

// Include original SPI driver to be able to access the private structs
#include "../../esp_driver_spi/src/gpspi/spi_master.c"

static const char TAG[] = "llspi";

void SPI_MASTER_ATTR llspi_set_address(spi_device_handle_t handle, uint8_t addr)
{
    spi_hal_context_t *hal = &handle->host->hal;
    spi_ll_set_address(hal->hw, addr, 8, handle->hal_dev.tx_lsbfirst);
}

esp_err_t SPI_MASTER_ATTR llspi_transmit(spi_device_handle_t handle, uint8_t *send_buffer, uint16_t bitlen)
{
    handle->host->cur_cs = handle->id;
    spi_hal_context_t *hal = &handle->host->hal;
    spi_ll_write_buffer(hal->hw, send_buffer, bitlen);
    spi_hal_enable_data_line(hal->hw, true, false);
    spi_hal_user_start(hal);
    while (!spi_hal_usr_is_done(hal))
        ;
    return ESP_OK;
}

static void SPI_MASTER_ATTR llspi_format_hal_trans_struct(spi_device_t *dev, spi_trans_priv_t *trans_buf, spi_hal_trans_config_t *hal_trans)
{
    spi_host_t *host = dev->host;
    spi_transaction_t *trans = trans_buf->trans;
    hal_trans->tx_bitlen = trans->length;
    hal_trans->rx_bitlen = trans->rxlength;
    hal_trans->rcv_buffer = (uint8_t*)host->cur_trans_buf.buffer_to_rcv;
    hal_trans->send_buffer = (uint8_t*)host->cur_trans_buf.buffer_to_send;
    hal_trans->cmd = trans->cmd;
    hal_trans->addr = trans->addr;

    if (trans->flags & SPI_TRANS_VARIABLE_CMD) {
        hal_trans->cmd_bits = ((spi_transaction_ext_t *)trans)->command_bits;
    } else {
        hal_trans->cmd_bits = dev->cfg.command_bits;
    }
    if (trans->flags & SPI_TRANS_VARIABLE_ADDR) {
        hal_trans->addr_bits = ((spi_transaction_ext_t *)trans)->address_bits;
    } else {
        hal_trans->addr_bits = dev->cfg.address_bits;
    }
    if (trans->flags & SPI_TRANS_VARIABLE_DUMMY) {
        hal_trans->dummy_bits = ((spi_transaction_ext_t *)trans)->dummy_bits;
    } else {
        hal_trans->dummy_bits = dev->cfg.dummy_bits;
    }

    hal_trans->cs_keep_active = (trans->flags & SPI_TRANS_CS_KEEP_ACTIVE) ? 1 : 0;
    //Set up OIO/QIO/DIO if needed
    hal_trans->line_mode.data_lines = (trans->flags & SPI_TRANS_MODE_DIO) ? 2 : (trans->flags & SPI_TRANS_MODE_QIO) ? 4 : 1;
#if SOC_SPI_SUPPORT_OCT
    if (trans->flags & SPI_TRANS_MODE_OCT) {
        hal_trans->line_mode.data_lines = 8;
    }
#endif
    hal_trans->line_mode.addr_lines = (trans->flags & SPI_TRANS_MULTILINE_ADDR) ? hal_trans->line_mode.data_lines : 1;
    hal_trans->line_mode.cmd_lines = (trans->flags & SPI_TRANS_MULTILINE_CMD) ? hal_trans->line_mode.data_lines : 1;
}

void SPI_MASTER_ATTR llspi_setup_device(spi_device_handle_t handle)
{
    spi_host_t *host = handle->host;

    // this function assumes the lock is already acquired
    assert(host->device_acquiring_lock == handle);

    spi_hal_setup_device(&host->hal, &handle->hal_dev);
    SPI_MASTER_PERI_CLOCK_ATOMIC() {
#if SPI_LL_SUPPORT_CLK_SRC_PRE_DIV
        //we set mst_div as const 2, then (hs_clk = 2*mst_clk) to ensure timing turning work as past
        //and sure (hs_div * mst_div = source_pre_div)
        spi_ll_clk_source_pre_div(host->hal.hw, handle->hal_dev->timing_conf.source_pre_div / 2, 2);
#endif
        spi_ll_set_clk_source(host->hal.hw, handle->hal_dev.timing_conf.clock_source);
    }
}

void SPI_MASTER_ATTR llspi_hal_setup_trans(spi_device_handle_t handle, const spi_hal_trans_config_t* trans)
{
    spi_hal_context_t *hal = &handle->host->hal;
    const spi_hal_dev_config_t *dev = &handle->hal_dev;
    spi_dev_t *hw = hal->hw;

    //clear int bit
    spi_ll_clear_int_stat(hal->hw);
    //We should be done with the transmission.
    HAL_ASSERT(spi_ll_get_running_cmd(hw) == 0);
    //set transaction line mode
    spi_ll_master_set_line_mode(hw, trans->line_mode);

    int extra_dummy = 0;
    //when no_dummy is not set and in half-duplex mode, sets the dummy bit if RX phase exist
    if (trans->rcv_buffer && !dev->no_compensate && dev->half_duplex) {
        extra_dummy = dev->timing_conf.timing_dummy;
    }

    //SPI iface needs to be configured for a delay in some cases.
    //configure dummy bits
    spi_ll_set_dummy(hw, extra_dummy + trans->dummy_bits);

    uint32_t miso_delay_num = 0;
    uint32_t miso_delay_mode = 0;
    if (dev->timing_conf.timing_miso_delay < 0) {
        //if the data comes too late, delay half a SPI clock to improve reading
        switch (dev->mode) {
        case 0:
            miso_delay_mode = 2;
            break;
        case 1:
            miso_delay_mode = 1;
            break;
        case 2:
            miso_delay_mode = 1;
            break;
        case 3:
            miso_delay_mode = 2;
            break;
        }
        miso_delay_num = 0;
    } else {
        //if the data is so fast that dummy_bit is used, delay some apb clocks to meet the timing
        miso_delay_num = extra_dummy ? dev->timing_conf.timing_miso_delay : 0;
        miso_delay_mode = 0;
    }
    spi_ll_set_miso_delay(hw, miso_delay_mode, miso_delay_num);

    spi_ll_set_mosi_bitlen(hw, trans->tx_bitlen);

    if (dev->half_duplex) {
        spi_ll_set_miso_bitlen(hw, trans->rx_bitlen);
    } else {
        //rxlength is not used in full-duplex mode
        spi_ll_set_miso_bitlen(hw, trans->tx_bitlen);
    }

    //Configure bit sizes, load addr and command
    int cmdlen = trans->cmd_bits;
    int addrlen = trans->addr_bits;
    if (!dev->half_duplex && dev->cs_setup != 0) {
        /* The command and address phase is not compatible with cs_ena_pretrans
         * in full duplex mode.
         */
        cmdlen = 0;
        addrlen = 0;
    }

    spi_ll_set_addr_bitlen(hw, addrlen);
    spi_ll_set_command_bitlen(hw, cmdlen);

    spi_ll_set_command(hw, trans->cmd, cmdlen, dev->tx_lsbfirst);
    spi_ll_set_address(hw, trans->addr, addrlen, dev->tx_lsbfirst);

    //Configure keep active CS
    spi_ll_master_keep_cs(hw, trans->cs_keep_active);
}

void SPI_MASTER_ATTR llspi_setup_transfer(spi_device_handle_t handle, spi_transaction_t* trans_desc)
{
    spi_host_t *host = handle->host;

    // this function assumes the lock is already acquired
    assert(host->device_acquiring_lock == handle);

    // set the transaction specific configuration each time before a transaction setup
    spi_hal_trans_config_t hal_trans = {};
    hal_trans.tx_bitlen = trans_desc->length;
    hal_trans.rx_bitlen = trans_desc->rxlength;
    hal_trans.rcv_buffer = NULL; // as a result, 'timing_dummy' will not be used, use 'dummy_bits' instead to configure dummy
    hal_trans.cmd = trans_desc->cmd;
    hal_trans.addr = trans_desc->addr;

    if (trans_desc->flags & SPI_TRANS_VARIABLE_CMD) {
        hal_trans.cmd_bits = ((spi_transaction_ext_t *)trans_desc)->command_bits;
    } else {
        hal_trans.cmd_bits = handle->cfg.command_bits;
    }
    if (trans_desc->flags & SPI_TRANS_VARIABLE_ADDR) {
        hal_trans.addr_bits = ((spi_transaction_ext_t *)trans_desc)->address_bits;
    } else {
        hal_trans.addr_bits = handle->cfg.address_bits;
    }
    if (trans_desc->flags & SPI_TRANS_VARIABLE_DUMMY) {
        hal_trans.dummy_bits = ((spi_transaction_ext_t *)trans_desc)->dummy_bits;
    } else {
        hal_trans.dummy_bits = handle->cfg.dummy_bits;
    }

    hal_trans.cs_keep_active = (trans_desc->flags & SPI_TRANS_CS_KEEP_ACTIVE) ? 1 : 0;
    //Set up OIO/QIO/DIO if needed
    hal_trans.line_mode.data_lines = (trans_desc->flags & SPI_TRANS_MODE_DIO) ? 2 : (trans_desc->flags & SPI_TRANS_MODE_QIO) ? 4 : 1;
#if SOC_SPI_SUPPORT_OCT
    if (trans_desc->flags & SPI_TRANS_MODE_OCT) {
        hal_trans.line_mode.data_lines = 8;
    }
#endif
    hal_trans.line_mode.addr_lines = (trans_desc->flags & SPI_TRANS_MULTILINE_ADDR) ? hal_trans.line_mode.data_lines : 1;
    hal_trans.line_mode.cmd_lines = (trans_desc->flags & SPI_TRANS_MULTILINE_CMD) ? hal_trans.line_mode.data_lines : 1;

    llspi_hal_setup_trans(handle, &hal_trans);
}

esp_err_t SPI_MASTER_ATTR llspi_device_polling_transmit(spi_device_handle_t handle, spi_transaction_t* trans_desc)
{
    spi_host_t *host = handle->host;
    spi_trans_priv_t priv_polling_trans = { .trans = trans_desc, };

    // this function assumes the lock is already acquired
    assert(host->device_acquiring_lock == handle);

    // rx memory assign
    uint32_t* rcv_ptr;
    if (trans_desc->flags & SPI_TRANS_USE_RXDATA) {
        rcv_ptr = (uint32_t *)&trans_desc->rx_data[0];
    } else {
        //if not use RXDATA neither rx_buffer, buffer_to_rcv assigned to NULL
        rcv_ptr = trans_desc->rx_buffer;
    }

    // tx memory assign
    const uint32_t *send_ptr;
    if (trans_desc->flags & SPI_TRANS_USE_TXDATA) {
        send_ptr = (uint32_t *)&trans_desc->tx_data[0];
    } else {
        //if not use TXDATA neither tx_buffer, tx data assigned to NULL
        send_ptr = trans_desc->tx_buffer ;
    }

    priv_polling_trans.buffer_to_send = send_ptr;
    priv_polling_trans.buffer_to_rcv = rcv_ptr;

    // Polling, no interrupt is used.
    host->polling = true;
    host->cur_trans_buf = priv_polling_trans;

    ESP_LOGV(TAG, "polling trans");

    host->cur_cs = handle->id;

    //Reconfigure according to device settings, the function only has effect when the dev_id is changed.
    //spi_setup_device(handle, &host->cur_trans_buf);

#if 0
    spi_hal_setup_device(&host->hal, &handle->hal_dev);
    SPI_MASTER_PERI_CLOCK_ATOMIC() {
#if SPI_LL_SUPPORT_CLK_SRC_PRE_DIV
        //we set mst_div as const 2, then (hs_clk = 2*mst_clk) to ensure timing turning work as past
        //and sure (hs_div * mst_div = source_pre_div)
        spi_ll_clk_source_pre_div(host->hal.hw, handle->hal_dev->timing_conf.source_pre_div / 2, 2);
#endif
        spi_ll_set_clk_source(host->hal.hw, handle->hal_dev.timing_conf.clock_source);
    }
#endif

    //set the transaction specific configuration each time before a transaction setup
    spi_hal_trans_config_t hal_trans = {};
    llspi_format_hal_trans_struct(handle, &host->cur_trans_buf, &hal_trans);
    spi_hal_setup_trans(&host->hal, &handle->hal_dev, &hal_trans);

    // Need to copy data to registers manually
    spi_hal_push_tx_buffer(&host->hal, &hal_trans);

    // in ESP32 these registers should be configured after the DMA is set
    spi_hal_enable_data_line(host->hal.hw, (!handle->hal_dev.half_duplex && hal_trans.rcv_buffer) || hal_trans.send_buffer, !!hal_trans.rcv_buffer);

    // Kick off transfer
    spi_hal_user_start(&host->hal);

    // Polling wait
    TickType_t start = xTaskGetTickCount();
    while (!spi_hal_usr_is_done(&host->hal)) {
        TickType_t end = xTaskGetTickCount();
        if (end - start > portMAX_DELAY) {
            return ESP_ERR_TIMEOUT;
        }
    }

    //release temporary buffers
    //uninstall_priv_desc(&host->cur_trans_buf);
    spi_trans_priv_t* trans_buf = &host->cur_trans_buf;
    if ((void *)trans_buf->buffer_to_send != &trans_desc->tx_data[0] &&
            trans_buf->buffer_to_send != trans_desc->tx_buffer) {
        free((void *)trans_buf->buffer_to_send); //force free, ignore const
    }
    // copy data from temporary DMA-capable buffer back to IRAM buffer and free the temporary one.
    if (trans_buf->buffer_to_rcv && (void *)trans_buf->buffer_to_rcv != &trans_desc->rx_data[0] && trans_buf->buffer_to_rcv != trans_desc->rx_buffer) { // NOLINT(clang-analyzer-unix.Malloc)
        if (trans_desc->flags & SPI_TRANS_USE_RXDATA) {
            memcpy((uint8_t *) & trans_desc->rx_data[0], trans_buf->buffer_to_rcv, (trans_desc->rxlength + 7) / 8);
        } else {
            memcpy(trans_desc->rx_buffer, trans_buf->buffer_to_rcv, (trans_desc->rxlength + 7) / 8);
        }
        free(trans_buf->buffer_to_rcv);
    }

    host->polling = false;

    return ESP_OK;
}

void llspi_device_wait_ready(spi_device_handle_t handle)
{
    spi_host_t *host = handle->host;

    while (!spi_hal_usr_is_done(&host->hal))
        ;
}
