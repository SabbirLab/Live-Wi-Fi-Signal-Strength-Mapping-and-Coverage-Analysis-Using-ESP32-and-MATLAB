/*
  ESP32 RSSI Logger
  --------------------------------------------------
  Connects to your WiFi router and streams RSSI (signal strength) readings
  over Serial as CSV lines:  <millis>,<rssi_dbm>\n

  MATLAB's PresenceDetectionApp.m reads these lines live via serialport(),
  fits a curve to a rolling window, and uses root-finding (Bisection, False
  Position, Newton-Raphson, Secant) to find the exact moment RSSI crosses a
  threshold -- i.e. when a person likely walked through the signal path.

  Wiring: none needed beyond USB (ESP32 <-> PC). Optional: add an LED on a
  GPIO pin if you want a physical indicator alongside the MATLAB GUI lamp.

  Board: any ESP32 dev board (tested logic works on ESP32-WROOM-32 style boards)
*/

#include <WiFi.h>

// ---- EDIT THESE ----
const char* WIFI_SSID     = "EEE_Batch_241";
const char* WIFI_PASSWORD = "ronaldo07";
const unsigned long SAMPLE_INTERVAL_MS = 200;   // ~5 samples/sec, matches MATLAB window sizing
// ---------------------

// Optional: onboard/external LED to mirror MATLAB's status lamp locally
const int STATUS_LED_PIN = 2;   // most ESP32 dev boards have a built-in LED on GPIO2

unsigned long lastSampleTime = 0;

void connectWiFi() {
  WiFi.mode(WIFI_STA);
  WiFi.begin(WIFI_SSID, WIFI_PASSWORD);

  Serial.print("Connecting to WiFi");
  unsigned long start = millis();
  while (WiFi.status() != WL_CONNECTED && millis() - start < 15000) {
    delay(300);
    Serial.print(".");
  }

  if (WiFi.status() == WL_CONNECTED) {
    Serial.println();
    Serial.print("Connected. IP: ");
    Serial.println(WiFi.localIP());
  } else {
    Serial.println();
    Serial.println("WiFi connect failed - will keep retrying in loop().");
  }
}

void setup() {
  Serial.begin(115200);
  delay(500);

  pinMode(STATUS_LED_PIN, OUTPUT);
  digitalWrite(STATUS_LED_PIN, LOW);

  connectWiFi();
}

void loop() {
  // Reconnect automatically if WiFi drops (keeps demo stable at the project show)
  if (WiFi.status() != WL_CONNECTED) {
    connectWiFi();
  }

  unsigned long now = millis();
  if (now - lastSampleTime >= SAMPLE_INTERVAL_MS) {
    lastSampleTime = now;

    if (WiFi.status() == WL_CONNECTED) {
      long rssi = WiFi.RSSI();   // signal strength in dBm, e.g. -55
      Serial.print(now);
      Serial.print(",");
      Serial.println(rssi);
    }
  }
}
