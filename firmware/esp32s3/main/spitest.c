/* SPI test
*/
#include "spitest.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "driver/spi_master.h"
#include "driver/gpio.h"

#include "sdkconfig.h"
#include "esp_log.h"

#include "llspi.h"

#define MAX(a, b)   (((a) > (b)) ? (a) : (b))

#define FPGA_BUSY_TIMEOUT_MS  1000

#define FPGA_CLK_FREQ         (4*1000*1000)   //When powered by 3.3V, FPGA max freq is 1MHz
#define FPGA_INPUT_DELAY_NS   0 //((1000*1000*1000/FPGA_CLK_FREQ)/2+20)

#define ADDR_MASK   0x7f

#define CMD_EWEN    0x01
#define CMD_READ    0x02
#define CMD_WRITE   0x03

#define ADD_EWEN    0x60

#define SPI_HOST          SPI2_HOST
#define SPI_PIN_NUM_CS    4
#define SPI_PIN_NUM_CLK   5
#define SPI_PIN_NUM_D0    6
#define SPI_PIN_NUM_D1    7
#define SPI_PIN_NUM_D2    15
#define SPI_PIN_NUM_D3    16
#define SPI_PIN_NUM_IRQ   17

static const char TAG[] = "main";

/// Configurations of the spi_fpga
typedef struct {
    spi_host_device_t host; ///< The SPI host used, set before calling `spi_fpga_init()`
    gpio_num_t irq_io;     ///< MISO gpio number, set before calling `spi_fpga_init()`
} fpga_config_t;

/// Context (config and data) of the spi_fpga
struct fpga_context_t {
    fpga_config_t cfg;        ///< Configuration by the caller.
    spi_device_handle_t spi;    ///< SPI device handle
    SemaphoreHandle_t interrupt_sem; ///< Semaphore for ready signal
};

typedef struct fpga_context_t fpga_context_t;
typedef struct fpga_context_t* fpga_handle_t;

static IRAM_ATTR void isr_handler(void* arg)
{
    fpga_context_t* ctx = (fpga_context_t*)arg;
    xSemaphoreGive(ctx->interrupt_sem);
    ESP_EARLY_LOGV(TAG, "interrupt detected");
}

esp_err_t spi_fpga_init(const fpga_config_t *cfg, fpga_context_t** out_ctx)
{
    esp_err_t err = ESP_OK;
    if (cfg->host == SPI1_HOST) {
        ESP_LOGE(TAG, "interrupt cannot be used on SPI1 host");
        return ESP_ERR_INVALID_ARG;
    }

    fpga_context_t* ctx = (fpga_context_t*)malloc(sizeof(fpga_context_t));
    if (!ctx) {
        return ESP_ERR_NO_MEM;
    }

    *ctx = (fpga_context_t) {
        .cfg = *cfg,
    };

    spi_device_interface_config_t devcfg = {
        .command_bits = 4,
        .address_bits = 0,
        .dummy_bits = 0, // don't use dummy bits here as they will also be inserted in write transactions, use SPI_TRANS_VARIABLE_DUMMY instead
        .clock_speed_hz = FPGA_CLK_FREQ,
        .mode = 0,          //SPI mode 0
        .spics_io_num = SPI_PIN_NUM_CS,
        .queue_size = 1,
        .flags = SPI_DEVICE_HALFDUPLEX,
        .input_delay_ns = FPGA_INPUT_DELAY_NS,  //the FPGA output the data half a SPI clock behind.
    };
    //Attach the FPGA to the SPI bus
    err = spi_bus_add_device(ctx->cfg.host, &devcfg, &ctx->spi);
    if (err != ESP_OK) {
        goto cleanup;
    }

    ctx->interrupt_sem = xSemaphoreCreateBinary();
    if (ctx->interrupt_sem == NULL) {
        err = ESP_ERR_NO_MEM;
        goto cleanup;
    }

    gpio_set_intr_type(ctx->cfg.irq_io, GPIO_INTR_POSEDGE);
    err = gpio_isr_handler_add(ctx->cfg.irq_io, isr_handler, ctx);
    if (err != ESP_OK) {
        goto cleanup;
    }
    gpio_intr_disable(ctx->cfg.irq_io);

    *out_ctx = ctx;
    return ESP_OK;

cleanup:
    if (ctx->spi) {
        spi_bus_remove_device(ctx->spi);
        ctx->spi = NULL;
    }
    if (ctx->interrupt_sem) {
        vSemaphoreDelete(ctx->interrupt_sem);
        ctx->interrupt_sem = NULL;
    }
    free(ctx);
    return err;
}

