/**
 * @file web_server.c
 * @brief Fall Sense X Web Server Implementation
 * @details Web interface for configuring the Fall Sense X device
 */

#include "web_server.h"
#include "esp_log.h"
#include "esp_http_server.h"
#include "esp_wifi.h"
#include "esp_netif.h"
#include "esp_system.h"
#include "nvs_flash.h"
#include "nvs.h"
#include "string.h"
#include "cJSON.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "driver/uart.h"
#include "radar_sensor.h"
#include "ota_update.h"
#include "device_pin.h"

static const char *TAG = "web_server";

/* NVS keys */
#define NVS_NS_WIFI "wifi_config"
#define NVS_KEY_SSID "ssid"
#define NVS_KEY_PASSWORD "password"

/* Global state */
static device_mode_t s_device_mode = DEVICE_MODE_NORMAL;
static char s_wifi_ssid[32] = {'\0'};
static char s_wifi_password[64] = {'\0'};
static mode_change_cb_t s_mode_change_callback = NULL;
static httpd_handle_t s_http_server = NULL;

/* Radar configuration - stored in NVS */
typedef struct {
    int mount_type;        // 0 = ceiling, 1 = wall
    float height;          // Height from ground (meters)
    float detection_min;   // Detection range min (meters)
    float detection_max;   // Detection range max (meters)
    int sensitivity;        // 1-10, higher is more sensitive
    int led_enabled;       // 1 = enabled, 0 = disabled
    int led_brightness;    // 1-100, LED brightness percentage
    // Fall detection thresholds
    float fall_threshold;
    float fall_height_drop;
    int fall_hold_time;    // seconds
    float human_confidence;
    // Posture height thresholds (meters) - set by /radar_calibrate or manually.
    // Defaults must match RADAR_CONFIG_DEFAULT() in radar_sensor.h.
    float standing_z;
    float sitting_z;
    float lying_z;
    // Per-point confidence formula tunables - see point_confidence() in
    // radar_sensor.c. Defaults must match RADAR_CONFIG_DEFAULT().
    float conf_snr_max;
    float conf_abs_max;
    float conf_dpk_max;
    float conf_point_threshold;
} radar_config_web_t;

static radar_config_web_t s_radar_config = {
    .mount_type = 0,
    .height = 2.5f,
    .detection_min = 0.5f,
    .detection_max = 6.0f,
    .sensitivity = 5,
    .led_enabled = 1,
    .led_brightness = 100,
    .fall_threshold = 0.5f,
    .fall_height_drop = 0.25f,
    .fall_hold_time = 5,
    .human_confidence = 0.3f,
    .standing_z = 1.0f,
    .sitting_z = 0.6f,
    .lying_z = 0.25f,
    .conf_snr_max = 40.0f,
    .conf_abs_max = 15.0f,
    .conf_dpk_max = 10.0f,
    .conf_point_threshold = 0.4f,
};

/* HTML Pages */
static const char *INDEX_HTML = 
    "<!DOCTYPE html>"
    "<html>"
    "<head>"
    "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">"
    "<title>FassSenseX - Configuration</title>"
    "<style>"
    "body { font-family: Arial, sans-serif; margin: 20px; background: #f0f0f0; }"
    ".container { max-width: 700px; margin: 0 auto; background: white; padding: 20px; border-radius: 10px; box-shadow: 0 2px 10px rgba(0,0,0,0.1); }"
    "h1 { color: #333; text-align: center; }"
    "h2 { color: #555; border-bottom: 2px solid #007bff; padding-bottom: 5px; margin-top: 20px; }"
    "h3 { color: #666; margin-top: 15px; }"
    ".status { padding: 10px; margin: 10px 0; border-radius: 5px; }"
    ".status.normal { background: #d4edda; color: #155724; }"
    ".status.config { background: #fff3cd; color: #856404; }"
    "input, select { width: 100%; padding: 10px; margin: 5px 0 15px; box-sizing: border-box; }"
    "label { font-weight: bold; color: #555; }"
    ".form-group { margin-bottom: 10px; }"
    ".row { display: flex; gap: 15px; }"
    ".col { flex: 1; }"
    "button { width: 100%; padding: 12px; background: #007bff; color: white; border: none; border-radius: 5px; cursor: pointer; font-size: 16px; margin-top: 10px; }"
    "button:hover { background: #0056b3; }"
    "button.danger { background: #dc3545; }"
    "button.danger:hover { background: #c82333; }"
    ".info { background: #e7f3ff; padding: 10px; border-radius: 5px; margin-bottom: 15px; }"
    "</style>"
    "</head>"
    "<body>"
    "<div class=\"container\">"
    "<h1>FassSenseX</h1>"
    "<div class=\"info\">"
    "<p><strong>Device Mode:</strong> <span id=\"mode\">Normal</span></p>"
    "<p><strong>MAC:</strong> <span id=\"mac\">Loading...</span></p>"
    "</div>"
    "<div class=\"form-group\">"
    "<label>Device PIN (required for save/reset/restart/OTA/calibrate):</label>"
    "<input type=\"text\" id=\"devicePin\" placeholder=\"1234\">"
    "</div>"
    "<h2>WiFi Configuration</h2>"
    "<form id=\"wifiForm\">"
    "<label>SSID:</label>"
    "<input type=\"text\" id=\"ssid\" name=\"ssid\" value=\"%s\"></p>"
    "<label>Password:</label>"
    "<input type=\"password\" id=\"password\" name=\"password\" value=\"%s\">"
    "<button type=\"submit\">Save & Restart</button>"
    "</form>"
    "<h2>Available WiFi Networks</h2>"
    "<button type=\"button\" onclick=\"scanWifi()\">Scan WiFi Networks</button>"
    "<p id=\"scanStatus\"></p>"
    "<ul id=\"networkList\"></ul>"
    "<h2>Sensor Configuration</h2>"
    "<form id=\"radarForm\">"
    "<div class=\"row\">"
    "<div class=\"col\">"
    "<div class=\"form-group\">"
    "<label>Mount Type:</label>"
    "<select id=\"mountType\" name=\"mountType\">"
    "<option value=\"0\">Ceiling</option>"
    "<option value=\"1\">Wall</option>"
    "</select>"
    "</div>"
    "</div>"
    "<div class=\"col\">"
    "<div class=\"form-group\">"
    "<label>Height (meters):</label>"
    "<input type=\"number\" id=\"height\" name=\"height\" step=\"0.1\" min=\"1.0\" max=\"5.0\" value=\"2.5\">"
    "</div>"
    "</div>"
    "</div>"
    "<div class=\"row\">"
    "<div class=\"col\">"
    "<div class=\"form-group\">"
    "<label>Detection Min (m):</label>"
    "<input type=\"number\" id=\"detMin\" name=\"detMin\" step=\"0.1\" min=\"0.1\" max=\"10\" value=\"0.5\">"
    "</div>"
    "</div>"
    "<div class=\"col\">"
    "<div class=\"form-group\">"
    "<label>Detection Max (m):</label>"
    "<input type=\"number\" id=\"detMax\" name=\"detMax\" step=\"0.1\" min=\"0.5\" max=\"10\" value=\"6.0\">"
    "</div>"
    "</div>"
    "</div>"
    "<div class=\"row\">"
    "<div class=\"col\">"
    "<div class=\"form-group\">"
    "<label> Sensitivity (1-10):</label>"
    "<input type=\"range\" id=\"sensitivity\" name=\"sensitivity\" min=\"1\" max=\"10\" value=\"5\" oninput=\"this.nextElementSibling.value = this.value\">"
    "<output>5</output>"
    "</div>"
    "</div>"
    "<div class=\"col\">"
    "<div class=\"form-group\">"
    "<label>LED Alerts:</label>"
    "<select id=\"ledEnabled\" name=\"ledEnabled\">"
    "<option value=\"1\" selected>Enabled</option>"
    "<option value=\"0\">Disabled</option>"
    "</select>"
    "</div>"
    "<div class=\"form-group\">"
    "<label>LED Brightness (1-100%):</label>"
    "<input type=\"range\" id=\"ledBrightness\" name=\"ledBrightness\" min=\"1\" max=\"100\" value=\"100\" oninput=\"this.nextElementSibling.value = this.value\">"
    "<output>100</output>"
    "</div>"
    "</div>"
    "</div>"
    "<h3>Fall Detection</h3>"
    "<div class=\"row\">"
    "<div class=\"col\">"
    "<div class=\"form-group\">"
    "<label>Confidence (0-1):</label>"
    "<input type=\"number\" id=\"humanConf\" name=\"humanConf\" step=\"0.05\" min=\"0.1\" max=\"1.0\" value=\"0.3\">"
    "</div>"
    "</div>"
    "<div class=\"col\">"
    "<div class=\"form-group\">"
    "<label>Fall Threshold:</label>"
    "<input type=\"number\" id=\"fallThresh\" name=\"fallThresh\" step=\"0.05\" min=\"0.1\" max=\"1.0\" value=\"0.5\">"
    "</div>"
    "</div>"
    "</div>"
    "<div class=\"row\">"
    "<div class=\"col\">"
    "<div class=\"form-group\">"
    "<label>Height Drop (m):</label>"
    "<input type=\"number\" id=\"fallDrop\" name=\"fallDrop\" step=\"0.05\" min=\"0.1\" max=\"1.0\" value=\"0.25\">"
    "</div>"
    "</div>"
    "<div class=\"col\">"
    "<div class=\"form-group\">"
    "<label>Hold Time (sec):</label>"
    "<input type=\"number\" id=\"fallHold\" name=\"fallHold\" step=\"1\" min=\"1\" max=\"30\" value=\"5\">"
    "</div>"
    "</div>"
    "</div>"
    "<h3>Posture Confidence (advanced)</h3>"
    "<div class=\"row\">"
    "<div class=\"col\">"
    "<div class=\"form-group\">"
    "<label>SNR max:</label>"
    "<input type=\"number\" id=\"confSnrMax\" name=\"confSnrMax\" step=\"1\" min=\"1\" max=\"200\" value=\"40\">"
    "</div>"
    "</div>"
    "<div class=\"col\">"
    "<div class=\"form-group\">"
    "<label>ABS max:</label>"
    "<input type=\"number\" id=\"confAbsMax\" name=\"confAbsMax\" step=\"1\" min=\"1\" max=\"200\" value=\"15\">"
    "</div>"
    "</div>"
    "</div>"
    "<div class=\"row\">"
    "<div class=\"col\">"
    "<div class=\"form-group\">"
    "<label>DPK max:</label>"
    "<input type=\"number\" id=\"confDpkMax\" name=\"confDpkMax\" step=\"1\" min=\"1\" max=\"200\" value=\"10\">"
    "</div>"
    "</div>"
    "<div class=\"col\">"
    "<div class=\"form-group\">"
    "<label>Point Confidence Threshold:</label>"
    "<input type=\"number\" id=\"confPointThresh\" name=\"confPointThresh\" step=\"0.05\" min=\"0\" max=\"1\" value=\"0.4\">"
    "</div>"
    "</div>"
    "</div>"
    "<button type=\"submit\">Save Radar Settings</button>"
    "<button type=\"button\" class=\"danger\" onclick=\"resetRadar()\">Reset to Defaults</button>"
    "</form>"
    "<h2>Posture Calibration</h2>"
    "<div class=\"info\">"
    "<p>Stand/sit/lie under the sensor in the actual installation position, then click the matching button to capture the real height for that posture. This updates the standing/sitting/lying Z thresholds used for classification.</p>"
    "<p>Standing Z: <span id=\"standingZ\">--</span> m &nbsp; Sitting Z: <span id=\"sittingZ\">--</span> m &nbsp; Lying Z: <span id=\"lyingZ\">--</span> m</p>"
    "<button type=\"button\" onclick=\"calibrate('standing')\">Capture Standing</button>"
    "<button type=\"button\" onclick=\"calibrate('sitting')\">Capture Sitting</button>"
    "<button type=\"button\" onclick=\"calibrate('lying')\">Capture Lying</button>"
    "</div>"
    "<h2>Device Information</h2>"
    "<div class=\"info\">"
    "<p>FassSenseX - mmWave Radar Fall Detection</p>"
    "<p>Version: 1.0.0 (FW Build : " __DATE__ " " __TIME__ ")</p>"
    "<p><strong>Free Heap:</strong> <span id=\"freeHeap\">--</span> bytes</p>"
    "<p><strong>CPU Temp:</strong> <span id=\"cpuTemp\">--</span> °C</p>"
    "<h2>Firmware Update (OTA)</h2>"
    "<div class=\"info\">"
    "<p>OTA status: <span id=\"otaState\">%s</span></p>"
    "<p>Progress: <span id=\"otaProgress\">%d</span>%%</p>"
    "<p>Manifest URL:</p>"
    "<input type=\"text\" id=\"otaServerUrl\" placeholder=\"https://your-server.com/ota/firmware.json\">"
    "<p><label><input type=\"checkbox\" id=\"otaAutoCheck\"> Enable auto-check every 10 minutes</label></p>"
    "<p><button onclick=\"saveOtaConfig()\">Save OTA Config</button></p>"
    "<p><button onclick=\"checkOtaNow()\">Check for Update Now</button></p>"
    "<p><input type=\"text\" id=\"otaUrl\" placeholder=\"Direct firmware URL\"></p>"
    "<p><button onclick=\"otaUpdate()\">Start OTA from URL</button></p>"
    "</div>"
    "<button type=\"button\" class=\"danger\" onclick=\"restartDevice()\">Restart Device</button>"
    "</div>"
    "</div>"
    "<script>"
    "// Load device status and radar config on page load\n"
    "fetch('/status')\n"
    "  .then(r => r.json())\n"
    "  .then(data => {\n"
    "    document.getElementById('mode').innerText = data.mode;\n"
    "    document.getElementById('mac').innerText = data.mac;\n"
    "    document.getElementById('freeHeap').innerText = data.freeHeap;\n"
    "    document.getElementById('cpuTemp').innerText = data.cpuTemp;\n"
    "  });\n"
    "\n"
    "fetch('/radar_status')\n"
    "  .then(r => r.json())\n"
    "  .then(data => {\n"
    "    document.getElementById('mountType').value = data.mountType;\n"
    "    document.getElementById('height').value = data.height;\n"
    "    document.getElementById('detMin').value = data.detMin;\n"
    "    document.getElementById('detMax').value = data.detMax;\n"
    "    document.getElementById('sensitivity').value = data.sensitivity;\n"
    "    document.getElementById('sensitivity').nextElementSibling.value = data.sensitivity;\n"
    "    document.getElementById('ledEnabled').value = data.ledEnabled;\n"
    "    document.getElementById('ledBrightness').value = data.ledBrightness;\n"
    "    document.getElementById('ledBrightness').nextElementSibling.value = data.ledBrightness;\n"
    "    document.getElementById('humanConf').value = data.humanConf;\n"
    "    document.getElementById('fallThresh').value = data.fallThresh;\n"
    "    document.getElementById('fallDrop').value = data.fallDrop;\n"
    "    document.getElementById('fallHold').value = data.fallHold;\n"
    "    document.getElementById('confSnrMax').value = data.confSnrMax;\n"
    "    document.getElementById('confAbsMax').value = data.confAbsMax;\n"
    "    document.getElementById('confDpkMax').value = data.confDpkMax;\n"
    "    document.getElementById('confPointThresh').value = data.confPointThresh;\n"
    "    document.getElementById('standingZ').innerText = data.standingZ;\n"
    "    document.getElementById('sittingZ').innerText = data.sittingZ;\n"
    "    document.getElementById('lyingZ').innerText = data.lyingZ;\n"
    "  });\n"
    "\n"
    "function pinHeaders() {"
    "  var pin = document.getElementById('devicePin').value;"
    "  return {'Content-Type': 'application/json', 'X-Device-PIN': pin};"
    "}"
    "\n"
    "document.getElementById('wifiForm').addEventListener('submit', function(e) {"
    "  e.preventDefault();"
    "  var ssid = document.getElementById('ssid').value;"
    "  var password = document.getElementById('password').value;"
    "  fetch('/save', {"
    "    method: 'POST',"
    "    headers: {'Content-Type': 'application/json'},"
    "    body: JSON.stringify({ssid: ssid, password: password})"
    "  })"
    "  .then(response => response.json())"
    "  .then(data => {"
    "    if(data.success) {"
    "      alert('Configuration saved! Device will restart.');"
    "      location.reload();"
    "    } else {"
    "      alert('Error: ' + data.error);"
    "    }"
