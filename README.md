# Live Wi-Fi Signal Strength Mapping and Coverage Analysis Using ESP32 and MATLAB

**A Real-Time Wireless Signal Analysis System Using Embedded Data Acquisition and Numerical Techniques**

## Overview

This project implements a real-time Wi-Fi signal strength mapping and coverage analysis system using an ESP32 microcontroller and MATLAB.

The ESP32 connects to a Wi-Fi access point and continuously measures the Received Signal Strength Indicator (RSSI). These measurements are transmitted to a computer through serial communication, where MATLAB processes the collected data and generates a spatial representation of Wi-Fi signal strength.

The system uses numerical techniques to estimate signal strength across an indoor environment, identify signal threshold boundaries, and calculate the percentage of an area receiving usable Wi-Fi coverage.

The project was developed as part of the **Numerical Techniques Laboratory Course** to demonstrate the practical application of numerical methods in wireless communication and engineering analysis.

## Project Objectives

- Acquire real-time Wi-Fi RSSI measurements using ESP32.
- Establish serial communication between ESP32 and MATLAB.
- Generate a two-dimensional Wi-Fi signal strength heatmap.
- Estimate signal distribution using Inverse Distance Weighting (IDW).
- Apply numerical root-finding algorithms to identify signal threshold boundaries.
- Calculate estimated usable signal coverage using numerical integration.
- Visualize the results through interactive 2D and 3D MATLAB plots.

## System Architecture

The project consists of three main stages:

**1. Data Acquisition — ESP32**

The ESP32 connects to a Wi-Fi network and measures RSSI values at regular intervals. The readings are transmitted to MATLAB through USB serial communication.

**2. Data Processing — MATLAB**

MATLAB receives the RSSI readings, associates averaged measurements with manually entered physical coordinates, and processes the collected spatial data.

**3. Numerical Analysis and Visualization**

MATLAB applies IDW interpolation, numerical root-finding methods, and trapezoidal integration to estimate signal distribution and coverage.

## Hardware Requirements

| Component | Purpose |
|---|---|
| ESP32 Development Board | Wi-Fi signal acquisition |
| Wi-Fi Router / Access Point | Wireless signal source |
| USB Cable | Power and serial communication |
| Computer | MATLAB processing and visualization |

No external Wi-Fi sensor is required because the ESP32 has built-in Wi-Fi functionality.

## Software and Technologies

- **ESP32:** Wi-Fi connectivity and RSSI acquisition
- **Arduino IDE:** ESP32 firmware development
- **MATLAB:** Data processing and visualization
- **Serial Communication:** Real-time data transmission
- **Numerical Methods:** Interpolation, root finding, and numerical integration

## Numerical Methods Implemented

### 1. Inverse Distance Weighting (IDW)

IDW interpolation estimates RSSI values at unknown spatial locations using the measured values at nearby sampling points.

The interpolation model is:

\[
RSSI(x,y)=
\frac{\sum_{i=1}^{n}w_i RSSI_i}
{\sum_{i=1}^{n}w_i}
\]

where:

\[
w_i=\frac{1}{d_i^p}
\]

- \(d_i\): Distance between the estimation point and measurement point.
- \(p\): Distance weighting power.
- \(RSSI_i\): Measured signal strength.

The implementation uses a weighting power of **3.5**.

### 2. Numerical Root-Finding Algorithms

The system identifies locations where the estimated RSSI crosses a user-defined signal threshold.

Four numerical methods are implemented:

- Bisection Method
- False Position Method
- Newton-Raphson Method
- Secant Method

These methods are used to estimate the signal threshold boundary across the spatial grid.

### 3. Numerical Integration — Trapezoidal Rule

The composite trapezoidal rule is used to estimate the area receiving usable Wi-Fi signal strength.

The system calculates:

- Total mapped area.
- Estimated measured area.
- Estimated usable signal area.
- Percentage of measured area receiving usable signal.

The default signal threshold is **-60 dBm**, which can be changed through the MATLAB interface.

## Key Features

- Live RSSI monitoring.
- Automatic serial port detection and connection.
- Spatial coordinate-based data collection.
- Averaging of 15 fresh RSSI samples per recorded location.
- Dynamic 2D Wi-Fi heatmap generation.
- Interactive 3D signal strength visualization.
- Configurable room dimensions and router coordinates.
- Adjustable RSSI threshold.
- Four selectable numerical root-finding methods.
- Honest mode to mask regions beyond the configured distance from measurement points.
- Full Surface mode for visualization using extrapolated estimates.
- Estimated signal coverage calculations.
- Animated heatmap transitions and router signal rings.
- Recorded measurement data save/load functionality.

## Experimental Workflow

1. Upload the ESP32 firmware using Arduino IDE.
2. Configure the Wi-Fi network credentials.
3. Connect the ESP32 to the computer using USB.
4. Open the MATLAB application.
5. Select the appropriate serial port and establish a connection.
6. Move to a selected measurement location.
7. Enter its X and Y coordinates in meters.
8. Wait until 15 fresh RSSI readings have been collected.
9. Record the measurement point.
10. Repeat the process at different locations throughout the test area.
11. Observe the generated heatmap and coverage analysis.

At least three spatial measurement points are required to generate the interpolated surface.

## Project Parameters

| Parameter | Implementation |
|---|---|
| RSSI sampling interval | 200 ms |
| Samples per measurement point | 15 |
| Average collection window | Approximately 3 seconds |
| IDW weighting power | 3.5 |
| Heatmap grid resolution | 45 × 45 |
| Honest-mode maximum distance | 1.2 m |
| Default RSSI threshold | -60 dBm |
| Default room dimensions | 5 m × 5 m |

These are the current software defaults and can be modified in the MATLAB source code.

## Repository Structure

```text
WiFi-Signal-Strength-Heatmap/
│
├── ESP32/
│   └── esp32_rssi_logger.ino
│
├── MATLAB/
│   ├── WiFiHeatmapLive_Animated.m
│   ├── bisection_method.m
│   ├── falseposition_method.m
│   ├── newtonraphson_method.m
│   └── secant_method.m
│
├── Results/
│   └── screenshots_and_heatmaps/
│
└── README.md
```

The four root-finding MATLAB function files must be included in the MATLAB path. They are external dependencies of the main application.

## Limitations and Considerations

- Heatmap accuracy depends on the number and distribution of actual measurement points.
- IDW provides an interpolation estimate, not a complete physical model of radio wave propagation.
- The Honest mode reduces unsupported extrapolation by masking regions too far from measured points.
- Signal strength can vary due to obstacles, reflections, interference, and environmental conditions.
- Coverage percentages represent numerical estimates based on the interpolated RSSI field and selected threshold.

## Learning Outcomes

This project demonstrates how numerical techniques can be integrated with embedded systems to solve a practical engineering problem.

It provided practical experience in:

- Embedded Wi-Fi communication.
- Real-time sensor data acquisition.
- Numerical interpolation.
- Nonlinear equation solving.
- Numerical integration.
- MATLAB GUI development.
- Engineering data visualization.

## Author

**Sabbir Ahmed**

Electrical and Electronic Engineering

Numerical Techniques Laboratory Project

---

**Note:** This project is intended for educational and experimental wireless signal analysis. The generated heatmap represents an estimate based on collected RSSI measurements, not a certified wireless coverage survey.
