# Agent Instructions

## Commands

### Python GUI Tool
```powershell
# Check syntax
python -m py_compile tools\professional_radar_tool.py

# Run with PyQt5
python tools\professional_radar_tool.py
```

### ESP-IDF Build (ESP32-S3)
ESP-IDF requires proper environment setup. Run from ESP-IDF PowerShell:
```powershell
# Export ESP-IDF environment
. C:\Espressif\frameworks\esp-idf-v5.5.2\export.ps1

# Then build
idf.py build
idf.py -p COM4 flash monitor
```

## Key Files

- `tools/professional_radar_tool.py` - PyQt5 radar configuration GUI
- `main/app/radar_sensor.h` - Radar sensor header with UART pin definitions
- `main/app/radar_sensor.c` - Radar sensor implementation

## Recent Changes

### radar_sensor.h
- Reverted UART pins to GPIO5/GPIO6 (working configuration)

### radar_sensor.c
- Added support for saved init sequence from NVS (web_server_get_uart_init_sequence)
- Added web_server.h include for init sequence integration

### web_server.h/c
- Added UART debug web interface (/uart_debug, /uart_send, /uart_log, /uart_init_sequence, /uart_send_sequence)
- Added load_uart_init_sequence() to load init commands from NVS
- Added web_server_run_uart_init_sequence() and web_server_get_uart_init_sequence() APIs
- UART log streaming via Server-Sent Events (SSE)
- Init sequence saved to NVS for use at boot

### professional_radar_tool.py
- Fixed indentation error in `load_profile()` method
- Removed duplicate exception handler block
- Made connection section more compact (reduced margins/spacing from 5 to 3)
- Added green transparent row highlight for currently running sequence command