"  });"
"});"
""
"function scanWifi() {"
"  document.getElementById('scanStatus').innerText = 'Scanning...';"
"  document.getElementById('networkList').innerHTML = '';"
"  fetch('/wifi_scan')"
"  .then(r => r.json())"
"  .then(data => {"
"    var list = document.getElementById('networkList');"
"    list.innerHTML = '';"
"    if(!data.success || !data.networks || data.networks.length === 0) {"
"      document.getElementById('scanStatus').innerText = 'No networks found or scan failed.';"
"      return;"
"    }"
"    document.getElementById('scanStatus').innerText = 'Found ' + data.networks.length + ' network(s).';"
"    data.networks.forEach(function(net) {"
"      var li = document.createElement('li');"
"      var button = document.createElement('button');"
"      button.type = 'button';"
"      button.innerText = net.ssid + ' (RSSI ' + net.rssi + ', ch ' + net.channel + ', ' + net.auth + ')';"
"      button.onclick = function() { document.getElementById('ssid').value = net.ssid; };"
"      li.appendChild(button);"
"      list.appendChild(li);"
"    });"
"  })"
"  .catch(function() { document.getElementById('scanStatus').innerText = 'Scan failed.'; });"
"}"
""
"document.getElementById('radarForm').addEventListener('submit', function(e) {"
    "  e.preventDefault();"
    "  var data = {"
    "    mountType: parseInt(document.getElementById('mountType').value),"
    "    height: parseFloat(document.getElementById('height').value),"
    "    detMin: parseFloat(document.getElementById('detMin').value),"
    "    detMax: parseFloat(document.getElementById('detMax').value),"
    "    sensitivity: parseInt(document.getElementById('sensitivity').value),"
    "    ledEnabled: parseInt(document.getElementById('ledEnabled').value),"
    "    ledBrightness: parseInt(document.getElementById('ledBrightness').value),"
    "    humanConf: parseFloat(document.getElementById('humanConf').value),"
    "    fallThresh: parseFloat(document.getElementById('fallThresh').value),"
    "    fallDrop: parseFloat(document.getElementById('fallDrop').value),"
    "    fallHold: parseInt(document.getElementById('fallHold').value),"
    "    confSnrMax: parseFloat(document.getElementById('confSnrMax').value),"
    "    confAbsMax: parseFloat(document.getElementById('confAbsMax').value),"
    "    confDpkMax: parseFloat(document.getElementById('confDpkMax').value),"
    "    confPointThresh: parseFloat(document.getElementById('confPointThresh').value)"
    "  };"
    "  fetch('/radar_save', {"
    "    method: 'POST',"
    "    headers: pinHeaders(),"
    "    body: JSON.stringify(data)"
    "  })"
    "  .then(response => response.json())"
    "  .then(data => {"
    "    if(data.success) {"
    "      alert('Radar config saved! Device will restart.');"
    "    } else {"
    "      alert('Error: ' + data.error);"
    "    }"
    "  });"
    "});"
    ""
    "function calibrate(phase) {"
    "  fetch('/radar_calibrate', {"
    "    method: 'POST',"
    "    headers: pinHeaders(),"
    "    body: JSON.stringify({phase: phase})"
    "  })"
    "  .then(response => response.json())"
    "  .then(data => {"
    "    if(data.success) {"
    "      alert('Captured ' + phase + ': height=' + data.capturedHeight.toFixed(2) + 'm, threshold=' + data.appliedThreshold.toFixed(2) + 'm' + (data.thresholdsOrdered ? '' : ' (WARNING: thresholds out of order, recalibrate other postures)'));"
    "      location.reload();"
    "    } else {"
    "      alert('Error: ' + data.error);"
    "    }"
    "  });"
    "}"
    ""
    "fetch('/ota_config')"
    "  .then(r => r.json())"
    "  .then(data => {"
    "    document.getElementById('otaServerUrl').value = data.serverUrl || '';"
    "    document.getElementById('otaAutoCheck').checked = data.enabled || false;"
    "  });"
    ""
    "function saveOtaConfig() {"
    "  var data = {"
    "    serverUrl: document.getElementById('otaServerUrl').value,"
    "    enabled: document.getElementById('otaAutoCheck').checked"
    "  };"
    "  fetch('/ota_config', {"
    "    method: 'POST',"
    "    headers: {'Content-Type': 'application/json'},"
    "    body: JSON.stringify(data)"
    "  })"
    "  .then(response => response.json())"
    "  .then(data => {"
    "    if(data.success) alert('OTA config saved!');"
    "    else alert('Error: ' + data.error);"
    "  });"
    "}"
    ""
    "function checkOtaNow() {"
    "  var data = {"
    "    serverUrl: document.getElementById('otaServerUrl').value,"
    "    enabled: document.getElementById('otaAutoCheck').checked,"
    "    checkNow: true"
    "  };"
    "  fetch('/ota_config', {"
    "    method: 'POST',"
    "    headers: {'Content-Type': 'application/json'},"
    "    body: JSON.stringify(data)"
    "  })"
    "  .then(response => response.json())"
    "  .then(data => {"
    "    if(data.success) alert('OTA check started!');"
    "    else alert('Error: ' + data.error);"
    "  });"
    "}"
    ""
    "function otaUpdate() {"
    "  var url = document.getElementById('otaUrl').value;"
    "  if(!url) { alert('Please enter firmware URL'); return; }"
    "  if(confirm('Start OTA update from this URL?')) {"
    "    fetch('/ota_update', {"
    "      method: 'POST',"
    "      headers: pinHeaders(),"
    "      body: JSON.stringify({url: url})"
    "    })"
    "    .then(response => response.json())"
    "    .then(data => {"
    "      if(data.success) alert('OTA update started! Device will restart.'); "
    "      else alert('Error: ' + data.error);"
    "    });"
    "  }"
    "}"
    ""
    "function resetRadar() {"
    "  if(confirm('Reset radar settings to defaults?')) {"
    "    fetch('/radar_reset', { method: 'POST', headers: pinHeaders() })"
    "    .then(r => r.json())"
    "    .then(data => {"
    "      if(data.success) alert('Reset to defaults! Restarting...');"
    "      else alert('Error: ' + data.error);"
    "    });"
    "  }"
    "}"
    ""
    "function restartDevice() {"
    "  if(confirm('Restart device?')) {"
    "    fetch('/restart', { method: 'POST', headers: pinHeaders() })"
    "    .then(r => r.json())"
    "    .then(data => { alert('Restarting...'); });"
    "  }"
    "}"
    "</script>"
    "</body>"
    "</html>";


