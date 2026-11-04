# Store marketing pipeline

All marketing uses the fictional seeded catalog (Meridian Wolde, Parallax Hours): never a real cover or artist. Bezels always come from the `frames` CLI.

- `capture_all_locales.sh UDID OUT [lang…]` captures the iPhone screens per locale and appearance from a simulator launched with `--seed-screenshots` (`capture_iphone.py` holds the route table).
- Mac: build the DEBUG target with an empty entitlements file and a throwaway bundle id, then launch it with `open -n --env MTL_HUD_ENABLED=0 … --args --seed-screenshots --window-size 3000x1880 --trial-day 3 -flaccy.mac.interfaceScale 2.0 --shot-section albums` (the zoom gives 2x-sharp captures on a 1x display; the Metal HUD is on globally on this Mac and paints over Now Playing).
- `swiftc -O text_layer.swift -o /private/tmp/build/text_layer` builds the CoreText caption renderer (right font per script).
- `build_iphone_set.py --raw RAW --out OUT --watch-raw NOWPLAYING.png,ALBUM.png` composes 10 slides × 11 locales at 1320×2868; `build_mac_set.py --raw RAW_MAC --out OUT` composes 9 slides at 2880×1800 (MacBook Pro via `frames`).
- iPad: `build_ipad_set.py --raw RAW_IPAD --out OUT` composes 8 slides at 2752×2064 (iPad Pro 13-inch landscape via `frames`) from captures on an iPad Pro 13-inch simulator with `--seed-screenshots`, `FLACCY_LANDSCAPE=1`, `FLACCY_SIDEBAR=1` and `FLACCY_HIDE_STATUS_BAR=1`; rotating needs the `UIRequiresFullScreen` copy described in `docs/agent-notes.md` ("iPad"). The set lives in `store/shots/ipad/en-US` (device type `IPAD_PRO_3GEN_129` when publishing).
- Captions live in `copy_en.json`, `copy_i18n.json` (iPhone), `copy_mac_en.json` and `copy_ipad_en.json`; listing text in `metadata_en.json` and `metadata_i18n.json`.
- `publish_listing.py --platform ios|mac --app … --version-id … --app-info … --stage DIR --device-type IPHONE_67|DESKTOP` pushes text and replaces screenshot sets on an editable version (cancel a submission first; screenshots lock in review).
