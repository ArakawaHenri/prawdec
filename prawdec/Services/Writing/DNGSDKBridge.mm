//
//  DNGSDKBridge.mm
//  prawdec
//
//  Created by Codex on 2026/3/28.
//

#import "DNGSDKBridge.h"

#include "dng_camera_profile.h"
#include "dng_exceptions.h"
#include "dng_exif.h"
#include "dng_file_stream.h"
#include "dng_host.h"
#include "dng_ifd.h"
#include "dng_image_writer.h"
#include "dng_jpeg_image.h"
#include "dng_jxl.h"
#include "dng_negative.h"
#include "dng_orientation.h"
#include "dng_rational.h"
#include "dng_simple_image.h"
#include "dng_tag_values.h"

namespace {

NSString * const kPDDNGSDKBridgeErrorDomain = @"moe.henri.prawdec.dngsdk";

NSInteger ClampQuality(NSInteger quality, NSInteger lower, NSInteger upper) {
    if (quality < lower) {
        return lower;
    }
    if (quality > upper) {
        return upper;
    }
    return quality;
}

dng_matrix_3by3 Matrix3x3FromDoubles(const double *v) {
    return dng_matrix_3by3(v[0], v[1], v[2],
                           v[3], v[4], v[5],
                           v[6], v[7], v[8]);
}

dng_vector_3 Vector3FromDoubles(const double *v) {
    return dng_vector_3(v[0], v[1], v[2]);
}

dng_rect RectFromDimensions(NSInteger imageWidth, NSInteger imageHeight) {
    return dng_rect((uint32) imageHeight, (uint32) imageWidth);
}

dng_rect RectFromActiveArea(const uint32_t *v) {
    return dng_rect((int32) v[0], (int32) v[1], (int32) v[2], (int32) v[3]);
}

uint32 BayerPhaseForPattern(NSInteger bayerPattern) {
    switch (bayerPattern) {
        case 0: // RGGB
            return 1;
        case 1: // GRBG
            return 0;
        case 2: // GBRG
            return 3;
        case 3: // BGGR
            return 2;
        default:
            return 1;
    }
}

NSError *BridgeError(NSInteger code, NSString *message) {
    return [NSError errorWithDomain:kPDDNGSDKBridgeErrorDomain
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey: message}];
}

class PDCustomDNGHost final : public dng_host {
public:
    dng_jxl_encode_settings *MakeJXLEncodeSettings(use_case_enum useCase,
                                                   const dng_image &image,
                                                   const dng_negative *negative = nullptr) const override {
        // Adobe's default host ignores caller-provided JXL settings for lossy
        // mosaic encoding and always falls back to a fixed distance. We want
        // the app's quality slider to control the actual encoded output.
        if (useCase == use_case_LossyMosaic) {
            if (const auto *settings = JXLEncodeSettings()) {
                return new dng_jxl_encode_settings(*settings);
            }
        }

        return dng_host::MakeJXLEncodeSettings(useCase, image, negative);
    }
};

