#import <UIKit/UIKit.h>
#import <CoreGraphics/CoreGraphics.h>
#import <IOSurface/IOSurfaceRef.h>
#import <mach/mach.h>
#import <dlfcn.h>
#import <objc/message.h>
#import "DisplayControl.h"

extern UIImage *_UICreateScreenUIImage(void) __attribute__((weak_import));

typedef CGImageRef (*JBP1lotWindowImageFunction)(CGRect, uint32_t, uint32_t, uint32_t);
typedef kern_return_t (*JBP1lotRenderDisplayFunction)(mach_port_t, CFStringRef, IOSurfaceRef, int, int);

static UIImage *JBP1lotCARenderImage(void) {
    void *framework = dlopen("/System/Library/Frameworks/QuartzCore.framework/QuartzCore", RTLD_NOW | RTLD_GLOBAL);
    JBP1lotRenderDisplayFunction renderDisplay = framework
        ? (JBP1lotRenderDisplayFunction)dlsym(framework, "CARenderServerRenderDisplay")
        : NULL;
    if (!renderDisplay)
        return nil;

    UIScreen *screen = UIScreen.mainScreen;
    CGSize pointSize = screen.bounds.size;
    CGFloat scale = screen.scale > 1.0 ? screen.scale : 1.0;
    size_t width = (size_t)MAX(1.0, round(pointSize.width * scale));
    size_t height = (size_t)MAX(1.0, round(pointSize.height * scale));
    size_t bytesPerRow = (width * 4 + 63) & ~((size_t)63);
    NSDictionary *properties = @{
        (id)kIOSurfaceWidth: @(width),
        (id)kIOSurfaceHeight: @(height),
        (id)kIOSurfacePixelFormat: @(0x42475241u),
        (id)kIOSurfaceBytesPerElement: @4,
        (id)kIOSurfaceBytesPerRow: @(bytesPerRow),
        (id)kIOSurfaceAllocSize: @(bytesPerRow * height)
    };
    IOSurfaceRef surface = IOSurfaceCreate((__bridge CFDictionaryRef)properties);
    if (!surface)
        return nil;

    UIImage *image = nil;
    if (renderDisplay(0, NULL, surface, 0, 0) == KERN_SUCCESS &&
        IOSurfaceLock(surface, kIOSurfaceLockReadOnly, NULL) == 0) {
        void *baseAddress = IOSurfaceGetBaseAddress(surface);
        size_t dataLength = bytesPerRow * height;
        if (baseAddress) {
            CFDataRef pixelData = CFDataCreate(kCFAllocatorDefault, baseAddress, (CFIndex)dataLength);
            CGDataProviderRef provider = pixelData ? CGDataProviderCreateWithCFData(pixelData) : NULL;
            CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
            CGImageRef imageRef = provider && colorSpace
                ? CGImageCreate(width,
                                height,
                                8,
                                32,
                                bytesPerRow,
                                colorSpace,
                                kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little,
                                provider,
                                NULL,
                                false,
                                kCGRenderingIntentDefault)
                : NULL;
            if (imageRef) {
                image = [UIImage imageWithCGImage:imageRef scale:scale orientation:UIImageOrientationUp];
                CGImageRelease(imageRef);
            }
            if (colorSpace)
                CGColorSpaceRelease(colorSpace);
            if (provider)
                CGDataProviderRelease(provider);
            if (pixelData)
                CFRelease(pixelData);
        }
        IOSurfaceUnlock(surface, kIOSurfaceLockReadOnly, NULL);
    }
    CFRelease(surface);
    return image;
}

static BOOL JBP1lotImageHasVisiblePixels(UIImage *image) {
    CGImageRef imageRef = image.CGImage;
    if (!imageRef)
        return NO;

    const size_t sampleSize = 16;
    uint8_t pixels[16 * 16 * 4] = {0};
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = colorSpace
        ? CGBitmapContextCreate(pixels,
                                sampleSize,
                                sampleSize,
                                8,
                                sampleSize * 4,
                                colorSpace,
                                kCGImageAlphaNoneSkipLast | kCGBitmapByteOrder32Big)
        : NULL;
    if (colorSpace)
        CGColorSpaceRelease(colorSpace);
    if (!context)
        return YES;

    CGContextSetInterpolationQuality(context, kCGInterpolationLow);
    CGContextDrawImage(context, CGRectMake(0, 0, sampleSize, sampleSize), imageRef);
    BOOL visible = NO;
    for (size_t index = 0; index < sampleSize * sampleSize; index++) {
        const uint8_t *pixel = pixels + index * 4;
        if (pixel[0] > 8 || pixel[1] > 8 || pixel[2] > 8) {
            visible = YES;
            break;
        }
    }
    CGContextRelease(context);
    return visible;
}

NSData *JBP1lotCapturePNG(void) {
    __block UIImage *image = nil;
    void (^capture)(void) = ^{
        if (JBP1lotDisplayIsEnabled())
            JBP1lotWakeDisplay();
        if (&_UICreateScreenUIImage)
            image = _UICreateScreenUIImage();

        if (!JBP1lotImageHasVisiblePixels(image))
            image = JBP1lotCARenderImage();

        JBP1lotWindowImageFunction windowImage = (JBP1lotWindowImageFunction)dlsym(RTLD_DEFAULT, "CGWindowListCreateImage");
        if (!JBP1lotImageHasVisiblePixels(image) && windowImage) {
            CGImageRef imageRef = windowImage(CGRectNull, 1u, 0u, 0u);
            if (imageRef) {
                UIImage *windowImage = [UIImage imageWithCGImage:imageRef scale:UIScreen.mainScreen.scale orientation:UIImageOrientationUp];
                CGImageRelease(imageRef);
                if (JBP1lotImageHasVisiblePixels(windowImage))
                    image = windowImage;
            }
        }

        if (!image) {
            UIScreen *screen = UIScreen.mainScreen;
            CGSize size = screen.bounds.size;
            UIGraphicsBeginImageContextWithOptions(size, YES, screen.scale);
            [[UIColor blackColor] setFill];
            UIRectFill((CGRect){CGPointZero, size});
            image = UIGraphicsGetImageFromCurrentImageContext();
            UIGraphicsEndImageContext();
        }
    };
    if ([NSThread isMainThread])
        capture();
    else
        dispatch_sync(dispatch_get_main_queue(), capture);
    return image ? UIImagePNGRepresentation(image) : nil;
}
