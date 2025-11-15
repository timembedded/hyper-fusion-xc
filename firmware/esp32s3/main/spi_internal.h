/*
 SPI structures and internal definitions
*/
#include <hal/spi_hal.h>
#include <esp_private/spi_share_hw_ctrl.h>
#include <esp_private/spi_common_internal.h>
#include <esp_private/spi_master_internal.h>

// NOTE: This MUST EXACTLY match with the definition in spi_mastr.c

/// struct to hold private transaction data (like tx and rx buffer for DMA).
typedef struct {
    spi_transaction_t   *trans;
    const uint32_t *buffer_to_send;    //equals to tx_data, if SPI_TRANS_USE_RXDATA is applied; otherwise if original buffer wasn't in DMA-capable memory, this gets the address of a temporary buffer that is;
    //otherwise sets to the original buffer or NULL if no buffer is assigned.
    uint32_t *buffer_to_rcv;           //similar to buffer_to_send
#if SOC_SPI_SCT_SUPPORTED
    uint32_t reserved[2];              //As we create the queue when in init, to use sct mode private descriptor as a queue item (when in sct mode), we need to add a dummy member here to keep the same size with `spi_sct_trans_priv_t`.
#endif
} spi_trans_priv_t;

#if SOC_SPI_SCT_SUPPORTED
//Type of dma descriptors that used under SPI SCT mode
typedef struct {
    spi_dma_desc_t          *tx_seg_head;
    spi_dma_desc_t          *rx_seg_head;
    spi_multi_transaction_t *sct_trans_desc_head;
    uint32_t                *sct_conf_buffer;
    uint16_t                tx_used_desc_num;
    uint16_t                rx_used_desc_num;
} spi_sct_trans_priv_t;
_Static_assert(sizeof(spi_trans_priv_t) == sizeof(spi_sct_trans_priv_t));   //size of spi_trans_priv_t must be the same as size of spi_sct_trans_priv_t

typedef struct {
    /* Segmented-Configure-Transfer required, configured by driver, don't touch */
    uint32_t       tx_free_desc_num;
    uint32_t       rx_free_desc_num;
    spi_dma_desc_t *cur_tx_seg_link;          ///< Current TX DMA descriptor used for sct mode.
    spi_dma_desc_t *cur_rx_seg_link;          ///< Current RX DMA descriptor used for sct mode.
    spi_dma_desc_t *tx_seg_link_tail;         ///< Tail of the TX DMA descriptor link
    spi_dma_desc_t *rx_seg_link_tail;         ///< Tail of the RX DMA descriptor link
} spi_sct_desc_ctx_t;
#endif

struct spi_device_t;
typedef struct spi_device_t spi_device_t;

typedef struct {
    int id;
    spi_device_t* device[DEV_NUM_MAX];
    intr_handle_t intr;
    spi_hal_context_t hal;
    spi_trans_priv_t cur_trans_buf;
#if SOC_SPI_SCT_SUPPORTED
    spi_sct_desc_ctx_t sct_desc_pool;
    spi_sct_trans_priv_t cur_sct_trans;
#endif
    int cur_cs;     //current device doing transaction
    const spi_bus_attr_t* bus_attr;
    const spi_dma_ctx_t *dma_ctx;
    bool sct_mode_enabled;

    /**
     * the bus is permanently controlled by a device until `spi_bus_release_bus`` is called. Otherwise
     * the acquiring of SPI bus will be freed when `spi_device_polling_end` is called.
     */
    spi_device_t* device_acquiring_lock;
    portMUX_TYPE spinlock;

//debug information
    bool polling;   //in process of a polling, avoid of queue new transactions into ISR
} spi_host_t;

struct spi_device_t {
    int id;
    QueueHandle_t trans_queue;
    QueueHandle_t ret_queue;
    spi_device_interface_config_t cfg;
    spi_hal_dev_config_t hal_dev;
    spi_host_t *host;
    spi_bus_lock_dev_handle_t dev_lock;
};

#if SOC_PERIPH_CLK_CTRL_SHARED
#define SPI_MASTER_PERI_CLOCK_ATOMIC() PERIPH_RCC_ATOMIC()
#else
#define SPI_MASTER_PERI_CLOCK_ATOMIC()
#endif