dng_negative *BuildBaseNegative(dng_host &host,
                                NSInteger imageWidth,
                                NSInteger imageHeight,
                                const uint32_t *activeArea,
                                const double *defaultCropOrigin,
                                const double *defaultCropSize,
                                NSString * _Nullable make,
                                NSString * _Nullable model,
                                NSString *uniqueCameraModel,
                                NSString * _Nullable software,
                                uint32_t blackLevel,
                                uint32_t whiteLevel,
                                double baselineExposure,
                                uint16_t calibrationIlluminant1,
                                const double *colorMatrix1,
                                const double *asShotNeutral,
                                uint16_t calibrationIlluminant2,
                                const double * _Nullable colorMatrix2,
                                const double * _Nullable forwardMatrix1,
                                const double * _Nullable forwardMatrix2) {
    AutoPtr<dng_negative> negative(dng_negative::Make(host));
    negative->SetModelName(uniqueCameraModel.UTF8String);
    negative->SetLocalName(uniqueCameraModel.UTF8String);
    negative->SetBaseOrientation(dng_orientation::Normal());
    negative->SetColorimetricReference(crSceneReferred);
    negative->SetBaselineExposure(baselineExposure);
    negative->SetAnalogBalance(dng_vector_3(1.0, 1.0, 1.0));
    negative->SetCameraNeutral(Vector3FromDoubles(asShotNeutral));

    negative->SetActiveArea(RectFromActiveArea(activeArea));
    dng_urational cropOriginH, cropOriginV, cropSizeW, cropSizeH;
    cropOriginH.Set_real64(defaultCropOrigin[0]);
    cropOriginV.Set_real64(defaultCropOrigin[1]);
    cropSizeW.Set_real64(defaultCropSize[0]);
    cropSizeH.Set_real64(defaultCropSize[1]);
    negative->SetDefaultCropOrigin(cropOriginH, cropOriginV);
    negative->SetDefaultCropSize(cropSizeW, cropSizeH);
    negative->SetBlackLevel(blackLevel);
    negative->SetWhiteLevel(whiteLevel);

    negative->ResetExif(host.Make_dng_exif());
    if (auto *exif = negative->GetExif()) {
        if (make.length > 0) {
            exif->fMake.Set_UTF8(make.UTF8String);
        }
        if (model.length > 0) {
            exif->fModel.Set_UTF8(model.UTF8String);
        }
        if (software.length > 0) {
            exif->fSoftware.Set_UTF8(software.UTF8String);
        }
    }

    AutoPtr<dng_camera_profile> profile(new dng_camera_profile);
    profile->SetName("prawdec Embedded");
    profile->SetUniqueCameraModelRestriction(uniqueCameraModel.UTF8String);
    profile->SetCalibrationIlluminant1(calibrationIlluminant1);
    profile->SetColorMatrix1(Matrix3x3FromDoubles(colorMatrix1));
    if (colorMatrix2 != nullptr && calibrationIlluminant2 > 0) {
        profile->SetCalibrationIlluminant2(calibrationIlluminant2);
        profile->SetColorMatrix2(Matrix3x3FromDoubles(colorMatrix2));
    }
    if (forwardMatrix1 != nullptr) {
        profile->SetForwardMatrix1(Matrix3x3FromDoubles(forwardMatrix1));
    }
    if (forwardMatrix2 != nullptr) {
        profile->SetForwardMatrix2(Matrix3x3FromDoubles(forwardMatrix2));
    }
    negative->AddProfile(profile);
    negative->SetAsShotProfileName("prawdec Embedded");
    negative->SynchronizeMetadata();

    return negative.Release();
}

dng_image *BuildRawMosaicImage(dng_host &host,
                               NSInteger imageWidth,
                               NSInteger imageHeight,
                               NSData *pixelData,
                               NSInteger bytesPerRow) {
    AutoPtr<dng_image> image(host.Make_dng_image(RectFromDimensions(imageWidth, imageHeight), 1, ttShort));
    NSInteger rowStep = (bytesPerRow > 0) ? (bytesPerRow / (NSInteger)sizeof(uint16)) : imageWidth;
    dng_pixel_buffer source;
    source.fArea = RectFromDimensions(imageWidth, imageHeight);
    source.fPlane = 0;
    source.fPlanes = 1;
    source.fPixelType = ttShort;
    source.fPixelSize = TagTypeSize(ttShort);
    source.fPlaneStep = 1;
    source.fColStep = 1;
    source.fRowStep = (int32) rowStep;
    source.fData = const_cast<void *>(pixelData.bytes);
    image->Put(source);
    return image.Release();
}

class PDCustomJPEGImage final : public dng_jpeg_image {
public:
    void EncodeWithQuality(dng_host &host,
                           dng_image_writer &writer,
                           const dng_image &image,
                           int32 quality) {
        DNG_REQUIRE(image.PixelType() == ttByte,
                    "Cannot JPEG encode non-byte image");

        dng_ifd ifd;
        ifd.fImageWidth = image.Width();
        ifd.fImageLength = image.Height();
        ifd.fSamplesPerPixel = image.Planes();
        ifd.fBitsPerSample[0] = 8;
        ifd.fBitsPerSample[1] = 8;
        ifd.fBitsPerSample[2] = 8;
        ifd.fBitsPerSample[3] = 8;
        ifd.fPhotometricInterpretation = piLinearRaw;
        ifd.fCompression = ccLossyJPEG;
        ifd.fCompressionQuality = (int32) ClampQuality(quality, 0, 12);
        ifd.FindTileSize(512U * 512U * ifd.fSamplesPerPixel);

        EncodeTiles(host, writer, image, ifd);
    }
};

