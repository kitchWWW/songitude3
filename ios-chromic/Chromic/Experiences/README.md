# Experiences

Drop exported `.zip` bundles from the web editor here. At build time,
`import_experiences.sh` unpacks each one into the app under `Bundled/<name>/`, and the app
lists them all (selectable in Settings → Debug → Map).

- One `.zip` per experience. The zip's file name (minus `.zip`) becomes the folder name.
- Point the app at "the most recent version" simply by replacing the zip and rebuilding.
- The app supports several at once — add three or four for people to choose between.

Bundle format is documented in `../../shared/FORMAT.md`.
