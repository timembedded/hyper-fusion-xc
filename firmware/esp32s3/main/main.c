#include "esp_event.h"
#include "esp_log.h"
#include "esp_system.h"
#include "esp_psram.h"
#include "nvs_flash.h"

#include "spitest.h"

void app_main(void)
{
    spitest_main();

    while (1) {
        vTaskDelay(100);
    }
}