dng_negative *BuildLinearJPEGNegative(dng_host &host,
                                      dng_image_writer &writer,
                                      NSInteger imageWidth,
                                      NSInteger imageHeight,
                                      const uint32_t *activeArea,
                                      const double *defaultCropOrigin,
                                      const double *defaultCropSize,
                                      NSData *pixelData,
                                      NSInteger bytesPerRow,
                                      NSString * _Nullable make,
                                      NSString * _Nullable model,
                                      NSString *uniqueCameraModel,
                                      NSString * _Nullable software,
                                      uint32_t blackLevel,
                                      uint32_t whiteLevel,
                                      double baselineExposure,
                                      uint16_t calibrationIlluminant1,
                                      const double *colorMatrix1,
                                      const double *asShotNeutral,
                                      uint16_t calibrationIlluminant2,
                                      const double * _Nullable colorMatrix2,
                                      const double * _Nullable forwardMatrix1,
                                      const double * _Nullable forwardMatrix2,
                                      NSInteger bayerPattern,
                                      NSInteger compressionQuality) {
    AutoPtr<dng_negative> sourceNegative(BuildBaseNegative(host,
                                                           imageWidth,
                                                           imageHeight,
                                                           activeArea,
                                                           defaultCropOrigin,
                                                           defaultCropSize,
                                                           make,
                                                           model,
                                                           uniqueCameraModel,
                                                           software,
                                                           blackLevel,
                                                           whiteLevel,
                                                           baselineExposure,
                                                           calibrationIlluminant1,
                                                           colorMatrix1,
                                                           asShotNeutral,
                                                           calibrationIlluminant2,
                                                           colorMatrix2,
                                                           forwardMatrix1,
                                                           forwardMatrix2));
    sourceNegative->SetRGB();
    sourceNegative->SetBayerMosaic(BayerPhaseForPattern(bayerPattern));

    AutoPtr<dng_image> rawImage(BuildRawMosaicImage(host, imageWidth, imageHeight, pixelData, bytesPerRow));
    sourceNegative->SetStage1Image(rawImage);
    sourceNegative->BuildStage2Image(host);
    sourceNegative->BuildStage3Image(host, -1);
    host.SetSaveLinearDNG(true);
    host.SetSaveDNGVersion(MinBackwardVersionForCompression(ccLossyJPEG));
    sourceNegative->ConvertToProxy(host, writer, 0, 0);

    AutoPtr<dng_lossy_compressed_image> lossyCompressed(new PDCustomJPEGImage);
    static_cast<PDCustomJPEGImage *>(lossyCompressed.Get())->EncodeWithQuality(host,
                                                                                writer,
                                                                                sourceNegative->RawImage(),
                                                                                (int32) ClampQuality(compressionQuality, 0, 12));
    sourceNegative->ClearRawLossyCompressedImage();
    sourceNegative->ClearRawLossyCompressedImageDigest();
    sourceNegative->SetRawLossyCompressedImage(lossyCompressed);
    return sourceNegative.Release();
}

}  // namespace

NSString *PDDNGSDKVersionString(void) {
    return @(kDNGSDK_GetInfoVersion);
}

BOOL PDDNGSDKSupportsCompressionMode(PDDNGCompressionMode mode) {
    switch (mode) {
        case PDDNGCompressionModeJPEGLosslessMosaic:
        case PDDNGCompressionModeJXLLossless:
        case PDDNGCompressionModeJXLLossyMosaic:
        case PDDNGCompressionModeJPEGLossyRGB:
            return YES;
    }

    return NO;
}

NSInteger PDDNGSDKDefaultJPEGQuality(void) {
    return 10;
}

NSInteger PDDNGSDKDefaultJXLQuality(void) {
    return kDefaultJXLCompressionQuality;
}

NSInteger PDDNGSDKClampJPEGQuality(NSInteger quality) {
    return ClampQuality(quality, 0, 12);
}

NSInteger PDDNGSDKClampJXLQuality(NSInteger quality) {
    return ClampQuality(quality, kMinJXLCompressionQuality, kMaxJXLCompressionQuality);
}

