# Flaccy 1.20.0: store baseline and targets

1.20.0 remasters Flaccy for iPhone Duo. The listing replaces the October Duo set (ten raw captures without captions, the tiny Now Playing cover, no book or nothing-playing story) with ten captioned slides across the four Duo sizes in fifteen languages, and replaces the Header and Search Results images placed with Duo 1.7.4 on 2026-10-09 with new text-free ones from the 1.20.0 build.

## What can and cannot be measured

App Store Connect counts an iPhone Duo as an iPhone in both the analytics reports (`Device` is `iPhone`) and the sales reports, so nothing below isolates the Duo. The Header and Search Results images are shown to every iOS 27 visitor who meets the listing in search, Duo or not, so the iPhone search rates are where a change in them would show.

## Baseline before 1.20.0

App Store Discovery and Engagement Standard, weekly, the three weeks 2026-10-19 to 2026-11-08 (request `ba3d5800-e0a5-4424-88ed-260ccc2e7dec`, instances `74289175…`, `4cdafce9…`, `0bfb6688…`):

| Device | Impressions | Page views | Taps | Page views per impression |
|---|---|---|---|---|
| iPhone | 6,542 | 1,271 | 315 | 19.4% |
| iPad | 1,389 | 181 | 24 | 13.0% |
| Desktop | 2,323 | 83 | 18 | n/a (web previews) |

Sales reports, first downloads in the 28 days to 2026-11-12 (`myyty`): iPhone 168, Desktop 22, iPad 12, Apple Watch 7.

## Targets for the four weeks after release

- iPhone page views per impression from 19.4% to 21% or more, with the new Search Results image in front of every iOS 27 searcher.
- iPhone first downloads hold at 168 or more per 28 days.
- No iPhone Duo review or support mail about the layout (the old build's empty half-screen player and 99 pt cover are gone).

## How to read it again

- `asc analytics view --request-id ba3d5800-e0a5-4424-88ed-260ccc2e7dec --granularity WEEKLY` lists the weekly instances of "App Store Discovery and Engagement Standard"; download each with `asc analytics download --request-id … --instance-id … --decompress --output <file>.csv.gz` and sum `Counts` by `Device` and `Event` for `App Apple Identifier` 6787493695.
- `myyty sql "select device, sum(units) filter (where kind='download') from sales where app_sku like 'flaccy%' and report_date >= current_date - 28 group by 1"`.
