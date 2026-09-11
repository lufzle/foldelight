# Preview lock screen

`LockScreen.png` replaces the former procedural mountain artwork in both Settings and About. It is a 1586 × 992 RGB PNG, reconstructed with the built-in imagegen tool from the user-supplied reference `codex-clipboard-7acc4f88-8ac2-4230-9efa-59180ef3916d.png` on September 11, 2026.

The texture preserves the blue flowing wallpaper, date, clock, status icons, and profile shown in the reference. The depicted profile name belongs to the reference artwork. The project creator remains Dario Farzati.

The generated texture contains no laptop body, bezel, notch, or rounded corner cutouts. The existing interactive miniature supplies those elements. The bitmap is bundled and cached as a Metal texture at its native pixel dimensions. No generated file outside the repository is required at runtime.

## Generation prompt

Use case: precise-object-edit. Asset type: a flat lock-screen texture for the screen inside an existing interactive MacBook miniature in a native macOS app. Input image is the edit target. Extract/recreate ONLY the illuminated rectangular screen content, filling the entire output edge to edge, at a landscape 16:10 aspect ratio, preferably 1920 x 1200 or larger. Preserve the reference's exact blue and cyan flowing glass wallpaper, its warm pale sky, the sweeping thin curved diagonal highlight, all relative composition and colors. Preserve the centered white date text 'Tue Apr 1' and large translucent white clock '9:41' near the top. Preserve the small status icons at the upper right and the circular illustrated profile avatar near the bottom with the labels 'Erica Souza' and 'Touch ID or Enter Password'. Keep these at the same relative positions and scale as within the original display. This is a faithful extraction, not a new interpretation. Remove the laptop hardware, silver body, black bezel, black notch/camera cutout, rounded black corner intrusions, shadows, and exterior white margin. Reconstruct the small sky areas hidden under the notch and rounded corners so the output is a complete flat rectangle. The application already draws its own hardware, notch and corner masking. No extra text, no extra objects, no frame, no border, no perspective, no additional blur or effects.

The generated file's actual dimensions were 1586 × 992. Those pixels are preserved without an additional upscale. The existing preview fits it to its 16:10 screen.
