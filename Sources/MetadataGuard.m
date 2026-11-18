#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <string.h>

// Swift 的 do/catch 抓不到 Objective-C 异常（会直接 objc_exception_throw → SIGABRT）。
// 真机崩溃栈已确认：-[AVAssetWriterInputMetadataAdaptor appendTimedMetadataGroup:]
// 在 iOS 27 上抛异常导致闪退。这里用 ObjC @try/@catch 兜住，返回原因给 Swift 写日志。

static char gReason[768] = {0};

int32_t LPWAppendMetadata(id adaptor, id group) {
    gReason[0] = 0;
    @try {
        BOOL ok = [adaptor performSelector:@selector(appendTimedMetadataGroup:) withObject:group];
        return ok ? 1 : 0;
    } @catch (NSException *ex) {
        NSString *s = [NSString stringWithFormat:@"%@ | %@",
                       ex.name ?: @"NSException",
                       ex.reason ?: @"(no reason)"];
        const char *c = [s UTF8String];
        if (c) {
            strncpy(gReason, c, sizeof(gReason) - 1);
            gReason[sizeof(gReason) - 1] = 0;
        }
        return -1;
    }
}

const char *LPWLastMetadataError(void) {
    return gReason;
}