static const char *SUCCESS_JSON = "{\"success\":true}";
static const char *ERROR_JSON = "{\"success\":false,\"error\":\"%s\"}";
static const char *ERROR_JSON_PARSE = "{\"success\":false,\"error\":\"Invalid JSON\"}";
static const char *ERROR_JSON_MISSING = "{\"success\":false,\"error\":\"Missing fields\"}";

static esp_err_t ota_status_handler(httpd_req_t *req)
{
    char json[256];
    int len = snprintf(json, sizeof(json),
        "{\"state\":\"%s\",\"progress\":%d,\"error\":\"%s\"}",
        ota_update_get_state_string(),
        ota_update_get_progress(),
        ota_update_get_error_string());

    httpd_resp_set_type(req, "application/json");
    httpd_resp_send(req, json, len);
    return ESP_OK;
}

static esp_err_t ota_update_handler(httpd_req_t *req)
{
    if (!device_pin_require(req)) {
        return ESP_OK;
    }
    char content[512];
    int content_len = httpd_req_recv(req, content, sizeof(content) - 1);
    if (content_len <= 0) {
        httpd_resp_send(req, ERROR_JSON_PARSE, strlen(ERROR_JSON_PARSE));
        return ESP_FAIL;
    }
    content[content_len] = '\0';

    cJSON *root = cJSON_Parse(content);
    if (!root) {
        httpd_resp_send(req, ERROR_JSON_PARSE, strlen(ERROR_JSON_PARSE));
        return ESP_FAIL;
    }

    cJSON *url_item = cJSON_GetObjectItem(root, "url");
    if (!url_item || !url_item->valuestring || url_item->valuestring[0] == '\0') {
        cJSON_Delete(root);
        httpd_resp_send(req, ERROR_JSON_MISSING, strlen(ERROR_JSON_MISSING));
        return ESP_FAIL;
    }

    ESP_LOGI(TAG, "OTA update requested: %s", url_item->valuestring);
    esp_err_t err = ota_update_start_url(url_item->valuestring);
    cJSON_Delete(root);

    if (err == ESP_OK) {
        httpd_resp_send(req, SUCCESS_JSON, strlen(SUCCESS_JSON));
    } else {
        char error_buf[128];
        snprintf(error_buf, sizeof(error_buf), ERROR_JSON, "Failed to start OTA");
        httpd_resp_send(req, error_buf, strlen(error_buf));
    }
    return ESP_OK;
}

static esp_err_t ota_config_handler(httpd_req_t *req)
{
    if (req->method == HTTP_POST) {
        if (!device_pin_require(req)) {
            return ESP_OK;
        }
        char content[512];
        int content_len = httpd_req_recv(req, content, sizeof(content) - 1);
        if (content_len <= 0) {
            httpd_resp_send(req, ERROR_JSON_PARSE, strlen(ERROR_JSON_PARSE));
            return ESP_FAIL;
        }
        content[content_len] = '\0';

        cJSON *root = cJSON_Parse(content);
        if (!root) {
            httpd_resp_send(req, ERROR_JSON_PARSE, strlen(ERROR_JSON_PARSE));
            return ESP_FAIL;
        }

        cJSON *server_url = cJSON_GetObjectItem(root, "serverUrl");
        cJSON *enabled = cJSON_GetObjectItem(root, "enabled");
        cJSON *check_now = cJSON_GetObjectItem(root, "checkNow");

        if (server_url && server_url->valuestring) {
            ota_update_set_server_url(server_url->valuestring);
        }
        if (enabled) {
            ota_update_set_auto_check_enabled(enabled->valueint ? true : false);
        }
        if (check_now && check_now->valueint) {
            char url[256];
            if (ota_update_get_server_url(url, sizeof(url)) == ESP_OK && url[0] != '\0') {
                ota_update_check_for_update(url);
            }
        }

        cJSON_Delete(root);
    }

    char server_url[256];
    if (ota_update_get_server_url(server_url, sizeof(server_url)) != ESP_OK) {
        server_url[0] = '\0';
    }

    char json[512];
    int len = snprintf(json, sizeof(json),
        "{\"serverUrl\":\"%s\",\"enabled\":%s,\"currentVersion\":\"%s\",\"autoCheck\":%s}",
        server_url,
        ota_update_get_auto_check_enabled() ? "true" : "false",
        OTA_FIRMWARE_VERSION,
        ota_update_get_auto_check_enabled() ? "true" : "false");

    httpd_resp_set_type(req, "application/json");
    httpd_resp_send(req, json, len);
    return ESP_OK;
}

static const httpd_uri_t ota_config_uri = {
    .uri = "/ota_config",
    .method = HTTP_GET,
    .handler = ota_config_handler
};

static const httpd_uri_t ota_config_post_uri = {
    .uri = "/ota_config",
    .method = HTTP_POST,
    .handler = ota_config_handler
};

static const httpd_uri_t ota_status_uri = {
    .uri = "/ota_status",
    .method = HTTP_GET,
    .handler = ota_status_handler
};

static const httpd_uri_t ota_update_uri = {
    .uri = "/ota_update",
    .method = HTTP_POST,
    .handler = ota_update_handler
};

esp_err_t web_server_ota_check_update(const char *server_url, const char *firmware_version)
{
    return ESP_ERR_NOT_SUPPORTED;
}

esp_err_t web_server_ota_start_update(const char *url)
{
    return ota_update_start_url(url);
}

int web_server_ota_get_progress(void)
{
    return ota_update_get_progress();
}

const char *web_server_ota_get_state_string(void)
{
    return ota_update_get_state_string();
}

const char *web_server_ota_get_error_string(void)
{
    return ota_update_get_error_string();
}

/* Radar config NVS namespace */
#define NVS_NS_RADAR "radar_config"
#define NVS_KEY_INIT_SEQUENCE "init_seq"

/* UART Debug - ring buffer for logs */
#define UART_DEBUG_BUFFER_SIZE 4096
static char s_uart_log_buffer[UART_DEBUG_BUFFER_SIZE];
static int s_uart_log_head = 0;
static int s_uart_log_tail = 0;
static SemaphoreHandle_t s_uart_log_mutex = NULL;
static char s_init_sequence[512] = "AT+STOP\nAT+PROG=02\nAT+DEBUG=0\nAT+HEATIME=60\nAT+SENS=3\n";

/* Add to UART log buffer */
static void uart_log_add(const char *text, bool is_tx)
{
    if (!s_uart_log_mutex) return;
    
    int len = strlen(text);
    const char *prefix = is_tx ? "TX: " : "RX: ";
    
    xSemaphoreTake(s_uart_log_mutex, portMAX_DELAY);
    for (int i = 0; prefix[i] != '\0'; i++) {
        s_uart_log_buffer[s_uart_log_head] = prefix[i];
        s_uart_log_head = (s_uart_log_head + 1) % UART_DEBUG_BUFFER_SIZE;
    }
    for (int i = 0; i < len && i < 256; i++) {
        s_uart_log_buffer[s_uart_log_head] = text[i];
        s_uart_log_head = (s_uart_log_head + 1) % UART_DEBUG_BUFFER_SIZE;
    }
    xSemaphoreGive(s_uart_log_mutex);
}

/* Load init sequence from NVS */
static void load_uart_init_sequence(void)
{
    nvs_handle_t nvs_handle;
    esp_err_t err = nvs_open(NVS_NS_RADAR, NVS_READONLY, &nvs_handle);
    if (err == ESP_OK) {
        size_t len = sizeof(s_init_sequence);
        if (nvs_get_blob(nvs_handle, NVS_KEY_INIT_SEQUENCE, s_init_sequence, &len) == ESP_OK) {
            ESP_LOGI(TAG, "Loaded init sequence from NVS");
        }
        nvs_close(nvs_handle);
    }
}

