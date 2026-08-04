#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>

// ============================================================
// 违规弹窗检测 Tweak（Dopamine 越狱）
// 功能：Hook UIAlertController，检测到违规/人脸识别等弹窗
//       → POST 到服务器 /api/violation_report → Bark 推送
// 配置：/var/mobile/Library/Preferences/com.ailive.violationalert.plist
//   {
//     device_id: "iPhone播放端6位ID",   // 必填
//     server: "http://59.110.152.66:18766",
//     test_mode: true,                  // 测试模式：自动弹测试窗+所有弹窗都上报
//     keywords: ["自定义词1", ...]       // 可选：覆盖默认关键词表
//   }
// ============================================================

static NSString *kPrefsPath = @"/var/mobile/Library/Preferences/com.ailive.violationalert.plist";
static BOOL gTestMode = NO;
static BOOL gTestAlertShown = NO;

@interface ViolationAlertHelper : NSObject
+ (instancetype)shared;
- (void)checkAlert:(UIAlertController *)alert;
- (void)showTestAlert;
@end

@implementation ViolationAlertHelper

+ (instancetype)shared {
    static ViolationAlertHelper *inst = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        inst = [[ViolationAlertHelper alloc] init];
    });
    return inst;
}

// 读取配置
- (NSDictionary *)loadConfig {
    NSDictionary *cfg = [NSDictionary dictionaryWithContentsOfFile:kPrefsPath];
    if (!cfg) cfg = @{};
    return cfg;
}

// 关键词匹配（命中任意一个即报警）
- (BOOL)matchKeyword:(NSString *)text {
    NSArray *defaultKeywords = @[
        @"人脸识别", @"人脸验证", @"身份验证", @"实名认证",
        @"违规", @"违规内容", @"涉嫌违规", @"违反",
        @"警告", @"提醒", @"封禁", @"禁播", @"限流",
        @"直播中断", @"直播异常", @"直播已结束",
        @"安全验证", @"验证码", @"异常登录", @"账号异常",
        @"未成年人", @"青少年模式", @"低俗", @"涉黄", @"涉政",
        @"停止直播", @"暂时无法", @"操作频繁"
    ];
    // 支持 plist 里自定义关键词覆盖
    NSDictionary *cfg = [self loadConfig];
    NSArray *keywords = cfg[@"keywords"];
    if (![keywords isKindOfClass:[NSArray class]] || keywords.count == 0) {
        keywords = defaultKeywords;
    }
    for (NSString *kw in keywords) {
        if ([kw isKindOfClass:[NSString class]] && [text containsString:kw]) return YES;
    }
    return NO;
}

// 上报到服务器
- (void)reportToServer:(NSString *)text app:(NSString *)app {
    NSDictionary *cfg = [self loadConfig];
    NSString *deviceId = cfg[@"device_id"] ?: @"";
    NSString *server = cfg[@"server"] ?: @"http://59.110.152.66:18766";
    if (!deviceId.length) {
        NSLog(@"[ViolationAlert] 未配置 device_id，跳过上报");
        return;
    }
    NSString *urlStr = [NSString stringWithFormat:@"%@/api/violation_report", server];
    NSURL *url = [NSURL URLWithString:urlStr];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.HTTPMethod = @"POST";
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    NSDictionary *body = @{
        @"device_id": deviceId,
        @"text": text,
        @"app": app ?: @"douyin"
    };
    NSError *err = nil;
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:body options:0 error:&err];
    if (err) {
        NSLog(@"[ViolationAlert] JSON序列化失败: %@", err);
        return;
    }
    req.HTTPBody = jsonData;
    NSURLSession *session = [NSURLSession sharedSession];
    NSURLSessionDataTask *task = [session dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *resp, NSError *error) {
        if (error) {
            NSLog(@"[ViolationAlert] 上报失败: %@", error);
        } else {
            NSLog(@"[ViolationAlert] 上报成功: %@", text);
        }
    }];
    [task resume];
}

// 检测弹窗（入口）
- (void)checkAlert:(UIAlertController *)alert {
    NSString *title = alert.title ?: @"";
    NSString *message = alert.message ?: @"";
    NSString *full = [NSString stringWithFormat:@"%@ %@", title, message];
    full = [full stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!full.length) return;

    // 测试模式：任何弹窗都上报
    if (gTestMode) {
        NSLog(@"[ViolationAlert] [测试模式] 弹窗: %@", full);
        NSString *appName = [[NSBundle mainBundle] bundleIdentifier] ?: @"unknown";
        [self reportToServer:full app:appName];
        return;
    }

    // 正常模式：关键词匹配
    if ([self matchKeyword:full]) {
        NSLog(@"[ViolationAlert] 🚨 检测到违规弹窗: %@", full);
        NSString *appName = [[NSBundle mainBundle] bundleIdentifier] ?: @"unknown";
        [self reportToServer:full app:appName];
    }
}

// 测试模式：自动弹一个模拟违规弹窗（验证全链路）
- (void)showTestAlert {
    if (gTestAlertShown) return;
    gTestAlertShown = YES;
    dispatch_async(dispatch_get_main_queue(), ^{
        UIAlertController *testAlert = [UIAlertController alertControllerWithTitle:@"测试弹窗"
                                                                          message:@"【ViolationAlert测试】人脸识别验证，请完成验证后继续直播。这是一条模拟违规弹窗，用于验证检测链路。"
                                                                   preferredStyle:UIAlertControllerStyleAlert];
        [testAlert addAction:[UIAlertAction actionWithTitle:@"知道了" style:UIAlertActionStyleDefault handler:nil]];
        // iOS 13+ 多场景：用 connectedScenes 拿 keyWindow（避免 keyWindow 弃用警告）
        UIWindow *keyWindow = nil;
        for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
            if ([scene isKindOfClass:[UIWindowScene class]] && scene.activationState == UISceneActivationStateForegroundActive) {
                UIWindowScene *ws = (UIWindowScene *)scene;
                for (UIWindow *w in ws.windows) {
                    if (w.isKeyWindow) { keyWindow = w; break; }
                }
                if (keyWindow) break;
            }
        }
        UIViewController *root = keyWindow.rootViewController;
        if (root) {
            [root presentViewController:testAlert animated:YES completion:nil];
        }
    });
}

@end

// ============ Hook 点 ============

%hook UIAlertController

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    [[ViolationAlertHelper shared] checkAlert:self];
}

%end

%ctor {
    NSLog(@"[ViolationAlert] 违规弹窗检测已加载 ✅");
    NSDictionary *cfg = [NSDictionary dictionaryWithContentsOfFile:kPrefsPath];
    gTestMode = [cfg[@"test_mode"] boolValue];
    if (gTestMode) {
        NSLog(@"[ViolationAlert] 🔧 测试模式开启：自动弹测试窗 + 所有弹窗上报");
        // 延迟几秒等抖音界面就绪后弹测试窗
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [[ViolationAlertHelper shared] showTestAlert];
        });
    }
}
