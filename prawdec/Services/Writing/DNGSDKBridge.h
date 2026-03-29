//
//  DNGSDKBridge.h
//  prawdec
//
//  Created by Codex on 2026/3/28.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, PDDNGCompressionMode) {
    PDDNGCompressionModeJPEGLosslessMosaic = 0,
    PDDNGCompressionModeJXLLossless = 1,
    PDDNGCompressionModeJXLLossyMosaic = 2,
    PDDNGCompressionModeJPEGLossyRGB = 3,
};

FOUNDATION_EXPORT NSString *PDDNGSDKVersionString(void);
FOUNDATION_EXPORT BOOL PDDNGSDKSupportsCompressionMode(PDDNGCompressionMode mode);
FOUNDATION_EXPORT NSInteger PDDNGSDKDefaultJPEGQuality(void);
FOUNDATION_EXPORT NSInteger PDDNGSDKDefaultJXLQuality(void);
FOUNDATION_EXPORT NSInteger PDDNGSDKClampJPEGQuality(NSInteger quality);
FOUNDATION_EXPORT NSInteger PDDNGSDKClampJXLQuality(NSInteger quality);
FOUNDATION_EXPORT BOOL PDDNGSDKWriteDNG(NSString *destinationPath,
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
                                        NSError **error);

NS_ASSUME_NONNULL_END
