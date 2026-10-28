# SUBWEB local overlay

This directory is intentionally outside /volume1/web/subweb so it survives an upstream checkout, build, or replacement of the deployed dist directory.

## Preserved items

- jQuery 3.6.4
- Font Awesome Free 6.4.0 CSS, WOFF2, and TTF fonts
- Inter v20 local WOFF2 fonts
- apply.py, which replaces the blocking public CDN references
- CURRENT_LOCAL_CHANGES.md, a snapshot of the current site configuration notes

## Apply after every upstream update

1. Pull or clone upstream source in a separate source directory.
2. Reapply the settings documented in CURRENT_LOCAL_CHANGES.md at source level.
3. Build and deploy the new dist to /volume1/web/subweb.
4. Run:

    python3 /volume1/docker/subweb-local-overlay/apply.py /volume1/web/subweb

The command is idempotent. It copies the preserved vendor files, replaces supported upstream CDN tags, changes local jQuery and qrcode scripts to deferred loading, and backs up index.html before modifying it.

If upstream changes the relevant HTML tags, the script exits with an error instead of silently deploying public CDN dependencies. Inspect the new HTML and update apply.py before proceeding.

## Verification

The deployed index.html must not contain these strings:

- unpkg.com/jquery
- fonts.googleapis.com/css2?family=Inter
- cdnjs.cloudflare.com/ajax/libs/font-awesome

All files below /vendor should return HTTP 200 from the SUBWEB virtual host.

## 2026-10-23: source-level local settings

Settings that live in source (backends, rule configs, option order/defaults) are kept as a patch in `source-patches/` (see its README). Build flow: apply patch -> build -> deploy dist -> run apply.py.
