/*
    MSX I/O extender, emulating:
    - AY8910 - PSG
    - YM2413 - MSX-MUSIC
*/

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

#include "i2s.h"

#include "bluemsx/IoPort.h"
#include "bluemsx/AudioMixer.h"
#include "bluemsx/AY8910.h"
#include "bluemsx/YM2413.h"
#include "bluemsx/MsxAudio.h"

#define MAX(a, b)   (((a) > (b)) ? (a) : (b))

#define FPGA_BUSY_TIMEOUT_MS  100

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
    SemaphoreHandle_t mixer_sem;
    SemaphoreHandle_t spi_sem;
    i2s_chan_handle_t tx_handle;
    i2s_chan_handle_t rx_handle;
    Mixer *mixer;
    AY8910 *psg;
    YM_2413 *ym2413;
    MsxAudioHndl msxaudio;

};

typedef struct fpga_context_t fpga_context_t;
typedef struct fpga_context_t* fpga_handle_t;

static void isr_handler(void* arg);

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

esp_err_t spi_fast_fpga_write(fpga_context_t* fpga_handle, uint8_t cmd, uint8_t addr, uint8_t data);
esp_err_t spi_fpga_read(fpga_context_t* fpga_handle, uint32_t* out_data);

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

void io_reset()
{
    memset(s_io_properties, 0, sizeof(s_io_properties));
}

void io_register(uint8_t port, IoPortProperties_t prop, void* ref)
{
    fpga_handle_t fpga_handle = (fpga_handle_t)ref;

    if (prop & IoPropRead) {
        ESP_LOGI(TAG, "Register read port 0x%02x", port);
        s_io_properties[port].read_mode = 3; // Read via IPC
    }
    if (prop & IoPropWrite) {
        ESP_LOGI(TAG, "Register write port 0x%02x", port);
        s_io_properties[port].write_ipc = 1; // Write via IPC
    }
    int ret = spi_fast_fpga_write(fpga_handle, FPGA_CMD_SET_PROPERTIES, port, s_io_properties[port].val);
    ESP_ERROR_CHECK(ret);
}

void io_unregister(uint8_t port, void* ref)
{
    fpga_handle_t fpga_handle = (fpga_handle_t)ref;

    ESP_LOGI(TAG, "Unregister port 0x%02x", port);
    s_io_properties[port].val = 0;

    int ret = spi_fast_fpga_write(fpga_handle, FPGA_CMD_SET_PROPERTIES, port, 0);
    ESP_ERROR_CHECK(ret);
}

uint32_t get_timer_count_12k5()
{
    static uint32_t prev_tick, leftover;
    uint32_t cur_tick = xTaskGetTickCount();
    uint32_t count = pdTICKS_TO_MS((cur_tick - prev_tick) * 12500) + leftover;
    prev_tick = cur_tick;
    leftover = count % 1000;
    count /= 1000;
    if (count > 4096) {
        count = 4096;
    }
    return count;
}

uint32_t get_sample_count()
{
    static uint32_t prev_tick, leftover;
    uint32_t cur_tick = xTaskGetTickCount();
    uint32_t count = pdTICKS_TO_MS((cur_tick - prev_tick) * 44100) + leftover;
    prev_tick = cur_tick;
    leftover = count % 1000;
    count /= 1000;
    if (count > 4096) {
        count = 4096;
    }
    if (count > 500) {
        ESP_LOGI(TAG, "mix %d", count);
    }

    // Handle audio tick timers
    int elapsed = get_timer_count_12k5();
    msxaudioTick(elapsed);

    return count;
}

static Int32 i2sMixerWriteCallback(void* arg, Int16* buffer, UInt32 count)
{
    fpga_handle_t fpga_handle = (fpga_handle_t)arg;
    size_t bytes_write = 0;
    esp_err_t ret;

    ret = i2s_channel_write(fpga_handle->tx_handle, buffer, count * sizeof(Int16), &bytes_write, 0);
    if (ret != ESP_OK && ret != ESP_ERR_TIMEOUT) {
        ESP_LOGE(TAG, "[mixer] i2s write failed");
        abort();
    }

    return bytes_write / sizeof(Int16);
}

