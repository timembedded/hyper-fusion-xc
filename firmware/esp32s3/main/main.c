/* HTTP Server Tests

   This example code is in the Public Domain (or CC0 licensed, at your option.)

   Unless required by applicable law or agreed to in writing, this
   software is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR
   CONDITIONS OF ANY KIND, either express or implied.
*/

#include "esp_event.h"
#include "esp_log.h"
#include "esp_system.h"
#include "nvs_flash.h"

#include "spitest.h"
#include "i2s.h"

//static const char *TAG = "example";

void app_main(void)
{
    spitest_main();
    i2s_main();

    while (1) {
        vTaskDelay(100);
    }
}
