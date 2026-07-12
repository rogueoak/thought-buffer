# Brand assets

## App icon

`app-icon.svg` is the source of truth for the Thought Stream app icon: a voice **soundwave**
drawn in the Rogue Oak node-graph style (gradient strokes with node caps) on a deep radial
background, colored with the **River Mist** palette. The gold spark on the tallest peak is the
"live" indicator and the family tie-in to the Rogue Oak avatar.

- `app-icon.svg` - canonical 1024 x 1024 source.
- `alternates/app-icon-mic.svg` - microphone concept kept for reference.
- `png/` - rasterized sizes for the Xcode asset catalog (`AppIcon-<px>.png`).

### Regenerate the PNG set

Rendered with headless Chrome, then downscaled with `sips`:

```sh
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
"$CHROME" --headless --disable-gpu --force-device-scale-factor=1 \
  --screenshot=png/AppIcon-1024.png --window-size=1024,1024 "file://$PWD/app-icon.svg"
for s in 180 167 152 120 87 80 76 60 58 40 29 20; do
  cp png/AppIcon-1024.png "png/AppIcon-$s.png"; sips -z $s $s "png/AppIcon-$s.png"
done
```

The icon uses no transparency and no rounded corners; iOS applies the rounded-square mask.