void reset_peripherals(fpga_handle_t fpga_handle)
{
    esp_err_t ret;

    // Stop mixer thread
    xSemaphoreTake(fpga_handle->mixer_sem, portMAX_DELAY);

    // Global disable
    ret = spi_fast_fpga_write(fpga_handle, FPGA_CMD_SET_PROPERTIES, 0xff, 0);
    ESP_ERROR_CHECK(ret);

    // Cleanup
    if (fpga_handle->msxaudio) {
        msxaudioDestroy(fpga_handle->msxaudio);
    }
    if (fpga_handle->ym2413) {
        ym2413Destroy(fpga_handle->ym2413);
    }
    if (fpga_handle->psg) {
        ay8910Destroy(fpga_handle->psg);
    }
    if (fpga_handle->mixer) {
        mixerDestroy(fpga_handle->mixer);
    }

    // Disable all IO properties
    for (uint8_t addr = 0; addr < 0xff; addr++) {
        ret = spi_fast_fpga_write(fpga_handle, FPGA_CMD_SET_PROPERTIES, addr, 0);
        ESP_ERROR_CHECK(ret);
    }

    // Global enable
    ret = spi_fast_fpga_write(fpga_handle, FPGA_CMD_SET_PROPERTIES, 0xff, 0x55);
    ESP_ERROR_CHECK(ret);

    // Init IoPort manager
    io_reset();
    ioPortInit(io_register, io_unregister, fpga_handle);

    // Create mixer
    fpga_handle->mixer = mixerCreate(get_sample_count);

    // Create sound chips
    fpga_handle->psg = ay8910Create(fpga_handle->mixer, AY8910_MSX, PSGTYPE_AY8910);
    fpga_handle->ym2413 = ym2413Create(fpga_handle->mixer);
    fpga_handle->msxaudio = msxaudioCreate(fpga_handle->mixer);

    // Configure mixer
    mixerSetWriteCallback(fpga_handle->mixer, i2sMixerWriteCallback, fpga_handle, 128);
    mixerSetMasterVolume(fpga_handle->mixer, 100);
    mixerEnableMaster(fpga_handle->mixer, 1);
    mixerSetStereo(fpga_handle->mixer, 1);
    mixerSetChannelTypeVolume(fpga_handle->mixer, MIXER_CHANNEL_PSG, 100);
    mixerSetChannelTypeVolume(fpga_handle->mixer, MIXER_CHANNEL_MSXMUSIC, 100);
    mixerSetChannelTypeVolume(fpga_handle->mixer, MIXER_CHANNEL_MSXAUDIO, 100);
    mixerSetChannelTypePan(fpga_handle->mixer, MIXER_CHANNEL_PSG, 50);
    mixerSetChannelTypePan(fpga_handle->mixer, MIXER_CHANNEL_MSXMUSIC, 0);
    mixerSetChannelTypePan(fpga_handle->mixer, MIXER_CHANNEL_MSXAUDIO, 100);
    mixerEnableChannelType(fpga_handle->mixer, MIXER_CHANNEL_PSG, 1);
    mixerEnableChannelType(fpga_handle->mixer, MIXER_CHANNEL_MSXMUSIC, 1);
    mixerEnableChannelType(fpga_handle->mixer, MIXER_CHANNEL_MSXAUDIO, 1);

    mixerSetEnable(fpga_handle->mixer, 1);

    // Continue mixer thread
    (void)get_sample_count();
    xSemaphoreGive(fpga_handle->mixer_sem);

    // Debug
    //--------

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
}

static spi_transaction_ext_t read_fifo_trans = {
    .base.cmd = FPGA_CMD_GET_RESPONSE,
    .base.rxlength = 24,
    .base.flags = SPI_TRANS_USE_RXDATA | (SPI_TRANS_MULTILINE_CMD | SPI_TRANS_MULTILINE_ADDR | SPI_TRANS_VARIABLE_DUMMY | SPI_TRANS_MODE_QIO),
    .dummy_bits = 2,    // this turns out to be 'clocks', not 'bits'
};
static bool read_fifo_busy;
static uint32_t read_fifo_value;

static spi_transaction_ext_t write_fifo_trans = {
    .base.tx_data[2] = 0xff, // dummy clocks
    .base.length = 16+8, // +8 for two dummy clocks after the data
    .base.flags = SPI_TRANS_USE_TXDATA | (SPI_TRANS_MULTILINE_CMD | SPI_TRANS_MULTILINE_ADDR | SPI_TRANS_VARIABLE_DUMMY | SPI_TRANS_MODE_QIO),
};

static IRAM_ATTR void isr_handler(void* arg)
{
    fpga_context_t* fpga_handle = (fpga_context_t*)arg;

    gpio_intr_disable(fpga_handle->cfg.irq_io);
    xSemaphoreGive(fpga_handle->interrupt_sem);
}