/* UART input task for capturing radar data */
static void uart_input_task(void *arg)
{
    uint8_t buf[128];
    while (1) {
        int len = uart_read_bytes(RADAR_UART_NUM, buf, sizeof(buf) - 1, 100 / portTICK_PERIOD_MS);
        if (len > 0) {
            buf[len] = '\0';
            uart_log_add((const char *)buf, false);
        }
    }
}
#if 0
/* UART debug HTTP handlers */
static esp_err_t uart_debug_handler(httpd_req_t *req)
{
    char html[16384];
    int len = snprintf(html, sizeof(html), UART_DEBUG_HTML, s_init_sequence);
    httpd_resp_set_type(req, "text/html");
    httpd_resp_send(req, html, len);
    return ESP_OK;
}

static esp_err_t uart_debug_alias_handler(httpd_req_t *req)
{
    httpd_resp_set_status(req, "302 Found");
    httpd_resp_set_hdr(req, "Location", "/uart_debug");
    httpd_resp_send(req, NULL, 0);
    return ESP_OK;
}

static esp_err_t uart_send_handler(httpd_req_t *req)
{
    char content[256];
    int content_len = httpd_req_recv(req, content, sizeof(content) - 1);
    if (content_len <= 0) {
        httpd_resp_send(req, ERROR_JSON_PARSE, strlen(ERROR_JSON_PARSE));
        return ESP_FAIL;
    }
    content[content_len] = '\0';
    
    cJSON *root = cJSON_Parse(content);
    if (!root) {
        httpd_resp_send(req, ERROR_JSON_PARSE, strlen(ERROR_JSON_PARSE));
        return ESP_FAIL;
    }
    
    cJSON *cmd_item = cJSON_GetObjectItem(root, "cmd");
    if (!cmd_item || !cmd_item->valuestring) {
        cJSON_Delete(root);
        httpd_resp_send(req, ERROR_JSON_MISSING, strlen(ERROR_JSON_MISSING));
        return ESP_FAIL;
    }
    
    char cmd[128];
    strncpy(cmd, cmd_item->valuestring, sizeof(cmd) - 1);
    cmd[sizeof(cmd) - 1] = '\0';
    
    // Ensure newline
    if (strlen(cmd) > 0 && cmd[strlen(cmd) - 1] != '\n') {
        strncat(cmd, "\n", sizeof(cmd) - strlen(cmd) - 1);
    }
    
    uart_write_bytes(RADAR_UART_NUM, cmd, strlen(cmd));
    uart_log_add(cmd, true);
    
    cJSON_Delete(root);
    httpd_resp_send(req, SUCCESS_JSON, strlen(SUCCESS_JSON));
    return ESP_OK;
}

static esp_err_t uart_log_handler(httpd_req_t *req)
{
    httpd_resp_set_type(req, "text/event-stream");
    httpd_resp_set_hdr(req, "Cache-Control", "no-cache");
    httpd_resp_set_hdr(req, "Connection", "keep-alive");
    httpd_resp_set_hdr(req, "Access-Control-Allow-Origin", "*");
    
    char line[512];
    while (1) {
        xSemaphoreTake(s_uart_log_mutex, portMAX_DELAY);
        if (s_uart_log_tail != s_uart_log_head) {
            int i = 0;
            while (s_uart_log_tail != s_uart_log_head && i < sizeof(line) - 1) {
                line[i++] = s_uart_log_buffer[s_uart_log_tail];
                s_uart_log_tail = (s_uart_log_tail + 1) % UART_DEBUG_BUFFER_SIZE;
            }
            line[i] = '\0';
            xSemaphoreGive(s_uart_log_mutex);
            
            // Parse TX/RX
            bool is_tx = (line[0] == 'T' && line[1] == 'X');
            const char *text = line + 4; // Skip "TX: " or "RX: "
            
            char json[512];
            int len = snprintf(json, sizeof(json), "{\"text\":\"%s\",\"tx\":%s}\n\n",
                text, is_tx ? "true" : "false");
            httpd_resp_send_chunk(req, json, len);
            httpd_resp_send_chunk(req, "", 0); // Send to flush
        } else {
            xSemaphoreGive(s_uart_log_mutex);
            vTaskDelay(100 / portTICK_PERIOD_MS);
        }
        // Check if client disconnected
        if (httpd_req_recv(req, line, 0) <= 0) break;
    }
    return ESP_OK;
}

static esp_err_t uart_init_sequence_handler(httpd_req_t *req)
{
    char content[1024];
    int content_len = httpd_req_recv(req, content, sizeof(content) - 1);
    if (content_len <= 0) {
        httpd_resp_send(req, ERROR_JSON_PARSE, strlen(ERROR_JSON_PARSE));
        return ESP_FAIL;
    }
    content[content_len] = '\0';
    
    cJSON *root = cJSON_Parse(content);
    if (!root) {
        httpd_resp_send(req, ERROR_JSON_PARSE, strlen(ERROR_JSON_PARSE));
        return ESP_FAIL;
    }
    
    cJSON *seq_item = cJSON_GetObjectItem(root, "sequence");
    if (!seq_item || !seq_item->valuestring) {
        cJSON_Delete(root);
        httpd_resp_send(req, ERROR_JSON_MISSING, strlen(ERROR_JSON_MISSING));
        return ESP_FAIL;
    }
    
    strncpy(s_init_sequence, seq_item->valuestring, sizeof(s_init_sequence) - 1);
    s_init_sequence[sizeof(s_init_sequence) - 1] = '\0';
    
    // Save to NVS
    nvs_handle_t nvs_handle;
    esp_err_t err = nvs_open(NVS_NS_RADAR, NVS_READWRITE, &nvs_handle);
    if (err == ESP_OK) {
        nvs_set_blob(nvs_handle, NVS_KEY_INIT_SEQUENCE, s_init_sequence, sizeof(s_init_sequence));
        nvs_commit(nvs_handle);
        nvs_close(nvs_handle);
    }
    
    cJSON_Delete(root);
    httpd_resp_send(req, SUCCESS_JSON, strlen(SUCCESS_JSON));
    return ESP_OK;
}

static esp_err_t uart_send_sequence_handler(httpd_req_t *req)
{
    char *token = strtok(s_init_sequence, "\n");
    while (token) {
        char cmd[128] = {0};
        strncpy(cmd, token, sizeof(cmd) - 2);
        if (strlen(cmd) > 0) {
            uart_write_bytes(RADAR_UART_NUM, cmd, strlen(cmd));
            if (cmd[strlen(cmd) - 1] != '\n') {
                uart_write_bytes(RADAR_UART_NUM, "\n", 1);
            }
            uart_log_add(cmd, true);
            vTaskDelay(200 / portTICK_PERIOD_MS);
        }
        token = strtok(NULL, "\n");
    }
    httpd_resp_send(req, SUCCESS_JSON, strlen(SUCCESS_JSON));
    return ESP_OK;
}

static const httpd_uri_t uart_debug_uri = {
    .uri = "/uart_debug",
    .method = HTTP_GET,
    .handler = uart_debug_handler
};

static const httpd_uri_t uart_debug_alias_uri = {
    .uri = "/duart_debug",
    .method = HTTP_GET,
    .handler = uart_debug_alias_handler
};

static const httpd_uri_t uart_send_uri = {
    .uri = "/uart_send",
    .method = HTTP_POST,
    .handler = uart_send_handler
};

static const httpd_uri_t uart_log_uri = {
    .uri = "/uart_log",
    .method = HTTP_GET,
    .handler = uart_log_handler
};

static const httpd_uri_t uart_init_seq_uri = {
    .uri = "/uart_init_sequence",
    .method = HTTP_POST,
    .handler = uart_init_sequence_handler
};

static const httpd_uri_t uart_send_seq_uri = {
    .uri = "/uart_send_sequence",
    .method = HTTP_POST,
    .handler = uart_send_sequence_handler
};
#endif
/* Load WiFi credentials from NVS */
static esp_err_t load_wifi_credentials(void)
{
    // Set default values - empty (no network configured)
    s_wifi_ssid[0] = '\0';
    s_wifi_password[0] = '\0';
    
    nvs_handle_t nvs_handle;
    esp_err_t err = nvs_open(NVS_NS_WIFI, NVS_READONLY, &nvs_handle);
    if (err != ESP_OK) {
        ESP_LOGW(TAG, "NVS namespace '%s' not found, using defaults. Error: %s", 
                 NVS_NS_WIFI, esp_err_to_name(err));
        return ESP_OK; // Not an error - just use defaults (empty)
    }

    size_t ssid_len = sizeof(s_wifi_ssid);
    size_t password_len = sizeof(s_wifi_password);
    
    err = nvs_get_str(nvs_handle, NVS_KEY_SSID, s_wifi_ssid, &ssid_len);
    if (err == ESP_ERR_NVS_NOT_FOUND) {
        ESP_LOGW(TAG, "SSID not found in NVS, using default");
    } else if (err != ESP_OK) {
        ESP_LOGW(TAG, "Failed to get SSID from NVS: %s", esp_err_to_name(err));
    }
    
    err = nvs_get_str(nvs_handle, NVS_KEY_PASSWORD, s_wifi_password, &password_len);
    if (err == ESP_ERR_NVS_NOT_FOUND) {
        ESP_LOGW(TAG, "Password not found in NVS, using default");
    } else if (err != ESP_OK) {
        ESP_LOGW(TAG, "Failed to get password from NVS: %s", esp_err_to_name(err));
    }
    
    // Ensure null-termination after NVS read
    s_wifi_ssid[sizeof(s_wifi_ssid) - 1] = '\0';
    s_wifi_password[sizeof(s_wifi_password) - 1] = '\0';
    
    nvs_close(nvs_handle);
    ESP_LOGI(TAG, "Using WiFi credentials - SSID: %s", s_wifi_ssid);
    return ESP_OK;
}

