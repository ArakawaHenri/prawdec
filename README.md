#  prawdec - ProRes RAW Decoder

Transcodes ProRes RAW to CinemaDNG. (WIP)

### Requirements

- libtiff

### Todo
- [ ] Save timecodes to CinemaDNG
- [ ] Extract audio
- [ ] Port to Windows
- [ ] If the ProRes RAW file contains Color Matrices for multiple scenes, use them to calculate more accurate color conversions
- [ ] Use more accurate conversion algorithms
- [ ] Support X-Trans CFA

### Completed
- [x] Support for Bayer CFA
- [x] Use the matrix in metadata to create color conversions for DNG instead of per device maintenance like RAW Converter. This way it can be adapted to any niche or new device. 
- [x] Calibrate the white balance of the converted DNG file. (Assimilate does not calibrate this resulting in single matrix files always being converted to D65)
