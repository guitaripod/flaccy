# Flaccy 1.16.0: store baseline and targets

1.16.0 makes the iPhone app universal. Until now an iPad visitor saw an iPhone-only listing with iPhone screenshots; from 1.16.0 the listing carries a 13" iPad set in eleven languages and a Built for iPad section in all seventeen descriptions.

## Baseline before 1.16.0

App Store Discovery and Engagement Standard, weekly, the three weeks starting 2026-09-28, 2026-10-05 and 2026-10-12 (request `ba3d5800-e0a5-4424-88ed-260ccc2e7dec`):

| Device | Impressions | Page views | Taps | Page views per impression |
|---|---|---|---|---|
| iPhone | 3,626 | 601 | 218 | 16.6% |
| iPad | 632 | 63 | 12 | 10.0% |
| Desktop | 94 | 1,452 | 7 | n/a (web previews) |

Sales reports, first downloads in the 28 days to 2026-11-02 (`myyty`): iPhone 174, Desktop 26, iPad 13, Apple Watch 9. iPad bought nothing.

## Targets for the four weeks after release

- iPad page views per impression from 10% to at least the iPhone rate (16%), now that the iPad set shows the iPad layout.
- iPad first downloads from 13 to 30 or more per 28 days.
- A first iPad purchase.
- iPhone rates hold: the iPhone set did not change.

## How to read it again

- `asc analytics view --request-id ba3d5800-e0a5-4424-88ed-260ccc2e7dec --granularity WEEKLY` lists the weekly instances; download each with `asc analytics download --request-id … --instance-id … --decompress` and sum `Counts` by `Device` and `Event`.
- `myyty sql "select device, sum(units) filter (where kind='download') from sales where app_sku like 'flaccy%' and report_date >= current_date - 28 group by 1"`.
