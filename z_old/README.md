# z_old

The four demo soundwalks that used to ship inside the iOS app (`ios/Songitude/Experiences/*.zip`,
unpacked at build time into `Bundled/`). They were removed from the app once every walk came from
the published catalog — keeping them baked in cost ~18 MB of download for content that is now
available online.

Kept here as the original editor-compatible bundles: each is a `.zip` with `map.json` + `audio/` at
the root, so any of them can be dropped straight back into the editor (Import .zip) or into
`ios/Songitude/Experiences/` to test a local bundle without publishing.
