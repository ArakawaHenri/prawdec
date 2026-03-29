# DNG SDK Vendor Drop

- Vendored static archive: `lib/libdng.a`
- Vendored headers:
  - `include/`
  - `include/dng/`
  - `include/jpeg/`
  - `include/jxl/`

The Xcode app target is configured to search these include paths and link `-ldng` from `ThirdParty/DNGSDK/lib`.