#define FPGA_CMD_UPDATE         0
#define FPGA_CMD_SET_PROPERTIES 1
#define FPGA_CMD_LOOPBACK       2
#define FPGA_CMD_GET_RESPONSE   8

#define FPGA_RESP_NOTIFY        0
#define FPGA_RESP_WRITE         1
#define FPGA_RESP_READ          2
#define FPGA_RESP_LOOPBACK      3

esp_err_t IRAM_ATTR spi_fast_fpga_write(fpga_context_t* ctx, uint8_t cmd, uint8_t addr, uint8_t data)
{
    esp_err_t err;
#if 1
    spi_transaction_ext_t t = {
        .base.cmd = cmd,
        .base.tx_data[0] = addr,
        .base.tx_data[1] = data,
        .base.tx_data[2] = 0xff, // dummy clocks
        .base.length = 16+8, // +8 for two dummy clocks after the data
        .base.flags = SPI_TRANS_USE_TXDATA | (SPI_TRANS_MULTILINE_CMD | SPI_TRANS_MULTILINE_ADDR | SPI_TRANS_VARIABLE_DUMMY | SPI_TRANS_MODE_QIO),
        .base.user = ctx,
    };
    err = llspi_device_polling_transmit(ctx->spi, &t.base);
    if (err != ESP_OK) {
        return err;
    }
#else
    llspi_set_address(ctx->spi, addr);
    err = llspi_transmit(ctx->spi, &data, 8);
#endif
    return err;
}

esp_err_t spi_fpga_read(fpga_context_t* ctx, uint32_t* out_data)
{
    spi_transaction_ext_t t = {
        .base.cmd = FPGA_CMD_GET_RESPONSE,
        .base.rxlength = 24,
        .base.flags = SPI_TRANS_USE_RXDATA | (SPI_TRANS_MULTILINE_CMD | SPI_TRANS_MULTILINE_ADDR | SPI_TRANS_VARIABLE_DUMMY | SPI_TRANS_MODE_QIO),
        .base.user = ctx,
        .dummy_bits = 2,    // this turns out to be 'clocks', not 'bits'
    };
#if 1
    esp_err_t err = spi_device_polling_transmit(ctx->spi, &t.base);
#else
    esp_err_t err = llspi_device_polling_transmit(ctx->spi, &t.base);
#endif
    if (err != ESP_OK) {
        return err;
    }

    *out_data = *(uint32_t*)(&t.base.rx_data[0]);
    return ESP_OK;
}

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