/* Save WiFi credentials to NVS */
esp_err_t web_server_set_wifi_credentials(const char *ssid, const char *password)
{
    nvs_handle_t nvs_handle;
    esp_err_t err = nvs_open(NVS_NS_WIFI, NVS_READWRITE, &nvs_handle);
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "Failed to open NVS");
        return err;
    }

    err = nvs_set_str(nvs_handle, NVS_KEY_SSID, ssid);
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "Failed to set SSID");
        nvs_close(nvs_handle);
        return err;
    }

    err = nvs_set_str(nvs_handle, NVS_KEY_PASSWORD, password);
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "Failed to set password");
        nvs_close(nvs_handle);
        return err;
    }

    err = nvs_commit(nvs_handle);
    nvs_close(nvs_handle);
    
    if (err == ESP_OK) {
        strncpy(s_wifi_ssid, ssid, sizeof(s_wifi_ssid) - 1);
        strncpy(s_wifi_password, password, sizeof(s_wifi_password) - 1);
    }
    
    return err;
}

esp_err_t web_server_get_wifi_credentials(char *ssid, size_t ssid_len, char *password, size_t password_len)
{
    strncpy(ssid, s_wifi_ssid, ssid_len - 1);
    ssid[ssid_len - 1] = '\0';
    strncpy(password, s_wifi_password, password_len - 1);
    password[password_len - 1] = '\0';
    return ESP_OK;
}

/* Radar config NVS keys (namespace already defined at top) */
#define NVS_NS_RADAR "radar_config"
#define NVS_KEY_MOUNT_TYPE "mount"
#define NVS_KEY_HEIGHT "height"
#define NVS_KEY_DETECT_MIN "det_min"
#define NVS_KEY_DETECT_MAX "det_max"
#define NVS_KEY_SENSITIVITY "sensitivity"
#define NVS_KEY_LED_ENABLED "led"
#define NVS_KEY_LED_BRIGHTNESS "led_brightness"
#define NVS_KEY_FALL_THRESHOLD "fall_thresh"
#define NVS_KEY_FALL_HEIGHT_DROP "fall_drop"
#define NVS_KEY_FALL_HOLD_TIME "fall_hold"
#define NVS_KEY_HUMAN_CONF "human_conf"
#define NVS_KEY_STANDING_Z "standing_z"
#define NVS_KEY_SITTING_Z "sitting_z"
#define NVS_KEY_LYING_Z "lying_z"
#define NVS_KEY_CONF_SNR_MAX "conf_snr"
#define NVS_KEY_CONF_ABS_MAX "conf_abs"
#define NVS_KEY_CONF_DPK_MAX "conf_dpk"
#define NVS_KEY_CONF_POINT_THRESH "conf_pt_th"

/* Load radar configuration from NVS */
static void load_radar_config(void)
{
    nvs_handle_t nvs_handle;
    esp_err_t err = nvs_open(NVS_NS_RADAR, NVS_READONLY, &nvs_handle);
    if (err != ESP_OK) {
        ESP_LOGI(TAG, "Using default radar config");
        return;
    }

    int32_t val;
    if (nvs_get_i32(nvs_handle, NVS_KEY_MOUNT_TYPE, &val) == ESP_OK) s_radar_config.mount_type = val;
    if (nvs_get_i32(nvs_handle, NVS_KEY_HEIGHT, &val) == ESP_OK) s_radar_config.height = (float)val / 100.0f;
    if (nvs_get_i32(nvs_handle, NVS_KEY_DETECT_MIN, &val) == ESP_OK) s_radar_config.detection_min = (float)val / 100.0f;
    if (nvs_get_i32(nvs_handle, NVS_KEY_DETECT_MAX, &val) == ESP_OK) s_radar_config.detection_max = (float)val / 100.0f;
    if (nvs_get_i32(nvs_handle, NVS_KEY_SENSITIVITY, &val) == ESP_OK) s_radar_config.sensitivity = val;
    if (nvs_get_i32(nvs_handle, NVS_KEY_LED_ENABLED, &val) == ESP_OK) s_radar_config.led_enabled = val;
    if (nvs_get_i32(nvs_handle, NVS_KEY_LED_BRIGHTNESS, &val) == ESP_OK) s_radar_config.led_brightness = val;
    if (nvs_get_i32(nvs_handle, NVS_KEY_FALL_THRESHOLD, &val) == ESP_OK) s_radar_config.fall_threshold = (float)val / 100.0f;
    if (nvs_get_i32(nvs_handle, NVS_KEY_FALL_HEIGHT_DROP, &val) == ESP_OK) s_radar_config.fall_height_drop = (float)val / 100.0f;
    if (nvs_get_i32(nvs_handle, NVS_KEY_FALL_HOLD_TIME, &val) == ESP_OK) s_radar_config.fall_hold_time = val;
    if (nvs_get_i32(nvs_handle, NVS_KEY_HUMAN_CONF, &val) == ESP_OK) s_radar_config.human_confidence = (float)val / 100.0f;
    if (nvs_get_i32(nvs_handle, NVS_KEY_STANDING_Z, &val) == ESP_OK) s_radar_config.standing_z = (float)val / 100.0f;
    if (nvs_get_i32(nvs_handle, NVS_KEY_SITTING_Z, &val) == ESP_OK) s_radar_config.sitting_z = (float)val / 100.0f;
    if (nvs_get_i32(nvs_handle, NVS_KEY_LYING_Z, &val) == ESP_OK) s_radar_config.lying_z = (float)val / 100.0f;
    if (nvs_get_i32(nvs_handle, NVS_KEY_CONF_SNR_MAX, &val) == ESP_OK) s_radar_config.conf_snr_max = (float)val / 100.0f;
    if (nvs_get_i32(nvs_handle, NVS_KEY_CONF_ABS_MAX, &val) == ESP_OK) s_radar_config.conf_abs_max = (float)val / 100.0f;
    if (nvs_get_i32(nvs_handle, NVS_KEY_CONF_DPK_MAX, &val) == ESP_OK) s_radar_config.conf_dpk_max = (float)val / 100.0f;
    if (nvs_get_i32(nvs_handle, NVS_KEY_CONF_POINT_THRESH, &val) == ESP_OK) s_radar_config.conf_point_threshold = (float)val / 100.0f;

    nvs_close(nvs_handle);
    ESP_LOGI(TAG, "Loaded radar config from NVS");
}

/* Save radar configuration to NVS */
esp_err_t web_server_set_radar_config(const radar_config_web_t *config)
{
    nvs_handle_t nvs_handle;
    esp_err_t err = nvs_open(NVS_NS_RADAR, NVS_READWRITE, &nvs_handle);
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "Failed to open radar NVS");
        return err;
    }

    esp_err_t set_err = ESP_OK;
    set_err |= nvs_set_i32(nvs_handle, NVS_KEY_MOUNT_TYPE, config->mount_type);
    set_err |= nvs_set_i32(nvs_handle, NVS_KEY_HEIGHT, (int32_t)(config->height * 100));
    set_err |= nvs_set_i32(nvs_handle, NVS_KEY_DETECT_MIN, (int32_t)(config->detection_min * 100));
    set_err |= nvs_set_i32(nvs_handle, NVS_KEY_DETECT_MAX, (int32_t)(config->detection_max * 100));
    set_err |= nvs_set_i32(nvs_handle, NVS_KEY_SENSITIVITY, config->sensitivity);
    set_err |= nvs_set_i32(nvs_handle, NVS_KEY_LED_ENABLED, config->led_enabled);
    set_err |= nvs_set_i32(nvs_handle, NVS_KEY_LED_BRIGHTNESS, config->led_brightness);
    set_err |= nvs_set_i32(nvs_handle, NVS_KEY_FALL_THRESHOLD, (int32_t)(config->fall_threshold * 100));
    set_err |= nvs_set_i32(nvs_handle, NVS_KEY_FALL_HEIGHT_DROP, (int32_t)(config->fall_height_drop * 100));
    set_err |= nvs_set_i32(nvs_handle, NVS_KEY_FALL_HOLD_TIME, config->fall_hold_time);
    set_err |= nvs_set_i32(nvs_handle, NVS_KEY_HUMAN_CONF, (int32_t)(config->human_confidence * 100));
    set_err |= nvs_set_i32(nvs_handle, NVS_KEY_STANDING_Z, (int32_t)(config->standing_z * 100));
    set_err |= nvs_set_i32(nvs_handle, NVS_KEY_SITTING_Z, (int32_t)(config->sitting_z * 100));
    set_err |= nvs_set_i32(nvs_handle, NVS_KEY_LYING_Z, (int32_t)(config->lying_z * 100));
    set_err |= nvs_set_i32(nvs_handle, NVS_KEY_CONF_SNR_MAX, (int32_t)(config->conf_snr_max * 100));
    set_err |= nvs_set_i32(nvs_handle, NVS_KEY_CONF_ABS_MAX, (int32_t)(config->conf_abs_max * 100));
    set_err |= nvs_set_i32(nvs_handle, NVS_KEY_CONF_DPK_MAX, (int32_t)(config->conf_dpk_max * 100));
    set_err |= nvs_set_i32(nvs_handle, NVS_KEY_CONF_POINT_THRESH, (int32_t)(config->conf_point_threshold * 100));
    if (set_err != ESP_OK) {
        ESP_LOGW(TAG, "One or more radar config fields failed to write to NVS");
    }

    err = nvs_commit(nvs_handle);
    nvs_close(nvs_handle);
    
    // Update current config
    s_radar_config = *config;
    
    return err;
}

/* Get radar configuration */
void web_server_get_radar_config(radar_config_web_t *config)
{
    *config = s_radar_config;
}

/* Pushes the persisted radar settings (s_radar_config) into the live
 * detection engine (radar_sensor.c's s_config). Previously these were
 * saved to NVS and echoed back by /radar_status, but radar_sensor_init()
 * was only ever called with RADAR_CONFIG_DEFAULT() - none of this ever
 * reached the actual detection code. Call this once after
 * radar_sensor_init() succeeds (see fall_sense_x_main.c), and again
 * whenever radar settings are saved or calibrated, to apply changes live
 * without requiring a reboot. */
