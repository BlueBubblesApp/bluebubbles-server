# Image conversion fixtures

`transparent-alpha.heic` was generated from the repository-owned
`icons/macos/tray/icon-lightTemplate.png` with:

```bash
/usr/bin/sips --setProperty format heic \
  icons/macos/tray/icon-lightTemplate.png \
  --out packages/server/test/fixtures/transparent-alpha.heic
```

Both the source PNG and generated HEIC report `hasAlpha: yes`. The macOS-only
integration test converts this fixture through the same `sips` helper used by
`FileSystem.convertToPng` and verifies that the output is a PNG with alpha.
