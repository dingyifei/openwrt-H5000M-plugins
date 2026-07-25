# luci-app-epm patches

The EPM runtime / MBIM patch(es), rebased to apply at **`--fuzz=0`** against the pinned
source in `configs/sources.lock`. `build-packages.sh` must fail if any hunk fuzzes.

MBIM must be accepted consistently across backend validation, UCI defaults, HTML and JS;
preserve lpac 2.3 fields such as `custom_isd_r_aid`. (Empty until the source is pinned.)