void web_server_apply_radar_config(void)
{
    radar_config_t cfg;
    radar_sensor_get_config(&cfg);

    cfg.standing_z = s_radar_config.standing_z;
    cfg.sitting_z = s_radar_config.sitting_z;
    cfg.lying_z = s_radar_config.lying_z;
    cfg.human_conf_threshold = s_radar_config.human_confidence;
    cfg.point_conf_snr_max = s_radar_config.conf_snr_max;
    cfg.point_conf_abs_max = s_radar_config.conf_abs_max;
    cfg.point_conf_dpk_max = s_radar_config.conf_dpk_max;
    cfg.point_conf_threshold = s_radar_config.conf_point_threshold;

    radar_sensor_set_config(&cfg);
    ESP_LOGI(TAG, "Applied radar config: standing_z=%.2f sitting_z=%.2f lying_z=%.2f human_conf=%.2f "
                  "conf_snr_max=%.1f conf_abs_max=%.1f conf_dpk_max=%.1f conf_point_thresh=%.2f",
             cfg.standing_z, cfg.sitting_z, cfg.lying_z, cfg.human_conf_threshold,
             cfg.point_conf_snr_max, cfg.point_conf_abs_max, cfg.point_conf_dpk_max, cfg.point_conf_threshold);
}

/* Get LED brightness (0-100) */
int web_server_get_led_brightness(void)
{
    return s_radar_config.led_brightness;
}

/* Radar HTTP handlers */
static esp_err_t radar_status_handler(httpd_req_t *req)
{
    char json[640];
    int len = snprintf(json, sizeof(json),
        "{\"mountType\":%d,\"height\":%.1f,\"detMin\":%.1f,\"detMax\":%.1f,\"sensitivity\":%d,\"ledEnabled\":%d,\"ledBrightness\":%d,"
        "\"humanConf\":%.2f,\"fallThresh\":%.2f,\"fallDrop\":%.2f,\"fallHold\":%d,"
        "\"standingZ\":%.2f,\"sittingZ\":%.2f,\"lyingZ\":%.2f,"
        "\"confSnrMax\":%.1f,\"confAbsMax\":%.1f,\"confDpkMax\":%.1f,\"confPointThresh\":%.2f}",
        s_radar_config.mount_type,
        s_radar_config.height,
        s_radar_config.detection_min,
        s_radar_config.detection_max,
        s_radar_config.sensitivity,
        s_radar_config.led_enabled,
        s_radar_config.led_brightness,
        s_radar_config.human_confidence,
        s_radar_config.fall_threshold,
        s_radar_config.fall_height_drop,
        s_radar_config.fall_hold_time,
        s_radar_config.standing_z,
        s_radar_config.sitting_z,
        s_radar_config.lying_z,
        s_radar_config.conf_snr_max,
        s_radar_config.conf_abs_max,
        s_radar_config.conf_dpk_max,
        s_radar_config.conf_point_threshold
    );

    httpd_resp_set_type(req, "application/json");
    httpd_resp_send(req, json, len);
    return ESP_OK;
}

static esp_err_t radar_save_handler(httpd_req_t *req)
{
    if (!device_pin_require(req)) {
        return ESP_OK;
    }
    char content[512];
    int content_len = httpd_req_recv(req, content, sizeof(content) - 1);
    if (content_len <= 0) {
        httpd_resp_send(req, ERROR_JSON_PARSE, strlen(ERROR_JSON_PARSE));
        return ESP_FAIL;
    }
    content[content_len] = '\0';

    cJSON *root = cJSON_Parse(content);
    if (!root) {
        httpd_resp_send(req, ERROR_JSON_PARSE, strlen(ERROR_JSON_PARSE));
        return ESP_FAIL;
    }

    radar_config_web_t new_config = s_radar_config;
    
    cJSON *item;
    if ((item = cJSON_GetObjectItem(root, "mountType"))) new_config.mount_type = item->valueint;
    if ((item = cJSON_GetObjectItem(root, "height"))) new_config.height = item->valuedouble;
    if ((item = cJSON_GetObjectItem(root, "detMin"))) new_config.detection_min = item->valuedouble;
    if ((item = cJSON_GetObjectItem(root, "detMax"))) new_config.detection_max = item->valuedouble;
    if ((item = cJSON_GetObjectItem(root, "sensitivity"))) new_config.sensitivity = item->valueint;
    if ((item = cJSON_GetObjectItem(root, "ledEnabled"))) new_config.led_enabled = item->valueint;
    if ((item = cJSON_GetObjectItem(root, "ledBrightness"))) new_config.led_brightness = item->valueint;
    if ((item = cJSON_GetObjectItem(root, "humanConf"))) new_config.human_confidence = item->valuedouble;
    if ((item = cJSON_GetObjectItem(root, "fallThresh"))) new_config.fall_threshold = item->valuedouble;
    if ((item = cJSON_GetObjectItem(root, "fallDrop"))) new_config.fall_height_drop = item->valuedouble;
    if ((item = cJSON_GetObjectItem(root, "fallHold"))) new_config.fall_hold_time = item->valueint;
    if ((item = cJSON_GetObjectItem(root, "standingZ"))) new_config.standing_z = item->valuedouble;
    if ((item = cJSON_GetObjectItem(root, "sittingZ"))) new_config.sitting_z = item->valuedouble;
    if ((item = cJSON_GetObjectItem(root, "lyingZ"))) new_config.lying_z = item->valuedouble;
    if ((item = cJSON_GetObjectItem(root, "confSnrMax"))) new_config.conf_snr_max = item->valuedouble;
    if ((item = cJSON_GetObjectItem(root, "confAbsMax"))) new_config.conf_abs_max = item->valuedouble;
    if ((item = cJSON_GetObjectItem(root, "confDpkMax"))) new_config.conf_dpk_max = item->valuedouble;
    if ((item = cJSON_GetObjectItem(root, "confPointThresh"))) new_config.conf_point_threshold = item->valuedouble;

    cJSON_Delete(root);

    esp_err_t err = web_server_set_radar_config(&new_config);
    if (err == ESP_OK) {
        web_server_apply_radar_config();
        httpd_resp_send(req, SUCCESS_JSON, strlen(SUCCESS_JSON));
        ESP_LOGI(TAG, "Radar config saved, restarting...");
        vTaskDelay(pdMS_TO_TICKS(500));
        esp_restart();
    } else {
        char error_buf[128];
        snprintf(error_buf, sizeof(error_buf), ERROR_JSON, "Failed to save");
        httpd_resp_send(req, error_buf, strlen(error_buf));
    }
    return ESP_OK;
}

static esp_err_t radar_reset_handler(httpd_req_t *req)
{
    if (!device_pin_require(req)) {
        return ESP_OK;
    }
    // Reset to defaults
    s_radar_config.mount_type = 0;
    s_radar_config.height = 2.5f;
    s_radar_config.detection_min = 0.5f;
    s_radar_config.detection_max = 6.0f;
    s_radar_config.sensitivity = 5;
    s_radar_config.led_enabled = 1;
    s_radar_config.fall_threshold = 0.5f;
    s_radar_config.fall_height_drop = 0.25f;
    s_radar_config.fall_hold_time = 5;
    s_radar_config.human_confidence = 0.3f;
    s_radar_config.standing_z = 1.0f;
    s_radar_config.sitting_z = 0.6f;
    s_radar_config.lying_z = 0.25f;
    s_radar_config.conf_snr_max = 40.0f;
    s_radar_config.conf_abs_max = 15.0f;
    s_radar_config.conf_dpk_max = 10.0f;
    s_radar_config.conf_point_threshold = 0.4f;

    // Erase only radar config namespace (not all NVS)
    nvs_handle_t nvs_handle;
    esp_err_t err = nvs_open(NVS_NS_RADAR, NVS_READWRITE, &nvs_handle);
    if (err == ESP_OK) {
        esp_err_t erase_err = nvs_erase_all(nvs_handle);
        if (erase_err != ESP_OK) {
            ESP_LOGW(TAG, "Failed to erase radar NVS namespace: %s", esp_err_to_name(erase_err));
        }
        nvs_close(nvs_handle);
    } else {
        ESP_LOGW(TAG, "Failed to open radar NVS namespace for reset: %s", esp_err_to_name(err));
    }
    
    // Save defaults to radar config namespace
    web_server_set_radar_config(&s_radar_config);
    
    httpd_resp_send(req, SUCCESS_JSON, strlen(SUCCESS_JSON));
    ESP_LOGI(TAG, "Radar config reset to defaults, restarting...");
    vTaskDelay(pdMS_TO_TICKS(500));
    esp_restart();
    return ESP_OK;
}

/* Captures the current detected target's height (the same 85th-percentile
 * metric classify_posture() uses) and uses it to derive the
 * standing/sitting/lying threshold for that posture, instead of relying
 * on the fixed constants that assume a specific sensor mount height.
 * Applies live immediately (no reboot needed) - stand/sit/lie under the
 * sensor, hit the matching button, repeat for the other two postures. */