BOOL PDDNGSDKWriteDNG(NSString *destinationPath,
                      PDDNGCompressionMode compressionMode,
                      NSInteger compressionQuality,
                      NSInteger imageWidth,
                      NSInteger imageHeight,
                      const uint32_t *activeArea,
                      const double *defaultCropOrigin,
                      const double *defaultCropSize,
                      NSData *pixelData,
                      NSInteger bytesPerRow,
                      NSString * _Nullable make,
                      NSString * _Nullable model,
                      NSString *uniqueCameraModel,
                      NSString *software,
                      NSInteger bayerPattern,
                      uint32_t blackLevel,
                      uint32_t whiteLevel,
                      double baselineExposure,
                      uint16_t calibrationIlluminant1,
                      const double *colorMatrix1,
                      const double *asShotNeutral,
                      uint16_t calibrationIlluminant2,
                      const double * _Nullable colorMatrix2,
                      const double * _Nullable forwardMatrix1,
                      const double * _Nullable forwardMatrix2,
                      NSError **error) {
    @autoreleasepool {
        if (activeArea == nullptr || defaultCropOrigin == nullptr ||
            defaultCropSize == nullptr || colorMatrix1 == nullptr ||
            asShotNeutral == nullptr) {
            if (error) {
                *error = BridgeError(1, NSLocalizedString(@"error.bridge.null_metadata_pointer", nil));
            }
            return NO;
        }

        if (pixelData.length == 0) {
            if (error) {
                *error = BridgeError(2, NSLocalizedString(@"error.bridge.empty_pixel_data", nil));
            }
            return NO;
        }

        try {
            PDCustomDNGHost host;
            host.SetSaveDNGVersion(dngVersion_SaveDefault);

            dng_image_writer writer;
            const char *path = destinationPath.fileSystemRepresentation;
            dng_file_stream stream(path, true);

            if (compressionMode == PDDNGCompressionModeJPEGLossyRGB) {
                host.SetSaveLinearDNG(true);
                AutoPtr<dng_negative> negative(BuildLinearJPEGNegative(host,
                                                                      writer,
                                                                      imageWidth,
                                                                      imageHeight,
                                                                      activeArea,
                                                                      defaultCropOrigin,
                                                                      defaultCropSize,
                                                                      pixelData,
                                                                      bytesPerRow,
                                                                      make,
                                                                      model,
                                                                      uniqueCameraModel,
                                                                      software,
                                                                      blackLevel,
                                                                      whiteLevel,
                                                                      baselineExposure,
                                                                      calibrationIlluminant1,
                                                                      colorMatrix1,
                                                                      asShotNeutral,
                                                                      calibrationIlluminant2,
                                                                      colorMatrix2,
                                                                      forwardMatrix1,
                                                                      forwardMatrix2,
                                                                      bayerPattern,
                                                                      compressionQuality));
                writer.WriteDNG(host, stream, *negative.Get(), nullptr, host.SaveDNGVersion(), false);
                stream.Flush();
                return YES;
            }

            AutoPtr<dng_negative> negative(BuildBaseNegative(host,
                                                             imageWidth,
                                                             imageHeight,
                                                             activeArea,
                                                             defaultCropOrigin,
                                                             defaultCropSize,
                                                             make,
                                                             model,
                                                             uniqueCameraModel,
                                                             software,
                                                             blackLevel,
                                                             whiteLevel,
                                                             baselineExposure,
                                                             calibrationIlluminant1,
                                                             colorMatrix1,
                                                             asShotNeutral,

                                                             calibrationIlluminant2,
                                                             colorMatrix2,
                                                             forwardMatrix1,
                                                             forwardMatrix2));
            negative->SetRGB();
            negative->SetBayerMosaic(BayerPhaseForPattern(bayerPattern));

            AutoPtr<dng_image> rawImage(BuildRawMosaicImage(host, imageWidth, imageHeight, pixelData, bytesPerRow));
            negative->SetStage1Image(rawImage);

            switch (compressionMode) {
                case PDDNGCompressionModeJPEGLosslessMosaic:
                    break;

                case PDDNGCompressionModeJXLLossless: {
                    host.SetLosslessJXL(true);
                    AutoPtr<dng_jxl_encode_settings> settings(JXLQualityToSettings(kMaxJXLCompressionQuality));
                    host.SetJXLEncodeSettings(*settings.Get());
                    negative->LosslessCompressJXL(host, writer, false);
                    break;
                }

                case PDDNGCompressionModeJXLLossyMosaic: {
                    host.SetLossyMosaicJXL(true);
                    AutoPtr<dng_jxl_encode_settings> settings(JXLQualityToSettings((uint32) ClampQuality(compressionQuality,
                                                                                                        kMinJXLCompressionQuality,
                                                                                                        kMaxJXLCompressionQuality)));
                    host.SetJXLEncodeSettings(*settings.Get());
                    negative->LossyCompressMosaicJXL(host, writer);
                    break;
                }

                case PDDNGCompressionModeJPEGLossyRGB:
                    break;
            }

            writer.WriteDNG(host, stream, *negative.Get(), nullptr, host.SaveDNGVersion(), false);
            stream.Flush();
            return YES;
        } catch (const dng_exception &exception) {
            if (error) {
                *error = BridgeError(exception.ErrorCode(), @(exception.what()));
            }
            return NO;
        } catch (const std::exception &exception) {
            if (error) {
                *error = BridgeError(1000, @(exception.what()));
            }
            return NO;
        } catch (...) {
            if (error) {
                *error = BridgeError(1001, NSLocalizedString(@"error.bridge.unknown_cpp_exception", nil));
            }
            return NO;
        }
    }
}
