/*****************************************************************************
**  FPGA interface handling
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
#include "fpga.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <freertos/FreeRTOS.h>
#include <freertos/task.h>
#include <driver/spi_master.h>
#include <driver/gpio.h>
#include <sdkconfig.h>
#include <esp_log.h>

#include "llspi.h"
#include "i2s.h"
#include "emutimer.h"

#define MAX(a, b)   (((a) > (b)) ? (a) : (b))

#define FPGA_BUSY_TIMEOUT_MS  100

#define FPGA_CLK_FREQ         (4*1000*1000)
#define FPGA_INPUT_DELAY_NS   0

#define SPI_HOST              SPI2_HOST
#define SPI_PIN_NUM_CS        4
#define SPI_PIN_NUM_CLK       5
#define SPI_PIN_NUM_D0        6
#define SPI_PIN_NUM_D1        7
#define SPI_PIN_NUM_D2        15
#define SPI_PIN_NUM_D3        16
#define SPI_PIN_NUM_IRQ       17

static const char TAG[] = "main";

/// Configurations of the spi_fpga
typedef struct {
    spi_host_device_t host;     ///< The SPI host used, set before calling `fpga_create()`
    gpio_num_t irq_io;          ///< MISO gpio number, set before calling `fpga_create()`
} fpga_config_t;

/// Context (config and data) of the spi_fpga
struct fpga_context_t {
    fpga_config_t cfg;          ///< Configuration by the caller.
    spi_device_handle_t spi;    ///< SPI device handle
    reset_callback_t reset_callback;
    void* reset_callback_ref;
    SemaphoreHandle_t spi_sem;  ///< Semaphore for SPI transfers
    SemaphoreHandle_t interrupt_sem; ///< Semaphore for ready signal
    spi_transaction_ext_t read_fifo_trans;
    spi_transaction_ext_t write_fifo_trans;
    bool read_fifo_busy;
    uint32_t read_fifo_value;
};

typedef struct fpga_context_t fpga_context_t;
typedef struct fpga_context_t* fpga_handle_t;

#define FPGA_CMD_LOOPBACK       0
#define FPGA_CMD_UPDATE         1
#define FPGA_CMD_SET_PROPERTIES 2
#define FPGA_CMD_SET_IRQ        3
#define FPGA_CMD_GET_RESPONSE   8

#define FPGA_RESP_RESET         1
#define FPGA_RESP_LOOPBACK      2
#define FPGA_RESP_NOTIFY        4
#define FPGA_RESP_WRITE         5
#define FPGA_RESP_READ          6

typedef struct {
    union {
        struct {
            uint8_t read_mode   : 2;
            uint8_t write_ipc   : 1;
            uint8_t write_cache : 1;
            uint8_t reserved    : 4;
        };
        uint8_t val;
    };
} fpga_io_properties_t;

typedef struct {
    union {
        struct {
            uint32_t addr   : 8;
            uint32_t data   : 8;
            uint32_t resp   : 4;
            uint32_t reserved20: 3;
            uint32_t valid  : 1;
            uint32_t reserved24: 8;
        };
        uint32_t val;
    };
} fpga_response_t;

static fpga_io_properties_t s_io_properties[256];

static void isr_handler(void* arg);

esp_err_t spi_fast_fpga_write(fpga_context_t* ctx, uint8_t cmd, uint8_t addr, uint8_t data);
esp_err_t spi_fpga_read(fpga_context_t* ctx, uint32_t* out_data);
static void fpga_handle_communication(void *args);

void fpga_set_reset_callback(fpga_handle_t ctx, reset_callback_t reset_callback, void* ref)
{
    ctx->reset_callback = reset_callback;
    ctx->reset_callback_ref = ref;
}

fpga_handle_t fpga_create(void)
{
    esp_err_t ret;

    // Allocate memory
    fpga_context_t* ctx = (fpga_context_t*)calloc(1, sizeof(fpga_context_t));
    if (!ctx) {
        ESP_LOGE(TAG, "No memory");
        return NULL;
    }

    ESP_LOGI(TAG, "Initializing bus SPI%d...", SPI_HOST + 1);
    spi_bus_config_t buscfg = {
        .flags = SPICOMMON_BUSFLAG_QUAD,
        .sclk_io_num = SPI_PIN_NUM_CLK,
        .mosi_io_num = SPI_PIN_NUM_D0,
        .max_transfer_sz = 512,
        .data1_io_num = SPI_PIN_NUM_D1,
        .data2_io_num = SPI_PIN_NUM_D2,
        .data3_io_num = SPI_PIN_NUM_D3,
    };

    // Initialize the SPI bus
    ret = spi_bus_initialize(SPI_HOST, &buscfg, SPI_DMA_CH_AUTO);
    ESP_ERROR_CHECK(ret);

    // Config
    ctx->cfg.host = SPI_HOST;
    ctx->cfg.irq_io = SPI_PIN_NUM_IRQ;

    gpio_install_isr_service(0);

    ESP_LOGI(TAG, "Initializing device...");

    // Attach the FPGA to the SPI bus
    static spi_device_interface_config_t devcfg = {
        .command_bits = 4,
        .address_bits = 0,
        .dummy_bits = 0, // don't use dummy bits here as they will also be inserted in write transactions, use SPI_TRANS_VARIABLE_DUMMY instead
        .clock_speed_hz = FPGA_CLK_FREQ,
        .mode = 0,          //SPI mode 0
        .spics_io_num = SPI_PIN_NUM_CS,
        .queue_size = 1,
        .flags = SPI_DEVICE_HALFDUPLEX,
        .input_delay_ns = FPGA_INPUT_DELAY_NS,
    };
    ret = spi_bus_add_device(ctx->cfg.host, &devcfg, &ctx->spi);
    ESP_ERROR_CHECK(ret);

    // Semaphore for IST
    ctx->interrupt_sem = xSemaphoreCreateBinary();
    ESP_ERROR_CHECK(ret);

    // Setup transfer structs
    ctx->read_fifo_trans.base.user = ctx;
    ctx->read_fifo_trans.base.cmd = FPGA_CMD_GET_RESPONSE;
    ctx->read_fifo_trans.base.rxlength = 24;
    ctx->read_fifo_trans.base.flags = SPI_TRANS_USE_RXDATA | (SPI_TRANS_MULTILINE_CMD | SPI_TRANS_MULTILINE_ADDR | SPI_TRANS_VARIABLE_DUMMY | SPI_TRANS_MODE_QIO);
    ctx->read_fifo_trans.dummy_bits = 2;    // this turns out to be 'clocks', not 'bits'

    ctx->write_fifo_trans.base.user = ctx;
    ctx->write_fifo_trans.base.tx_data[2] = 0xff; // dummy clocks
    ctx->write_fifo_trans.base.length = 16+8; // +8 for two dummy clocks after the data
    ctx->write_fifo_trans.base.flags = SPI_TRANS_USE_TXDATA | (SPI_TRANS_MULTILINE_CMD | SPI_TRANS_MULTILINE_ADDR | SPI_TRANS_VARIABLE_DUMMY | SPI_TRANS_MODE_QIO);

    // Acquire the SPI bus permanently
    ret = spi_device_acquire_bus(ctx->spi, portMAX_DELAY);
    ESP_ERROR_CHECK(ret);

    // Setup the low-latency SPI driver
    llspi_setup_device(ctx->spi);

    // Mutex for SPI communication
    ctx->spi_sem = xSemaphoreCreateBinary();
    assert(ctx->spi_sem != NULL);
    xSemaphoreGive(ctx->spi_sem);

    // Init FPGA IO bridge
    // -------------------

    // Global disable
    ret = spi_fast_fpga_write(ctx, FPGA_CMD_SET_PROPERTIES, 0xff, 0);
    ESP_ERROR_CHECK(ret);

    // Disable all IO properties
    for (uint8_t addr = 0; addr < 0xff; addr++) {
        ret = spi_fast_fpga_write(ctx, FPGA_CMD_SET_PROPERTIES, addr, 0);
        ESP_ERROR_CHECK(ret);
    }

    ESP_LOGI(TAG, "Flushing fifo ...");
    uint32_t rxvalue;
    for(;;) {
        ret = spi_fpga_read(ctx, &rxvalue);
        ESP_ERROR_CHECK(ret);
        if ((rxvalue & 0xF00000) != 0x800000) {
            break;
        }
    }

    // Loopback test
    ESP_LOGI(TAG, "Loopback test ...");
    for (int addr = 0; addr <= 0xff; addr++) {
        // Loopback command to FPGA
        ret = spi_fast_fpga_write(ctx, FPGA_CMD_LOOPBACK, (uint8_t)addr, 1 << (addr & 7));
        ESP_ERROR_CHECK(ret);
        // Get response
        ret = spi_fpga_read(ctx, &rxvalue);
        ESP_ERROR_CHECK(ret);
        uint32_t expected = (8 << 20) | (FPGA_RESP_LOOPBACK << 16) | (0x100 << (addr & 7)) | addr;
        if (rxvalue != expected) {
            ESP_LOGE(TAG, "Loopback test failed at addr 0x%x: expected 0x%x, got 0x%x", addr, expected, rxvalue);
            return NULL;
        }
    }
    ESP_LOGI(TAG, "passed");

    // Final read to reset the IRQ
    ret = spi_fpga_read(ctx, &rxvalue);
    ESP_ERROR_CHECK(ret);

    // Arm interrupt
    xSemaphoreTake(ctx->interrupt_sem, 0);
    gpio_set_intr_type(ctx->cfg.irq_io, GPIO_INTR_HIGH_LEVEL);
    ret = gpio_isr_handler_add(ctx->cfg.irq_io, isr_handler, ctx);
    ESP_ERROR_CHECK(ret);

    // Start interrupt handler task
    xTaskCreatePinnedToCore(fpga_handle_communication, "fpga_handle_communication", 4096, ctx, 5, NULL, 1);

    return ctx;
}

void fpga_io_start(fpga_handle_t ctx)
{
    gpio_intr_enable(ctx->cfg.irq_io);
}

void fpga_io_stop(fpga_handle_t ctx)
{
    // Global disable
    esp_err_t ret = spi_fast_fpga_write(ctx, FPGA_CMD_SET_PROPERTIES, 0xff, 0);
    ESP_ERROR_CHECK(ret);
    gpio_intr_disable(ctx->cfg.irq_io);
}

void fpga_io_reset(fpga_handle_t ctx)
{
    // Disable all IO properties
    for (uint8_t addr = 0; addr < 0xff; addr++) {
        esp_err_t ret = spi_fast_fpga_write(ctx, FPGA_CMD_SET_PROPERTIES, addr, 0);
        ESP_ERROR_CHECK(ret);
    }

    // Global enable
    esp_err_t ret = spi_fast_fpga_write(ctx, FPGA_CMD_SET_PROPERTIES, 0xff, 0x55);
    ESP_ERROR_CHECK(ret);

    memset(s_io_properties, 0, sizeof(s_io_properties));
}

void fpga_io_register(fpga_handle_t ctx, uint8_t port, IoPortProperties_t prop)
{
    if (prop & IoPropRead) {
        ESP_LOGI(TAG, "Register read port 0x%02x", port);
        s_io_properties[port].read_mode = 3; // Read via IPC
    }
    if (prop & IoPropWrite) {
        ESP_LOGI(TAG, "Register write port 0x%02x", port);
        s_io_properties[port].write_ipc = 1; // Write via IPC
    }
    esp_err_t ret = spi_fast_fpga_write(ctx, FPGA_CMD_SET_PROPERTIES, port, s_io_properties[port].val);
    ESP_ERROR_CHECK(ret);
}

void fpga_io_unregister(fpga_handle_t ctx, uint8_t port)
{
    ESP_LOGI(TAG, "Unregister port 0x%02x", port);
    s_io_properties[port].val = 0;

    esp_err_t ret = spi_fast_fpga_write(ctx, FPGA_CMD_SET_PROPERTIES, port, 0);
    ESP_ERROR_CHECK(ret);
}

void fpga_irq_set(fpga_handle_t fpga_handle)
{
    BaseType_t ret = ret = spi_fast_fpga_write(fpga_handle, FPGA_CMD_SET_IRQ, 0, 1); // Set IRQ
    ESP_ERROR_CHECK(ret);
}

void fpga_irq_reset(fpga_handle_t fpga_handle)
{
    BaseType_t ret = ret = spi_fast_fpga_write(fpga_handle, FPGA_CMD_SET_IRQ, 0, 0); // Reset IRQ
    ESP_ERROR_CHECK(ret);
}

static IRAM_ATTR void isr_handler(void* arg)
{
    fpga_context_t* fpga_handle = (fpga_context_t*)arg;

    gpio_intr_disable(fpga_handle->cfg.irq_io);
    xSemaphoreGive(fpga_handle->interrupt_sem);
}

esp_err_t IRAM_ATTR spi_fast_fpga_write(fpga_context_t* ctx, uint8_t cmd, uint8_t addr, uint8_t data)
{
    esp_err_t ret;
    xSemaphoreTake(ctx->spi_sem, portMAX_DELAY);

    // First finish read when busy
    if (ctx->read_fifo_busy) {
        ret = spi_device_polling_end(ctx->spi, portMAX_DELAY);
        ESP_ERROR_CHECK(ret);
        ctx->read_fifo_busy = false;
        ctx->read_fifo_value = *(uint32_t*)(&ctx->read_fifo_trans.base.rx_data[0]);
    }

    // Setup write transaction
    ctx->write_fifo_trans.base.cmd = cmd;
    ctx->write_fifo_trans.base.tx_data[0] = addr;
    ctx->write_fifo_trans.base.tx_data[1] = data;

    ret = llspi_device_polling_transmit(ctx->spi, &ctx->write_fifo_trans.base);
    ESP_ERROR_CHECK(ret);

    xSemaphoreGive(ctx->spi_sem);
    return ret;
}

esp_err_t IRAM_ATTR spi_fpga_read(fpga_context_t* ctx, uint32_t* out_data)
{
    xSemaphoreTake(ctx->spi_sem, portMAX_DELAY);

    esp_err_t ret = spi_device_polling_start(ctx->spi, &ctx->read_fifo_trans.base, portMAX_DELAY);
    ESP_ERROR_CHECK(ret);

    ret = spi_device_polling_end(ctx->spi, portMAX_DELAY);
    ESP_ERROR_CHECK(ret);

    *out_data = *(uint32_t*)(&ctx->read_fifo_trans.base.rx_data[0]);

    xSemaphoreGive(ctx->spi_sem);
    return ESP_OK;
}

static void IRAM_ATTR fpga_handle_communication(void *args)
{
    fpga_handle_t ctx = (fpga_handle_t)args;

    ESP_LOGI(TAG, "Handling interrupts ...");
    while (1) {
        uint32_t tick_to_wait = MAX(FPGA_BUSY_TIMEOUT_MS / portTICK_PERIOD_MS, 2);
        BaseType_t ret = xSemaphoreTake(ctx->interrupt_sem, tick_to_wait);
        if (ret != pdTRUE) {
            continue;
        }

        xSemaphoreTake(ctx->spi_sem, portMAX_DELAY);

        // Get first response
        ret = spi_device_polling_start(ctx->spi, &ctx->read_fifo_trans.base, portMAX_DELAY);
        ESP_ERROR_CHECK(ret);
        ctx->read_fifo_busy = true;

        // Get response(s)
        for(;;) {
            // Get the response
            fpga_response_t resp;
            if (ctx->read_fifo_busy) {
                ret = spi_device_polling_end(ctx->spi, portMAX_DELAY);
                ESP_ERROR_CHECK(ret);
                ctx->read_fifo_busy = false;
                ctx->read_fifo_value = *(uint32_t*)(&ctx->read_fifo_trans.base.rx_data[0]);
            }
            resp.val = ctx->read_fifo_value;
            if (!resp.valid)
                // No more responses
                break;

            // Prefetch the next response
            llspi_device_wait_ready(ctx->spi);
            ret = spi_device_polling_start(ctx->spi, &ctx->read_fifo_trans.base, portMAX_DELAY);
            ESP_ERROR_CHECK(ret);
            ctx->read_fifo_busy = true;

            // Process the response
            switch(resp.resp) {
                case FPGA_RESP_RESET:
                    ESP_LOGI(TAG, "Reset ...");
                    xSemaphoreGive(ctx->spi_sem);
                    ctx->reset_callback(ctx->reset_callback_ref);
                    xSemaphoreTake(ctx->spi_sem, portMAX_DELAY);
                    break;
                case FPGA_RESP_READ:
                    // IO Read
                    xSemaphoreGive(ctx->spi_sem);
                    uint8_t data = ioPortReadPort(resp.addr);
                    //ESP_LOGI(TAG, "IO read 0x%x -> 0x%x", resp.addr, data);
                    ret = spi_fast_fpga_write(ctx, FPGA_CMD_UPDATE, resp.addr, data);
                    ESP_ERROR_CHECK(ret);
                    xSemaphoreTake(ctx->spi_sem, portMAX_DELAY);
                    break;
                case FPGA_RESP_WRITE:
                    // IO Write
                    //ESP_LOGI(TAG, "IO write 0x%x = 0x%x", resp.addr, resp.data);
                    xSemaphoreGive(ctx->spi_sem);
                    ioPortWritePort(resp.addr, resp.data);
                    xSemaphoreTake(ctx->spi_sem, portMAX_DELAY);
                    break;
                default:
                    ESP_LOGW(TAG, "Unknown FPGA response: 0x%x", resp.val);
            }
        }

        // Enable interrupt again
        xSemaphoreGive(ctx->spi_sem);
        gpio_intr_enable(ctx->cfg.irq_io);
    }
    vTaskDelete(NULL);
}