static esp_err_t radar_calibrate_handler(httpd_req_t *req)
{
    if (!device_pin_require(req)) {
        return ESP_OK;
    }

    char content[128];
    int content_len = httpd_req_recv(req, content, sizeof(content) - 1);
    if (content_len <= 0) {
        httpd_resp_send(req, ERROR_JSON_PARSE, strlen(ERROR_JSON_PARSE));
        return ESP_FAIL;
    }
    content[content_len] = '\0';

    cJSON *root = cJSON_Parse(content);
    if (!root) {
        httpd_resp_send(req, ERROR_JSON_PARSE, strlen(ERROR_JSON_PARSE));
        return ESP_FAIL;
    }
    cJSON *phase_item = cJSON_GetObjectItem(root, "phase");
    if (!phase_item || !phase_item->valuestring) {
        cJSON_Delete(root);
        httpd_resp_send(req, ERROR_JSON_MISSING, strlen(ERROR_JSON_MISSING));
        return ESP_FAIL;
    }
    char phase[16];
    strncpy(phase, phase_item->valuestring, sizeof(phase) - 1);
    phase[sizeof(phase) - 1] = '\0';
    cJSON_Delete(root);

    int count = 0;
    const human_target_t *targets = radar_get_targets(&count);
    if (count == 0) {
        char buf[160];
        snprintf(buf, sizeof(buf), ERROR_JSON, "No person detected - stand under the sensor and try again");
        httpd_resp_send(req, buf, strlen(buf));
        return ESP_OK;
    }

    int best = 0;
    for (int i = 1; i < count; i++) {
        if (targets[i].confidence > targets[best].confidence) best = i;
    }
    float captured_height = targets[best].height;

    /* Margins push the threshold slightly inside the captured value so
     * normal frame-to-frame jitter during real use doesn't sit right on
     * the boundary. lying_z's margin is larger because classify_posture()
     * compares against (lying_z + 0.2f), not lying_z directly. */
    float new_value;
    if (strcmp(phase, "standing") == 0) {
        new_value = captured_height - 0.05f;
        s_radar_config.standing_z = new_value;
    } else if (strcmp(phase, "sitting") == 0) {
        new_value = captured_height - 0.05f;
        s_radar_config.sitting_z = new_value;
    } else if (strcmp(phase, "lying") == 0) {
        new_value = captured_height - 0.25f;
        s_radar_config.lying_z = new_value;
    } else {
        char buf[160];
        snprintf(buf, sizeof(buf), ERROR_JSON, "phase must be 'standing', 'sitting', or 'lying'");
        httpd_resp_send(req, buf, strlen(buf));
        return ESP_OK;
    }

    bool order_ok = (s_radar_config.standing_z > s_radar_config.sitting_z) &&
                     (s_radar_config.sitting_z > s_radar_config.lying_z + 0.2f);
    if (!order_ok) {
        ESP_LOGW(TAG, "Calibrated thresholds look out of order (standing=%.2f sitting=%.2f lying=%.2f) - "
                      "double check you captured each posture correctly",
                 s_radar_config.standing_z, s_radar_config.sitting_z, s_radar_config.lying_z);
    }

    esp_err_t err = web_server_set_radar_config(&s_radar_config);
    web_server_apply_radar_config();

    char buf[224];
    if (err == ESP_OK) {
        snprintf(buf, sizeof(buf),
                 "{\"success\":true,\"phase\":\"%s\",\"capturedHeight\":%.3f,\"appliedThreshold\":%.3f,\"thresholdsOrdered\":%s}",
                 phase, captured_height, new_value, order_ok ? "true" : "false");
    } else {
        snprintf(buf, sizeof(buf), ERROR_JSON, "Failed to persist calibration");
    }
    httpd_resp_send(req, buf, strlen(buf));
    return ESP_OK;
}

static esp_err_t pin_change_handler(httpd_req_t *req)
{
    char content[256];
    int content_len = httpd_req_recv(req, content, sizeof(content) - 1);
    if (content_len <= 0) {
        httpd_resp_send(req, ERROR_JSON_PARSE, strlen(ERROR_JSON_PARSE));
        return ESP_FAIL;
    }
    content[content_len] = '\0';

    cJSON *root = cJSON_Parse(content);
    if (!root) {
        httpd_resp_send(req, ERROR_JSON_PARSE, strlen(ERROR_JSON_PARSE));
        return ESP_FAIL;
    }

    cJSON *old_pin = cJSON_GetObjectItem(root, "oldPin");
    cJSON *new_pin = cJSON_GetObjectItem(root, "newPin");
    if (!old_pin || !new_pin || !old_pin->valuestring || !new_pin->valuestring) {
        cJSON_Delete(root);
        httpd_resp_send(req, ERROR_JSON_MISSING, strlen(ERROR_JSON_MISSING));
        return ESP_FAIL;
    }

    esp_err_t err = device_pin_change(old_pin->valuestring, new_pin->valuestring);
    cJSON_Delete(root);

    if (err == ESP_OK) {
        httpd_resp_send(req, SUCCESS_JSON, strlen(SUCCESS_JSON));
        ESP_LOGI(TAG, "Device PIN changed via web");
    } else {
        char error_buf[128];
        const char *msg = (err == ESP_ERR_INVALID_STATE) ? "Incorrect current PIN" : "Failed to change PIN";
        snprintf(error_buf, sizeof(error_buf), ERROR_JSON, msg);
        httpd_resp_send(req, error_buf, strlen(error_buf));
    }
    return ESP_OK;
}

static const httpd_uri_t pin_change_uri = {
    .uri = "/pin_change",
    .method = HTTP_POST,
    .handler = pin_change_handler
};

static esp_err_t restart_handler(httpd_req_t *req)
{
    if (!device_pin_require(req)) {
        return ESP_OK;
    }
    httpd_resp_send(req, SUCCESS_JSON, strlen(SUCCESS_JSON));
    ESP_LOGI(TAG, "Restart requested via web");
    vTaskDelay(pdMS_TO_TICKS(500));
    esp_restart();
    return ESP_OK;
}

/* HTTP Handlers */
// Use static buffer to avoid stack overflow
static char s_html_buffer[16384];

static void json_escape(char *dst, size_t dst_len, const char *src)
{
    if (dst == NULL || dst_len == 0) {
        return;
    }

    size_t out = 0;
    for (size_t i = 0; src != NULL && src[i] != '\0' && out + 1 < dst_len; i++) {
        char c = src[i];
        if (c == '"' || c == '\\') {
            if (out + 2 >= dst_len) {
                break;
            }
            dst[out++] = '\\';
            dst[out++] = c;
        } else if (c == '\n') {
            if (out + 2 >= dst_len) {
                break;
            }
            dst[out++] = '\\';
            dst[out++] = 'n';
        } else if (c == '\r') {
            if (out + 2 >= dst_len) {
                break;
            }
            dst[out++] = '\\';
            dst[out++] = 'r';
        } else {
            dst[out++] = c;
        }
    }
    dst[out] = '\0';
}

static const char *wifi_auth_mode_string(wifi_auth_mode_t authmode)
{
    switch (authmode) {
        case WIFI_AUTH_OPEN:
            return "Open";
        case WIFI_AUTH_WEP:
            return "WEP";
        case WIFI_AUTH_WPA_PSK:
            return "WPA";
        case WIFI_AUTH_WPA2_PSK:
            return "WPA2";
        case WIFI_AUTH_WPA_WPA2_PSK:
            return "WPA/WPA2";
        case WIFI_AUTH_WPA2_ENTERPRISE:
            return "WPA2-Enterprise";
        case WIFI_AUTH_WPA3_PSK:
            return "WPA3";
        case WIFI_AUTH_WPA2_WPA3_PSK:
            return "WPA2/WPA3";
        default:
            return "Unknown";
    }
}

static void ensure_default_wifi_sta_netif(void)
{
    if (esp_netif_get_handle_from_ifkey("WIFI_STA_DEF") == NULL) {
        esp_netif_create_default_wifi_sta();
    }
}

static esp_err_t wifi_scan_handler(httpd_req_t *req)
{
    char response[4096];
    wifi_ap_record_t ap_records[12];
    uint16_t ap_count = sizeof(ap_records) / sizeof(ap_records[0]);
    wifi_mode_t original_mode = WIFI_MODE_NULL;
    bool restore_ap_mode = false;

    esp_err_t err = esp_wifi_get_mode(&original_mode);
    if (err != ESP_OK) {
        snprintf(response, sizeof(response), ERROR_JSON, "WiFi mode query failed");
        httpd_resp_send(req, response, strlen(response));
        return ESP_FAIL;
    }

    if (original_mode == WIFI_MODE_AP) {
        ensure_default_wifi_sta_netif();
        err = esp_wifi_set_mode(WIFI_MODE_APSTA);
        if (err != ESP_OK) {
            snprintf(response, sizeof(response), ERROR_JSON, "Failed to enable scan mode");
            httpd_resp_send(req, response, strlen(response));
            return ESP_FAIL;
        }
        restore_ap_mode = true;
    }

    wifi_scan_config_t scan_config = {
        .ssid = NULL,
        .bssid = NULL,
        .channel = 0,
        .show_hidden = true,
    };

    err = esp_wifi_scan_start(&scan_config, true);
    if (err == ESP_OK) {
        ap_count = sizeof(ap_records) / sizeof(ap_records[0]);
        err = esp_wifi_scan_get_ap_records(&ap_count, ap_records);
    }

    if (restore_ap_mode) {
        esp_wifi_set_mode(WIFI_MODE_AP);
    }

    if (err != ESP_OK) {
        snprintf(response, sizeof(response), ERROR_JSON, "WiFi scan failed");
        httpd_resp_send(req, response, strlen(response));
        return ESP_FAIL;
    }

    int offset = snprintf(response, sizeof(response),
        "{\"success\":true,\"count\":%u,\"networks\":[", ap_count);
    for (uint16_t i = 0; i < ap_count; i++) {
        char ssid[33];
        json_escape(ssid, sizeof(ssid), (const char *)ap_records[i].ssid);
        offset += snprintf(response + offset, sizeof(response) - offset,
            "%s{\"ssid\":\"%s\",\"rssi\":%d,\"channel\":%u,\"auth\":\"%s\"}",
            i == 0 ? "" : ",",
            ssid,
            ap_records[i].rssi,
            ap_records[i].primary,
            wifi_auth_mode_string(ap_records[i].authmode));
        if (offset < 0 || offset >= sizeof(response)) {
            break;
        }
    }

    offset += snprintf(response + offset, sizeof(response) - offset, "]}");
    if (offset < 0 || offset >= sizeof(response)) {
        snprintf(response, sizeof(response), ERROR_JSON, "WiFi scan response too large");
    }

    httpd_resp_set_type(req, "application/json");
    httpd_resp_send(req, response, strlen(response));
    return ESP_OK;
}

static esp_err_t index_handler(httpd_req_t *req)
{
    s_wifi_ssid[sizeof(s_wifi_ssid) - 1] = '\0';
    s_wifi_password[sizeof(s_wifi_password) - 1] = '\0';


    int len = snprintf(s_html_buffer, sizeof(s_html_buffer), INDEX_HTML, s_wifi_ssid, s_wifi_password);
    if (len < 0 || len >= sizeof(s_html_buffer)) {
        ESP_LOGE(TAG, "HTML buffer overflow");
        httpd_resp_send_500(req);
        return ESP_FAIL;
    }

    httpd_resp_set_type(req, "text/html");
    httpd_resp_send(req, s_html_buffer, len);
    return ESP_OK;
}

