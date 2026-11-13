RLS Vehicle Photo
=================

Adds "New image" and "Photo studio..." to the vehicle menu on RLS Career Overhaul's My Vehicles page.
Click (or right-click) a vehicle, then:
- "New image": a fresh photo of the car as it is now replaces its picture, using your saved framing.
- "Photo studio...": opens a panel with a live preview and sliders for distance, rotation, camera
  height, position in the picture and lens. "Take photo" saves the picture; with "Use these settings
  for all photos" ticked, the framing also becomes the default for "New image". Reset goes back to
  the settings the panel opened with, Mod defaults to the built-in ones, and a double-click resets
  one slider. Esc or Cancel closes it without a photo.

How it works
- A temporary copy of the car is spawned in a studio bowl (the stock showroom backdrop) high above
  the map, photographed with an off-screen camera, then deleted. Your real car is not moved.
- If it is dark, midday light is borrowed for the shot and the time of day is put back afterwards.
- Physics is paused for the couple of seconds the shot takes.
- Photos are stored per career profile in <BeamNG user folder>/settings/x_rls_vehicle_photo/photos/
  and take priority over RLS's own picture (which otherwise sticks to the stock config image).
- The copy is undamaged even if your car is damaged.

Options
The photo studio saves the framing settings for you. Everything can also be set by hand in
<BeamNG user folder>/settings/x_rls_vehicle_photo/config.json, with any of:
  {
    "useBackdrop": true,      false = sky behind the car instead of the studio
    "forceDaylight": true,    false = keep the current time of day
    "yawDegrees": 0,          turn the car in the studio (-180 to 180)
    "width": 640, "height": 360,
    "fov": 40,
    "cameraDistance": 1.25,   1 = tight framing; higher = more space around the vehicle
    "cameraPitch": 0,         degrees to raise the camera (e.g. 10 = looking down more); negative lowers it
    "frameShiftUp": 0,        move the vehicle up in the picture (0.1 = a touch); negative moves it down
    "frameShiftRight": 0,     move the vehicle right in the picture; negative moves it left
    "manualEV": null,         a number fixes the exposure if photos come out too dark/bright
    "backdropReach": 20,      how far away the studio wall is, in camera distances
    "backdropHeight": 3,      raise if sky shows at the top of photos
    "shadowSoftness": 0.8,    shadow blur, 0 (sharp) to 1 (very soft); false = level's own
    "settleSeconds": 1.5      raise this if big modded cars are photographed half-loaded
  }
(JSON does not allow the explanations above; only keep the "key": value pairs.)

Go back to RLS's own picture for one vehicle: open the console (~) in GE Lua mode and run
  xRlsVehiclePhoto.clearPhoto(<inventoryId>)

Troubleshooting: messages are logged under the tag "xRlsVehiclePhoto" in beamng.log.
