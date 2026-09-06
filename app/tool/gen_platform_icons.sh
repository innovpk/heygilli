#!/usr/bin/env sh
# Renders the launcher icon for iOS and web from assets/gilli.svg.
#
# Android's icons are adaptive (a cream @color background plus a foreground
# layer, masked by the launcher), so they are generated separately and live in
# res/mipmap-*. iOS and the web need one flat square each, at a pile of sizes,
# and this writes them from the same drawing at the same 66% safe-zone scale so
# a family sees the same squirrel whichever device they open.
#
# Needs rsvg-convert and ImageMagick:  brew install librsvg imagemagick
# Run from the repo root:  sh app/tool/gen_platform_icons.sh
set -eu

SVG=app/assets/gilli.svg
CREAM='#FBF3E6'
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# Gilli at 66% of the canvas, centred on cream — the same safe zone the Android
# adaptive icon uses, so no launcher shape can crop a paw.
# The SVG carries its own margin and sits off-centre in its viewBox, so the
# drawing is trimmed to its ink before being placed. Without the trim Gilli
# lands low and right of centre and reads as a mistake at 40px.
rsvg-convert -w 2048 -h 2048 "$SVG" -o "$TMP/full.png"
magick "$TMP/full.png" -trim +repage "$TMP/gilli.png"

render() { # size out
  size=$1; out=$2
  inner=$(( size * 66 / 100 ))
  magick "$TMP/gilli.png" -resize "${inner}x${inner}" "$TMP/g.png"
  magick -size "${size}x${size}" "xc:$CREAM" "$TMP/g.png" -gravity center -composite "$out"
}

IOS=app/ios/Runner/Assets.xcassets/AppIcon.appiconset
for spec in \
  "20 Icon-App-20x20@1x" "40 Icon-App-20x20@2x" "60 Icon-App-20x20@3x" \
  "29 Icon-App-29x29@1x" "58 Icon-App-29x29@2x" "87 Icon-App-29x29@3x" \
  "40 Icon-App-40x40@1x" "80 Icon-App-40x40@2x" "120 Icon-App-40x40@3x" \
  "120 Icon-App-60x60@2x" "180 Icon-App-60x60@3x" \
  "76 Icon-App-76x76@1x" "152 Icon-App-76x76@2x" "167 Icon-App-83.5x83.5@2x" \
  "1024 Icon-App-1024x1024@1x"; do
  set -- $spec
  render "$1" "$IOS/$2.png"
done

WEB=app/web
render 192 "$WEB/icons/Icon-192.png"
render 512 "$WEB/icons/Icon-512.png"
render 192 "$WEB/icons/Icon-maskable-192.png"
render 512 "$WEB/icons/Icon-maskable-512.png"
# Tighter than the rest on purpose: a browser tab is 16-32px, and the
# launcher safe zone leaves nothing legible at that size.
magick "$TMP/gilli.png" -resize 30x30 "$TMP/fav.png"
magick -size 32x32 "xc:$CREAM" "$TMP/fav.png" -gravity center -composite \
  "$WEB/favicon.png"

# iOS launch screen. The storyboard paints cream behind this and centres it,
# so these are transparent squares at the three scales the imageView asks for.
LAUNCH=app/ios/Runner/Assets.xcassets/LaunchImage.imageset
for spec in "168 LaunchImage" "336 LaunchImage@2x" "504 LaunchImage@3x"; do
  set -- $spec
  magick "$TMP/gilli.png" -resize "$1x$1" -background none -gravity center \
    -extent "$1x$1" "$LAUNCH/$2.png"
done

echo "iOS and web icons written from $SVG"
