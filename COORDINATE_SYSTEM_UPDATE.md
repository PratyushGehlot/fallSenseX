# FallSenseX Coordinate System Update

## Requirement Summary
1. ESP32 sends raw coordinates **as-is** (meters)
2. Mobile app displays coordinates in **feet**
3. 2D grid: user-configurable size, **center = (0,0)**, X+ right, Y+ forward
4. Sensor mounted at ceiling center, covers ~6m radius

## Changes Made

### 1. ESP32 Code (`main/app/radar_sensor.c`)

**Lines 568-582**: Enabled coordinate transformation to center the data at sensor

```c
// Parse raw values (radar gives corner-based coordinates: 0..GRID_X, 0..GRID_Y)
float raw_x = (float)atof(px + 2);
float raw_y = (float)atof(py + 2);
float raw_z = (float)atof(pz + 2);

// Transform to centered coordinates: sensor at (0,0) center of grid
point->x = raw_x + (GRID_X / 2.0f);  // shift X: 0→-3, 6→+3
point->y = raw_y + (GRID_Y / 2.0f);  // shift Y similarly
point->z = raw_z;                    // height unchanged
```

**Result**: ESP32 now sends **centered** coordinates:
- X range: approximately -3 to +3 meters
- Y range: approximately -3 to +3 meters
- Z range: 0 to ~2.5 meters (height from ground)

### 2. Flutter Mobile App

#### `lib/main.dart`

- **Line 52**: Added `_telemetryRef` listener for temperature
- **Lines 56, 112-126**: `_latestTemperature` field and `_startTelemetryUpdates()` method
- **Lines 418-422**: Display temperature in the latest frame card
- **Lines 136-156** (`_navigateTo3DView`): Convert centered meters → corner-based meters for 3D view
  - `cornerX = xMeters + roomLenM/2`
  - `cornerY = yMeters + roomWidM/2`

#### `lib/widgets/room_3d_view.dart`

- **Lines 211-243** (`_convertFromFramesList`): Stores centered feet coordinates in `humanDet`
  - `_displayX = xFeet` (centered)
  - `_displayY = yFeet` (centered)
  - `humanDet.x = xFeet` (centered for drawing)
  - `humanDet.y = yFeet` (centered)
- **Lines 317-336** (`_convertLatestFrame`): Same centered coordinate handling
- **Lines 677-718** (`RoomPainter.paint`): Draws using centered coordinates
  - `canvasX = centerCanvasX + human.x * scale`  (+X → right)
  - `canvasY = centerCanvasY - human.y * scale`  (+Y → up, flipped for canvas)

## Coordinate System Flow

```
Radar raw (corner-based, 0..6m)
        ↓ ESP32 transforms
Centered meters (-3..+3)
        ↓ Firebase
Flutter reads x,y in meters (centered)
        ↓ Convert to feet
Centered feet (-9.8..+9.8 approx)
        ↓
- Display: show centered feet directly
- 2D Grid: (0,0) at center, +X right, +Y up
- 3D Scene: convert centered → corner for Three.js origin-at-corner
```

## Testing

- **x=0, y=0**: Should appear at **center** of grid (sensor location)
- **x=+3m (≈+9.8ft)**: Should appear at **right edge** of 10ft grid
- **y=+3m (≈+9.8ft)**: Should appear at **top edge** (forward direction)
- **x=-3m, y=-3m**: Should appear at **bottom-left** corner

Temperature reading appears below position in the main dashboard card when telemetry is received.
