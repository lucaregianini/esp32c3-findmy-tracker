// Low-power Find My (OpenHaystack-style) beacon for the ESP32-C3 SuperMini.
//
// Same over-the-air format as go-haystack, so the same keys keep working in
// FindMy.py / hass-FindMy. The difference is power: the CPU light-sleeps
// between advertising events instead of running all the time.

#include <string.h>

#include "esp_adc/adc_cali.h"
#include "esp_adc/adc_cali_scheme.h"
#include "esp_adc/adc_oneshot.h"
#include "esp_log.h"
#include "esp_mac.h"
#include "esp_pm.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "host/ble_hs.h"
#include "nimble/nimble_port.h"
#include "nimble/nimble_port_freertos.h"
#include "nvs_flash.h"

#include "keys.h"

static const char *TAG = "tracker";

// Find My status byte, battery in bits 6-7 (same values as go-haystack)
#define STATUS_FULL 0x10
#define STATUS_MEDIUM 0x40
#define STATUS_LOW 0x80
#define STATUS_CRITICAL 0xC0

static uint8_t status_byte = STATUS_FULL;
static int battery_mv = 0;
static int battery_pct = -1;

// ---------------------------------------------------------------- battery

// 3x AA alkaline under a light load, pack mV -> %. 0 % is where the board's
// regulator can no longer hold 3.3 V reliably.
static const struct {
    int mv, pct;
} ALKALINE_3AA[] = {
    {4650, 100}, {4350, 90}, {4140, 80}, {3960, 65}, {3810, 50},
    {3660, 35},  {3600, 30}, {3540, 25}, {3450, 15}, {3390, 5}, {3330, 0},
};

static int pack_percent(int mv)
{
    const int n = sizeof(ALKALINE_3AA) / sizeof(ALKALINE_3AA[0]);
    if (mv >= ALKALINE_3AA[0].mv) return 100;
    for (int i = 1; i < n; i++) {
        if (mv >= ALKALINE_3AA[i].mv) {
            int hi_mv = ALKALINE_3AA[i - 1].mv, hi_p = ALKALINE_3AA[i - 1].pct;
            int lo_mv = ALKALINE_3AA[i].mv, lo_p = ALKALINE_3AA[i].pct;
            return lo_p + (mv - lo_mv) * (hi_p - lo_p) / (hi_mv - lo_mv);
        }
    }
    return 0;
}

// Levels use the same bands hass-FindMy assumes: >80, 50-80, 30-50, <30 %
static uint8_t status_for_percent(int pct)
{
    if (pct >= 80) return STATUS_FULL;
    if (pct >= 50) return STATUS_MEDIUM;
    if (pct >= 30) return STATUS_LOW;
    return STATUS_CRITICAL;
}

static adc_oneshot_unit_handle_t adc;
static adc_cali_handle_t cali;

static void battery_init(void)
{
    adc_oneshot_unit_init_cfg_t unit = {.unit_id = ADC_UNIT_1};
    ESP_ERROR_CHECK(adc_oneshot_new_unit(&unit, &adc));
    adc_oneshot_chan_cfg_t chan = {.atten = ADC_ATTEN_DB_12, .bitwidth = ADC_BITWIDTH_DEFAULT};
    ESP_ERROR_CHECK(adc_oneshot_config_channel(adc, CONFIG_TRACKER_BATTERY_GPIO_CHANNEL, &chan));
    // Factory calibration from eFuse: corrects the chip-to-chip error that
    // made the TinyGo reading 10 % high
    adc_cali_curve_fitting_config_t cc = {
        .unit_id = ADC_UNIT_1, .atten = ADC_ATTEN_DB_12, .bitwidth = ADC_BITWIDTH_DEFAULT};
    if (adc_cali_create_scheme_curve_fitting(&cc, &cali) != ESP_OK) {
        ESP_LOGW(TAG, "no ADC calibration in eFuse, readings are rough");
        cali = NULL;
    }
}

static void battery_update(void)
{
    int sum = 0, raw = 0;
    const int samples = 16;
    for (int i = 0; i < samples; i++) {
        adc_oneshot_read(adc, CONFIG_TRACKER_BATTERY_GPIO_CHANNEL, &raw);
        sum += raw;
    }
    raw = sum / samples;
    int pin_mv = 0;
    if (cali) {
        adc_cali_raw_to_voltage(cali, raw, &pin_mv);
    } else {
        pin_mv = raw * 2500 / 4095;
    }
    battery_mv = pin_mv * CONFIG_TRACKER_DIVIDER_X1000 / 1000;
    battery_pct = pack_percent(battery_mv);
    status_byte = status_for_percent(battery_pct);
    ESP_LOGI(TAG, "battery %d mV, %d %%, status 0x%02x", battery_mv, battery_pct, status_byte);
}

// ---------------------------------------------------------------- advertising

static int gap_event(struct ble_gap_event *event, void *arg) { return 0; }

static int advertise(const uint8_t addr[6], const uint8_t *data, int len, int interval_ms)
{
    ble_gap_adv_stop();
    int rc = ble_hs_id_set_rnd(addr);
    if (rc) return rc;
    rc = ble_gap_adv_set_data(data, len);
    if (rc) return rc;
    struct ble_gap_adv_params p = {0};
    p.conn_mode = BLE_GAP_CONN_MODE_NON;
    p.disc_mode = BLE_GAP_DISC_MODE_NON;
    p.itvl_min = p.itvl_max = BLE_GAP_ADV_ITVL_MS(interval_ms);
    return ble_gap_adv_start(BLE_OWN_ADDR_RANDOM, NULL, BLE_HS_FOREVER, &p, gap_event, NULL);
}

