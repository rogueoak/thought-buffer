# Brand assets

## App icon

`app-icon.svg` is the source of truth for the Thought Buffer app icon: a voice **soundwave**
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

## Wordmark

`wordmark.svg` is the horizontal logo: the app-icon soundwave in an 84 x 84 product tile, next to
the "Thought Buffer" wordmark and a one-line descriptor. It is drawn in the shared Rogue Oak logo
language (520 x 150 canvas, monoline mark, accent underline) so it sits in the same family as the
Spectra, Trellis, and Canopy wordmarks. Use it wherever the name needs to read as a logo - the top
of this README, the rogueoak.com Coming Soon section, docs. For a square badge (app stores, avatars)
use `app-icon.svg` instead.