esp_err_t spi_fast_fpga_write(fpga_context_t* fpga_handle, uint8_t cmd, uint8_t addr, uint8_t data)
{
    esp_err_t ret;
    xSemaphoreTake(fpga_handle->spi_sem, portMAX_DELAY);

    // First finish read when busy
    if (read_fifo_busy) {
        ret = spi_device_polling_end(fpga_handle->spi, portMAX_DELAY);
        ESP_ERROR_CHECK(ret);
        read_fifo_busy = false;
        read_fifo_value = *(uint32_t*)(&read_fifo_trans.base.rx_data[0]);
    }

    // Setup write transaction
    write_fifo_trans.base.cmd = cmd;
    write_fifo_trans.base.tx_data[0] = addr;
    write_fifo_trans.base.tx_data[1] = data;

    ret = llspi_device_polling_transmit(fpga_handle->spi, &write_fifo_trans.base);
    ESP_ERROR_CHECK(ret);

    xSemaphoreGive(fpga_handle->spi_sem);
    return ret;
}

esp_err_t spi_fpga_read(fpga_context_t* fpga_handle, uint32_t* out_data)
{
    xSemaphoreTake(fpga_handle->spi_sem, portMAX_DELAY);

    esp_err_t ret = spi_device_polling_start(fpga_handle->spi, &read_fifo_trans.base, portMAX_DELAY);
    ESP_ERROR_CHECK(ret);

    ret = spi_device_polling_end(fpga_handle->spi, portMAX_DELAY);
    ESP_ERROR_CHECK(ret);

    *out_data = *(uint32_t*)(&read_fifo_trans.base.rx_data[0]);

    xSemaphoreGive(fpga_handle->spi_sem);
    return ESP_OK;
}

static void fpga_handle_communication(void *args)
{
    fpga_handle_t fpga_handle = (fpga_handle_t)args;

    ESP_LOGI(TAG, "Handling interrupts ...");
    while (1) {
        uint32_t tick_to_wait = MAX(FPGA_BUSY_TIMEOUT_MS / portTICK_PERIOD_MS, 2);
        BaseType_t ret = xSemaphoreTake(fpga_handle->interrupt_sem, tick_to_wait);
        if (ret != pdTRUE) {
            continue;
        }

        xSemaphoreTake(fpga_handle->spi_sem, portMAX_DELAY);

        // Get first response
        ret = spi_device_polling_start(fpga_handle->spi, &read_fifo_trans.base, portMAX_DELAY);
        ESP_ERROR_CHECK(ret);
        read_fifo_busy = true;

        // Get response(s)
        for(;;) {
            // Get the response
            fpga_response_t resp;
            if (read_fifo_busy) {
                ret = spi_device_polling_end(fpga_handle->spi, portMAX_DELAY);
                ESP_ERROR_CHECK(ret);
                read_fifo_busy = false;
                read_fifo_value = *(uint32_t*)(&read_fifo_trans.base.rx_data[0]);
            }
            resp.val = read_fifo_value;
            if (!resp.valid)
                // No more responses
                break;

            // Prefetch the next response
            llspi_device_wait_ready(fpga_handle->spi);
            ret = spi_device_polling_start(fpga_handle->spi, &read_fifo_trans.base, portMAX_DELAY);
            ESP_ERROR_CHECK(ret);
            read_fifo_busy = true;

            // Process the response
            switch(resp.resp) {
                case FPGA_RESP_RESET:
                    ESP_LOGI(TAG, "Reset ...");
                    xSemaphoreGive(fpga_handle->spi_sem);
                    reset_peripherals(fpga_handle);
                    xSemaphoreTake(fpga_handle->spi_sem, portMAX_DELAY);
                    break;
                case FPGA_RESP_READ:
                    // IO Read
                    xSemaphoreGive(fpga_handle->spi_sem);
                    uint8_t data = ioPortReadPort(resp.addr);
                    //ESP_LOGI(TAG, "IO read 0x%x -> 0x%x", resp.addr, data);
                    ret = spi_fast_fpga_write(fpga_handle, FPGA_CMD_UPDATE, resp.addr, data);
                    ESP_ERROR_CHECK(ret);
                    xSemaphoreTake(fpga_handle->spi_sem, portMAX_DELAY);
                    break;
                case FPGA_RESP_WRITE:
                    // IO Write
                    //ESP_LOGI(TAG, "IO write 0x%x = 0x%x", resp.addr, resp.data);
                    xSemaphoreGive(fpga_handle->spi_sem);
                    ioPortWritePort(resp.addr, resp.data);
                    xSemaphoreTake(fpga_handle->spi_sem, portMAX_DELAY);
                    break;
                default:
                    ESP_LOGW(TAG, "Unknown FPGA response: 0x%x", resp.val);
            }
        }

        // Enable interrupt again
        xSemaphoreGive(fpga_handle->spi_sem);
        gpio_intr_enable(fpga_handle->cfg.irq_io);
    }
    vTaskDelete(NULL);
}