static esp_err_t save_handler(httpd_req_t *req)
{
    if (!device_pin_require(req)) {
        return ESP_OK;
    }
    char content[512];
    int content_len = httpd_req_recv(req, content, sizeof(content) - 1);
    if (content_len <= 0) {
        httpd_resp_send(req, ERROR_JSON_PARSE, strlen(ERROR_JSON_PARSE));
        return ESP_FAIL;
    }
    content[content_len] = '\0';

    cJSON *root = cJSON_Parse(content);
    if (!root) {
        httpd_resp_send(req, ERROR_JSON_PARSE, strlen(ERROR_JSON_PARSE));
        return ESP_FAIL;
    }

    cJSON *ssid_item = cJSON_GetObjectItem(root, "ssid");
    cJSON *password_item = cJSON_GetObjectItem(root, "password");
    
    if (!ssid_item || !password_item || !ssid_item->valuestring || !password_item->valuestring) {
        cJSON_Delete(root);
        httpd_resp_send(req, ERROR_JSON_MISSING, strlen(ERROR_JSON_MISSING));
        return ESP_FAIL;
    }

    esp_err_t err = web_server_set_wifi_credentials(ssid_item->valuestring, password_item->valuestring);
    cJSON_Delete(root);

    if (err == ESP_OK) {
        httpd_resp_send(req, SUCCESS_JSON, strlen(SUCCESS_JSON));
        // Give time for response to be sent, then restart
        ESP_LOGI(TAG, "WiFi credentials saved, restarting in 1 second...");
        vTaskDelay(pdMS_TO_TICKS(500));
        esp_restart();
    } else {
        char error_buf[128];
        snprintf(error_buf, sizeof(error_buf), ERROR_JSON, "Failed to save");
        httpd_resp_send(req, error_buf, strlen(error_buf));
    }
    
    return ESP_OK;
}

static esp_err_t status_handler(httpd_req_t *req)
{
    char status_json[512];
    const char *mode_str = (s_device_mode == DEVICE_MODE_CONFIG) ? "Config" : "Normal";
    
    uint8_t mac[6];
    esp_wifi_get_mac(ESP_IF_WIFI_AP, mac);
    
    // Get CPU usage (free heap memory as a proxy for load)
    uint32_t free_heap = esp_get_free_heap_size();
    
    // CPU temperature (internal sensor - may not be available on all chips)
    float cpu_temp = 0.0f;
    #ifdef CONFIG_ESP32S3_INTERNAL_TEMP_ENABLED
    // Try to read internal temperature if available
    // This is a placeholder - actual implementation depends on ESP-IDF version
    #endif
    
    snprintf(status_json, sizeof(status_json),
        "{\"mode\":\"%s\",\"mac\":\"%02X:%02X:%02X:%02X:%02X:%02X\",\"ssid\":\"%s\",\"freeHeap\":%u,\"cpuTemp\":%.1f}",
        mode_str, mac[0], mac[1], mac[2], mac[3], mac[4], mac[5], s_wifi_ssid,
        free_heap, cpu_temp);

    httpd_resp_set_type(req, "application/json");
    httpd_resp_send(req, status_json, strlen(status_json));
    return ESP_OK;
}

static esp_err_t mode_handler(httpd_req_t *req)
{
    if (req->method == HTTP_POST) {
        if (!device_pin_require(req)) {
            return ESP_OK;
        }
        char content[128];
        int content_len = httpd_req_recv(req, content, sizeof(content) - 1);
        if (content_len > 0) {
            content[content_len] = '\0';
            
            cJSON *root = cJSON_Parse(content);
            if (root) {
                cJSON *mode_item = cJSON_GetObjectItem(root, "mode");
                if (mode_item && mode_item->valuestring) {
                    if (strcmp(mode_item->valuestring, "config") == 0) {
                        web_server_set_device_mode(DEVICE_MODE_CONFIG);
                    } else if (strcmp(mode_item->valuestring, "normal") == 0) {
                        web_server_set_device_mode(DEVICE_MODE_NORMAL);
                    }
                }
                cJSON_Delete(root);
            }
        }
    }
    
    const char *mode_str = (s_device_mode == DEVICE_MODE_CONFIG) ? "config" : "normal";
    char response[64];
    snprintf(response, sizeof(response), "{\"mode\":\"%s\"}", mode_str);
    httpd_resp_set_type(req, "application/json");
    httpd_resp_send(req, response, strlen(response));
    return ESP_OK;
}

static const httpd_uri_t index_uri = {
    .uri = "/",
    .method = HTTP_GET,
    .handler = index_handler
};

static const httpd_uri_t save_uri = {
    .uri = "/save",
    .method = HTTP_POST,
    .handler = save_handler
};

static const httpd_uri_t status_uri = {
    .uri = "/status",
    .method = HTTP_GET,
    .handler = status_handler
};

static const httpd_uri_t wifi_scan_uri = {
    .uri = "/wifi_scan",
    .method = HTTP_GET,
    .handler = wifi_scan_handler
};

static const httpd_uri_t mode_uri = {
    .uri = "/mode",
    .method = HTTP_POST,
    .handler = mode_handler
};

static const httpd_uri_t radar_status_uri = {
    .uri = "/radar_status",
    .method = HTTP_GET,
    .handler = radar_status_handler
};

static const httpd_uri_t radar_save_uri = {
    .uri = "/radar_save",
    .method = HTTP_POST,
    .handler = radar_save_handler
};

static const httpd_uri_t radar_reset_uri = {
    .uri = "/radar_reset",
    .method = HTTP_POST,
    .handler = radar_reset_handler
};

static const httpd_uri_t radar_calibrate_uri = {
    .uri = "/radar_calibrate",
    .method = HTTP_POST,
    .handler = radar_calibrate_handler
};

static const httpd_uri_t restart_uri = {
    .uri = "/restart",
    .method = HTTP_POST,
    .handler = restart_handler
};

esp_err_t web_server_init(const web_server_config_t *config)
{
    ESP_LOGI(TAG, "web_server_init: starting...");
    
    if (config) {
        s_mode_change_callback = config->mode_change_callback;
        if (config->ssid) {
            strncpy(s_wifi_ssid, config->ssid, sizeof(s_wifi_ssid) - 1);
        }
        if (config->password) {
            strncpy(s_wifi_password, config->password, sizeof(s_wifi_password) - 1);
        }
    }
    
    /* Load saved credentials from NVS */
    ESP_LOGI(TAG, "web_server_init: loading WiFi credentials...");
    load_wifi_credentials();
    
    /* Load radar config from NVS */
    load_radar_config();

    /* Initialize device PIN (generates a random default on first boot) */
    esp_err_t pin_err = device_pin_init();
    if (pin_err != ESP_OK) {
        ESP_LOGE(TAG, "device_pin_init failed: %s", esp_err_to_name(pin_err));
    }

    /* Load init sequence from NVS */
    
    /* Initialize UART log mutex */
    
    ESP_LOGI(TAG, "web_server_init: complete");
    return ESP_OK;
}

esp_err_t web_server_start(void)
{
    if (s_http_server) {
        ESP_LOGW(TAG, "HTTP server already running");
        return ESP_OK;
    }

    httpd_config_t config = HTTPD_DEFAULT_CONFIG();
    config.server_port = WEB_SERVER_PORT;
    /* Must be >= the number of httpd_register_uri_handler() calls below.
     * httpd_start() allocates a fixed-size handler table of this length;
     * once full, httpd_register_uri_handler() silently fails (returns
     * ESP_ERR_HTTPD_HANDLERS_FULL) for every handler after the limit,
     * which then 404s as if the route never existed. Left at the old
     * value of 11 here for a while after more OTA/PIN routes were added,
     * which is exactly what caused /ota_status, /ota_update, and
     * /pin_change to silently stop responding - kept some headroom this
     * time so adding one or two more routes doesn't reintroduce the same
     * bug. */
    config.max_uri_handlers = 20;
    config.ctrl_port = 32768;
    config.stack_size = 8192;

    ESP_LOGI(TAG, "Starting HTTP server on port %d...", WEB_SERVER_PORT);
    
    esp_err_t err = httpd_start(&s_http_server, &config);
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "Failed to start HTTP server: %s (error %d)", esp_err_to_name(err), err);
        return err;
    }

    const httpd_uri_t *uri_handlers[] = {
        &index_uri, &save_uri, &status_uri, &wifi_scan_uri, &mode_uri,
        &radar_status_uri, &radar_save_uri, &radar_reset_uri, &radar_calibrate_uri, &restart_uri,
        &ota_config_uri, &ota_config_post_uri, &ota_status_uri,
        &ota_update_uri, &pin_change_uri,
    };
    for (size_t i = 0; i < sizeof(uri_handlers) / sizeof(uri_handlers[0]); i++) {
        esp_err_t reg_err = httpd_register_uri_handler(s_http_server, uri_handlers[i]);
        if (reg_err != ESP_OK) {
            /* Silent in the original per-call form - a handler dropped here
             * 404s on every request as if the route never existed, with no
             * indication why. Surface it instead of letting it disappear. */
            ESP_LOGE(TAG, "Failed to register URI handler '%s': %s",
                     uri_handlers[i]->uri, esp_err_to_name(reg_err));
        }
    }


    //ota_update_init();
    //ota_update_task_start();

    /* Start UART input task for debug streaming */
    //xTaskCreate(uart_input_task, "uart_input_task", 4096, NULL, 5, NULL);

    ESP_LOGI(TAG, "HTTP server started successfully on port %d", WEB_SERVER_PORT);
    return ESP_OK;
}

void web_server_stop(void)
{
    if (s_http_server) {
        httpd_stop(s_http_server);
        s_http_server = NULL;
        ESP_LOGI(TAG, "HTTP server stopped");
    }
}

void web_server_deinit(void)
{
    web_server_stop();
    s_mode_change_callback = NULL;
    ESP_LOGI(TAG, "Web server deinitialized");
}

device_mode_t web_server_get_device_mode(void)
{
    return s_device_mode;
}

esp_err_t web_server_set_device_mode(device_mode_t mode)
{
    if (s_device_mode == mode) {
        return ESP_OK;
    }
    
    device_mode_t old_mode = s_device_mode;
    s_device_mode = mode;
    
    ESP_LOGI(TAG, "Device mode changed: %d -> %d", old_mode, mode);
    
    if (s_mode_change_callback) {
        s_mode_change_callback(mode);
    }
    
    return ESP_OK;
}

    