void spitest_main(void)
{
    esp_err_t ret;
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
    //Initialize the SPI bus
    ret = spi_bus_initialize(SPI_HOST, &buscfg, SPI_DMA_CH_AUTO);
    ESP_ERROR_CHECK(ret);

    fpga_config_t fpga_config = {
        .host = SPI_HOST,
        .irq_io = SPI_PIN_NUM_IRQ,
    };

    gpio_install_isr_service(0);

    fpga_handle_t fpga_handle;

    ESP_LOGI(TAG, "Initializing device...");
    ret = spi_fpga_init(&fpga_config, &fpga_handle);
    ESP_ERROR_CHECK(ret);

    ret = spi_device_acquire_bus(fpga_handle->spi, portMAX_DELAY);
    ESP_ERROR_CHECK(ret);

    llspi_setup_device(fpga_handle->spi);

    ESP_LOGI(TAG, "Flushing fifo ...");
    uint32_t rxvalue;
    for(;;) {
        ret = spi_fpga_read(fpga_handle, &rxvalue);
        ESP_ERROR_CHECK(ret);
        if ((rxvalue & 0xF00000) != 0x800000) {
            break;
        }
    }

    // Loopback test
    ESP_LOGI(TAG, "Loopback test ...");
    for (int addr = 0; addr <= 0xff; addr++) {
        // Loopback command to FPGA
        ret = spi_fast_fpga_write(fpga_handle, FPGA_CMD_LOOPBACK, (uint8_t)addr, 1 << (addr & 7));
        ESP_ERROR_CHECK(ret);
        // Get response
        ret = spi_fpga_read(fpga_handle, &rxvalue);
        ESP_ERROR_CHECK(ret);
        uint32_t expected = (8 << 20) | (FPGA_RESP_LOOPBACK << 16) | (0x100 << (addr & 7)) | addr;
        if (rxvalue != expected) {
            ESP_LOGE(TAG, "Loopback test failed at addr 0x%x: expected 0x%x, got 0x%x", addr, expected, rxvalue);
            return;
        }
    }
    ESP_LOGI(TAG, "passed");

    // Final read to reset the IRQ
    ret = spi_fpga_read(fpga_handle, &rxvalue);
    ESP_ERROR_CHECK(ret);

    // Disable all IO properties
    for (uint8_t addr = 0; addr < 0xff; addr++) {
        ret = spi_fast_fpga_write(fpga_handle, FPGA_CMD_SET_PROPERTIES, addr, 0);
        ESP_ERROR_CHECK(ret);
    }

    // Arm interrupt
    xSemaphoreTake(fpga_handle->interrupt_sem, 0);
    gpio_intr_enable(fpga_config.irq_io);

    // Global enable
    ret = spi_fast_fpga_write(fpga_handle, FPGA_CMD_SET_PROPERTIES, 0xff, 0x55);
    ESP_ERROR_CHECK(ret);

    // Configure IO
    //--------------------------

    fpga_io_properties_t io_props_60 = {
        .read_mode = 2,     // Read from cache + notify
        .write_ipc = 0,
        .write_cache = 1,   // Write to cache
    };
    ret = spi_fast_fpga_write(fpga_handle, FPGA_CMD_SET_PROPERTIES, 0x60, io_props_60.val); // Write to RAM, read from RAM, notify
    ESP_ERROR_CHECK(ret);

    fpga_io_properties_t io_props_61 = {
        .read_mode = 3,     // Read via IPC
        .write_ipc = 1,     // Write via IPC
        .write_cache = 0,
    };
    ret = spi_fast_fpga_write(fpga_handle, FPGA_CMD_SET_PROPERTIES, 0x61, io_props_61.val); // Write to RAM, read from RAM, notify
    ESP_ERROR_CHECK(ret);

    ESP_LOGI(TAG, "Handling interrupts ...");
    while (1) {
        uint32_t tick_to_wait = MAX(FPGA_BUSY_TIMEOUT_MS / portTICK_PERIOD_MS, 2);
        BaseType_t ret = xSemaphoreTake(fpga_handle->interrupt_sem, tick_to_wait);
        if (ret != pdTRUE) {
            continue;
        }else{
            ESP_LOGI(TAG, "trig");
        }

        // Get response(s)
        for(;;) {
            fpga_response_t resp;
            ret = spi_fpga_read(fpga_handle, &resp.val);
            ESP_ERROR_CHECK(ret);
            if (!resp.valid)
                break;
            ESP_LOGI(TAG, "resp %d addr 0x%x data 0x%x", resp.resp, resp.addr, resp.data);
            if (resp.resp == 2) { // Read response
                // Send back the data
                ret = spi_fast_fpga_write(fpga_handle, FPGA_CMD_UPDATE, resp.addr, 0x55);
                ESP_ERROR_CHECK(ret);
            }
        }
    }
}