// OpenHaystack payload: the address carries key bytes 0-5, the manufacturer
// data carries bytes 6-27 and the top two bits of byte 0.
static void advertise_findmy(int index)
{
    const uint8_t *key = ADV_KEYS[index];
    uint8_t addr[6] = {key[5], key[4], key[3], key[2], key[1], key[0] | 0xC0};
    uint8_t adv[31] = {0x1e, 0xff, 0x4c, 0x00, 0x12, 0x19, status_byte};
    memcpy(&adv[7], &key[6], 22);
    adv[29] = key[0] >> 6;
    adv[30] = 0x00;  // hint
    int rc = advertise(addr, adv, sizeof(adv), CONFIG_TRACKER_ADV_INTERVAL_MS);
    if (rc) ESP_LOGE(TAG, "find my adv failed: %d", rc);
    else ESP_LOGI(TAG, "find my key %d, addr %02X:%02X:%02X:%02X:%02X:%02X", index, addr[5], addr[4],
                  addr[3], addr[2], addr[1], addr[0]);
}

#if CONFIG_TRACKER_BTHOME
// BTHome v2, unencrypted, "trigger based" so HA doesn't mark it unavailable
// between bursts. Objects: 0x01 battery %, 0x0C voltage in mV.
static void advertise_bthome(void)
{
    uint8_t mac[6];
    esp_read_mac(mac, ESP_MAC_BT);
    // static random address from the chip MAC, distinct from the Find My keys
    uint8_t addr[6] = {mac[5], mac[4], mac[3], mac[2], mac[1], (uint8_t)(mac[0] | 0xC0)};

    uint8_t adv[31];
    int n = 0;
    adv[n++] = 0x02; adv[n++] = 0x01; adv[n++] = 0x06;
    const char *name = CONFIG_TRACKER_BTHOME_NAME;
    int name_len = strlen(name);
    if (name_len > 10) name_len = 10;
    adv[n++] = name_len + 1; adv[n++] = 0x09;
    memcpy(&adv[n], name, name_len); n += name_len;
    adv[n++] = 9; adv[n++] = 0x16; adv[n++] = 0xD2; adv[n++] = 0xFC; adv[n++] = 0x44;
    adv[n++] = 0x01; adv[n++] = (uint8_t)(battery_pct < 0 ? 0 : battery_pct);
    adv[n++] = 0x0C; adv[n++] = battery_mv & 0xff; adv[n++] = (battery_mv >> 8) & 0xff;

    int rc = advertise(addr, adv, n, 100);
    if (rc) ESP_LOGE(TAG, "bthome adv failed: %d", rc);
    else vTaskDelay(pdMS_TO_TICKS(3000));  // ~30 packets, then back to Find My
}
#endif

// ---------------------------------------------------------------- main loop

static void tracker_task(void *arg)
{
    int key = 0;
    uint32_t minute = 0;

    battery_update();
#if CONFIG_TRACKER_BTHOME
    advertise_bthome();
#endif
    advertise_findmy(key);

    for (;;) {
        // Everything below is idle time: the CPU light-sleeps and the radio
        // wakes only for its advertising events.
        vTaskDelay(pdMS_TO_TICKS(60 * 1000));
        minute++;
        bool readvertise = false;

        if (minute % CONFIG_TRACKER_BATTERY_CHECK_MIN == 0) {
            uint8_t old = status_byte;
            battery_update();
            readvertise |= status_byte != old;
        }
        if (minute % CONFIG_TRACKER_ROTATION_MIN == 0) {
            key = (key + 1) % ADV_KEY_COUNT;
            readvertise = true;
        }
#if CONFIG_TRACKER_BTHOME
        if (minute % CONFIG_TRACKER_BTHOME_EVERY_MIN == 0) {
            advertise_bthome();
            readvertise = true;
        }
#endif
        if (readvertise) advertise_findmy(key);
    }
}

static void on_sync(void)
{
    xTaskCreate(tracker_task, "tracker", 4096, NULL, 5, NULL);
}

static void host_task(void *param)
{
    nimble_port_run();
    nimble_port_freertos_deinit();
}

void app_main(void)
{
    ESP_LOGI(TAG, "c3 find my tracker, %d keys, %d ms interval, rotate %d min", ADV_KEY_COUNT,
             CONFIG_TRACKER_ADV_INTERVAL_MS, CONFIG_TRACKER_ROTATION_MIN);

    esp_err_t err = nvs_flash_init();
    if (err == ESP_ERR_NVS_NO_FREE_PAGES || err == ESP_ERR_NVS_NEW_VERSION_FOUND) {
        ESP_ERROR_CHECK(nvs_flash_erase());
        err = nvs_flash_init();
    }
    ESP_ERROR_CHECK(err);

    esp_pm_config_t pm = {.max_freq_mhz = 80, .min_freq_mhz = 40, .light_sleep_enable = true};
    ESP_ERROR_CHECK(esp_pm_configure(&pm));

    battery_init();

    ESP_ERROR_CHECK(nimble_port_init());
    ble_hs_cfg.sync_cb = on_sync;
    nimble_port_freertos_init(host_task);
}