static uint32_t s_pending_irq;
fpga_handle_t s_static_fpga_handle;

void  boardSetInt(uint32_t irq)
{
    bool was_pending = (s_pending_irq != 0);

    s_pending_irq |= irq;

    if (s_pending_irq != 0 && !was_pending) {
        //ESP_LOGI(TAG, "Set INT");
        BaseType_t ret = ret = spi_fast_fpga_write(s_static_fpga_handle, FPGA_CMD_SET_IRQ, 0, 1); // Set IRQ
        ESP_ERROR_CHECK(ret);
    }
}

void   boardClearInt(uint32_t irq)
{
    bool was_pending = (s_pending_irq != 0);

    s_pending_irq &= ~irq;

    if (s_pending_irq == 0 && was_pending) {
        //ESP_LOGI(TAG, "Reset INT");
        BaseType_t ret = ret = spi_fast_fpga_write(s_static_fpga_handle, FPGA_CMD_SET_IRQ, 0, 0); // Reset IRQ
        ESP_ERROR_CHECK(ret);
    }
}

static void i2s_mixer(void *args)
{
    fpga_handle_t fpga_handle = (fpga_handle_t)args;

    (void)get_sample_count();

    /* Enable the TX channel */
    while (1) {
        xSemaphoreTake(fpga_handle->mixer_sem, portMAX_DELAY);
        mixerSync(fpga_handle->mixer);
        xSemaphoreGive(fpga_handle->mixer_sem);

        vTaskDelay(1);
    }
    vTaskDelete(NULL);
}

void ipc_main(void)
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

    // Setup transfer structs
    write_fifo_trans.base.user = fpga_handle;
    read_fifo_trans.base.user = fpga_handle;

    // TODO: Make nicer
    s_static_fpga_handle = fpga_handle;

    ret = spi_device_acquire_bus(fpga_handle->spi, portMAX_DELAY);
    ESP_ERROR_CHECK(ret);

    llspi_setup_device(fpga_handle->spi);

    i2s_init(&fpga_handle->tx_handle, &fpga_handle->rx_handle);
    //i2s_play_music(fpga_handle->tx_handle);

    // Mutex for SPI communication
    fpga_handle->spi_sem = xSemaphoreCreateBinary();
    assert(fpga_handle->spi_sem != NULL);
    xSemaphoreGive(fpga_handle->spi_sem);

    // Global disable
    ret = spi_fast_fpga_write(fpga_handle, FPGA_CMD_SET_PROPERTIES, 0xff, 0);
    ESP_ERROR_CHECK(ret);

    // Disable all IO properties
    for (uint8_t addr = 0; addr < 0xff; addr++) {
        ret = spi_fast_fpga_write(fpga_handle, FPGA_CMD_SET_PROPERTIES, addr, 0);
        ESP_ERROR_CHECK(ret);
    }

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

    // Init mixer mutex
    fpga_handle->mixer_sem = xSemaphoreCreateBinary();
    assert(fpga_handle->mixer_sem != NULL);
    xSemaphoreGive(fpga_handle->mixer_sem);

    // Arm interrupt
    xSemaphoreTake(fpga_handle->interrupt_sem, 0);
    gpio_set_intr_type(fpga_config.irq_io, GPIO_INTR_HIGH_LEVEL);
    ret = gpio_isr_handler_add(fpga_config.irq_io, isr_handler, fpga_handle);
    ESP_ERROR_CHECK(ret);
    gpio_intr_enable(fpga_config.irq_io);

    // Configure IO
    //--------------------------

    reset_peripherals(fpga_handle);

    /* Start interrupt handler */
    xTaskCreatePinnedToCore(fpga_handle_communication, "fpga_handle_communication", 4096, fpga_handle, 5, NULL, 1);

    /* Start the audio task */
    xTaskCreatePinnedToCore(i2s_mixer, "i2s_mixer", 4096, fpga_handle, 6, NULL, 0);
}

void app_main(void)
{
    ipc_main();

    while (1) {
        vTaskDelay(100);
    }
}
