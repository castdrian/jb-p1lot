#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <ifaddrs.h>
#import <arpa/inet.h>
#import <net/if.h>
#import <spawn.h>
#import <unistd.h>

@interface ViewController : UIViewController
@end

@interface ViewController ()
@property(nonatomic, strong) UIScrollView *scrollView;
@property(nonatomic, strong) UIStackView *contentStack;
@property(nonatomic, strong) UILabel *statusLabel;
@property(nonatomic, strong) UILabel *addressLabel;
@property(nonatomic, strong) UILabel *activityLabel;
@property(nonatomic, strong) UIView *statusDot;
@property(nonatomic, strong) CAGradientLayer *backgroundGradient;
@end

extern char **environ;

@implementation ViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemGroupedBackgroundColor;
    [self configureBackground];
    [self configureContent];
    [self refresh];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    self.backgroundGradient.frame = self.view.bounds;
}

- (void)configureBackground {
    self.backgroundGradient = [CAGradientLayer layer];
    self.backgroundGradient.colors = @[
        (__bridge id)[UIColor colorWithRed:0.15 green:0.31 blue:0.66 alpha:0.28].CGColor,
        (__bridge id)[UIColor colorWithRed:0.22 green:0.70 blue:0.67 alpha:0.14].CGColor,
        (__bridge id)UIColor.systemGroupedBackgroundColor.CGColor
    ];
    self.backgroundGradient.locations = @[@0.0, @0.42, @1.0];
    self.backgroundGradient.startPoint = CGPointMake(0.08, 0.0);
    self.backgroundGradient.endPoint = CGPointMake(0.92, 1.0);
    [self.view.layer insertSublayer:self.backgroundGradient atIndex:0];
}

- (void)configureContent {
    self.scrollView = [[UIScrollView alloc] init];
    self.scrollView.alwaysBounceVertical = YES;
    self.scrollView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.scrollView];
    self.contentStack = [[UIStackView alloc] init];
    self.contentStack.axis = UILayoutConstraintAxisVertical;
    self.contentStack.spacing = 16;
    self.contentStack.translatesAutoresizingMaskIntoConstraints = NO;
    [self.scrollView addSubview:self.contentStack];
    [NSLayoutConstraint activateConstraints:@[
        [self.scrollView.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [self.scrollView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.scrollView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.scrollView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [self.contentStack.topAnchor constraintEqualToAnchor:self.scrollView.contentLayoutGuide.topAnchor constant:20],
        [self.contentStack.leadingAnchor constraintEqualToAnchor:self.scrollView.contentLayoutGuide.leadingAnchor constant:20],
        [self.contentStack.trailingAnchor constraintEqualToAnchor:self.scrollView.contentLayoutGuide.trailingAnchor constant:-20],
        [self.contentStack.bottomAnchor constraintEqualToAnchor:self.scrollView.contentLayoutGuide.bottomAnchor constant:-28],
        [self.contentStack.widthAnchor constraintEqualToAnchor:self.scrollView.frameLayoutGuide.widthAnchor constant:-40]
    ]];
    [self.contentStack addArrangedSubview:[self headerCard]];
    [self.contentStack addArrangedSubview:[self statusCard]];
    [self.contentStack addArrangedSubview:[self addressCard]];
    [self.contentStack addArrangedSubview:[self actionsCard]];
    [self.contentStack addArrangedSubview:[self supportCard]];
    [self.contentStack addArrangedSubview:[self activityCard]];
}

- (UIVisualEffectView *)card {
    UIVisualEffectView *card = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemMaterial]];
    card.layer.cornerRadius = 24;
    card.layer.cornerCurve = kCACornerCurveContinuous;
    card.layer.masksToBounds = YES;
    card.translatesAutoresizingMaskIntoConstraints = NO;
    return card;
}

- (UILabel *)label:(NSString *)text style:(UIFontTextStyle)style color:(UIColor *)color {
    UILabel *label = [[UILabel alloc] init];
    label.text = text;
    label.font = [UIFont preferredFontForTextStyle:style];
    label.textColor = color;
    label.adjustsFontForContentSizeCategory = YES;
    label.numberOfLines = 0;
    return label;
}

- (UIView *)headerCard {
    UIVisualEffectView *card = [self card];
    UIStackView *stack = [[UIStackView alloc] init];
    stack.axis = UILayoutConstraintAxisHorizontal;
    stack.alignment = UIStackViewAlignmentCenter;
    stack.spacing = 12;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [card.contentView addSubview:stack];
    UIImageView *icon = [[UIImageView alloc] initWithImage:[UIImage imageNamed:@"AppIcon"]];
    icon.translatesAutoresizingMaskIntoConstraints = NO;
    icon.layer.cornerRadius = 13;
    icon.layer.cornerCurve = kCACornerCurveContinuous;
    icon.layer.masksToBounds = YES;
    icon.accessibilityLabel = @"jb-p1lot icon";
    [NSLayoutConstraint activateConstraints:@[[icon.widthAnchor constraintEqualToConstant:48], [icon.heightAnchor constraintEqualToConstant:48]]];
    [stack addArrangedSubview:icon];
    UILabel *title = [self label:@"jb-p1lot" style:UIFontTextStyleTitle2 color:UIColor.labelColor];
    title.font = [UIFont systemFontOfSize:22 weight:UIFontWeightBold];
    [stack addArrangedSubview:title];
    [NSLayoutConstraint activateConstraints:@[
        [stack.topAnchor constraintEqualToAnchor:card.contentView.topAnchor constant:12],
        [stack.leadingAnchor constraintEqualToAnchor:card.contentView.leadingAnchor constant:14],
        [stack.trailingAnchor constraintEqualToAnchor:card.contentView.trailingAnchor constant:-14],
        [stack.bottomAnchor constraintEqualToAnchor:card.contentView.bottomAnchor constant:-12]
    ]];
    return card;
}

- (UIView *)statusCard {
    UIVisualEffectView *card = [self card];
    UIStackView *stack = [[UIStackView alloc] init];
    stack.axis = UILayoutConstraintAxisHorizontal;
    stack.alignment = UIStackViewAlignmentCenter;
    stack.spacing = 12;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [card.contentView addSubview:stack];
    self.statusDot = [[UIView alloc] init];
    self.statusDot.layer.cornerRadius = 7;
    self.statusDot.translatesAutoresizingMaskIntoConstraints = NO;
    [NSLayoutConstraint activateConstraints:@[[self.statusDot.widthAnchor constraintEqualToConstant:14], [self.statusDot.heightAnchor constraintEqualToConstant:14]]];
    [stack addArrangedSubview:self.statusDot];
    UIStackView *copy = [[UIStackView alloc] init];
    copy.axis = UILayoutConstraintAxisVertical;
    copy.spacing = 2;
    UILabel *heading = [self label:@"Bridge status" style:UIFontTextStyleHeadline color:UIColor.labelColor];
    self.statusLabel = [self label:@"Ready" style:UIFontTextStyleSubheadline color:UIColor.secondaryLabelColor];
    [copy addArrangedSubview:heading];
    [copy addArrangedSubview:self.statusLabel];
    [stack addArrangedSubview:copy];
    UIView *spacer = [[UIView alloc] init];
    [stack addArrangedSubview:spacer];
    UIButton *refresh = [self iconButton:@"arrow.clockwise" title:@"Refresh" action:@selector(refresh)];
    [stack addArrangedSubview:refresh];
    [NSLayoutConstraint activateConstraints:@[
        [stack.topAnchor constraintEqualToAnchor:card.contentView.topAnchor constant:16],
        [stack.leadingAnchor constraintEqualToAnchor:card.contentView.leadingAnchor constant:18],
        [stack.trailingAnchor constraintEqualToAnchor:card.contentView.trailingAnchor constant:-14],
        [stack.bottomAnchor constraintEqualToAnchor:card.contentView.bottomAnchor constant:-16]
    ]];
    return card;
}

- (UIView *)addressCard {
    UIVisualEffectView *card = [self card];
    UIStackView *stack = [[UIStackView alloc] init];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 6;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [card.contentView addSubview:stack];
    UILabel *heading = [self label:@"Connection" style:UIFontTextStyleHeadline color:UIColor.labelColor];
    self.addressLabel = [self label:@"Looking for Wi-Fi addresses…" style:UIFontTextStyleSubheadline color:UIColor.secondaryLabelColor];
    self.addressLabel.font = [UIFont monospacedSystemFontOfSize:13 weight:UIFontWeightRegular];
    [stack addArrangedSubview:heading];
    [stack addArrangedSubview:self.addressLabel];
    [NSLayoutConstraint activateConstraints:@[
        [stack.topAnchor constraintEqualToAnchor:card.contentView.topAnchor constant:16],
        [stack.leadingAnchor constraintEqualToAnchor:card.contentView.leadingAnchor constant:18],
        [stack.trailingAnchor constraintEqualToAnchor:card.contentView.trailingAnchor constant:-18],
        [stack.bottomAnchor constraintEqualToAnchor:card.contentView.bottomAnchor constant:-16]
    ]];
    return card;
}

- (UIView *)actionsCard {
    UIVisualEffectView *card = [self card];
    UIStackView *stack = [[UIStackView alloc] init];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 10;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [card.contentView addSubview:stack];
    [stack addArrangedSubview:[self label:@"Actions" style:UIFontTextStyleHeadline color:UIColor.labelColor]];
    NSArray *rows = @[
        @[[self actionButton:@"Restart bridge" symbol:@"arrow.triangle.2.circlepath" action:@selector(restartBridge)], [self actionButton:@"Rotate identity" symbol:@"key" action:@selector(rotateIdentity)]],
        @[[self actionButton:@"Revoke hosts" symbol:@"person.crop.circle.badge.xmark" action:@selector(revokeHosts)], [self actionButton:@"Diagnostics" symbol:@"waveform.path.ecg" action:@selector(showDiagnostics)]]
    ];
    for (NSArray *buttons in rows) {
        UIStackView *row = [[UIStackView alloc] init];
        row.axis = UILayoutConstraintAxisHorizontal;
        row.spacing = 10;
        row.distribution = UIStackViewDistributionFillEqually;
        for (UIView *button in buttons) [row addArrangedSubview:button];
        [stack addArrangedSubview:row];
    }
    [NSLayoutConstraint activateConstraints:@[
        [stack.topAnchor constraintEqualToAnchor:card.contentView.topAnchor constant:16],
        [stack.leadingAnchor constraintEqualToAnchor:card.contentView.leadingAnchor constant:16],
        [stack.trailingAnchor constraintEqualToAnchor:card.contentView.trailingAnchor constant:-16],
        [stack.bottomAnchor constraintEqualToAnchor:card.contentView.bottomAnchor constant:-16]
    ]];
    return card;
}

- (UIView *)activityCard {
    UIVisualEffectView *card = [self card];
    UIStackView *stack = [[UIStackView alloc] init];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 8;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [card.contentView addSubview:stack];
    [stack addArrangedSubview:[self label:@"Activity" style:UIFontTextStyleHeadline color:UIColor.labelColor]];
    self.activityLabel = [self label:@"No recent activity" style:UIFontTextStyleFootnote color:UIColor.secondaryLabelColor];
    self.activityLabel.font = [UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightRegular];
    [stack addArrangedSubview:self.activityLabel];
    [NSLayoutConstraint activateConstraints:@[
        [stack.topAnchor constraintEqualToAnchor:card.contentView.topAnchor constant:16],
        [stack.leadingAnchor constraintEqualToAnchor:card.contentView.leadingAnchor constant:18],
        [stack.trailingAnchor constraintEqualToAnchor:card.contentView.trailingAnchor constant:-18],
        [stack.bottomAnchor constraintEqualToAnchor:card.contentView.bottomAnchor constant:-16]
    ]];
    return card;
}

- (UIView *)supportCard {
    UIVisualEffectView *card = [self card];
    UIStackView *stack = [[UIStackView alloc] init];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 10;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [card.contentView addSubview:stack];
    [stack addArrangedSubview:[self label:@"Support" style:UIFontTextStyleHeadline color:UIColor.labelColor]];
    [stack addArrangedSubview:[self label:@"If jb-p1lot saves you time, you can support its development." style:UIFontTextStyleSubheadline color:UIColor.secondaryLabelColor]];
    [stack addArrangedSubview:[self actionButton:@"Donate on Ko-fi" symbol:@"heart.fill" action:@selector(openDonationPage)]];
    [NSLayoutConstraint activateConstraints:@[
        [stack.topAnchor constraintEqualToAnchor:card.contentView.topAnchor constant:16],
        [stack.leadingAnchor constraintEqualToAnchor:card.contentView.leadingAnchor constant:16],
        [stack.trailingAnchor constraintEqualToAnchor:card.contentView.trailingAnchor constant:-16],
        [stack.bottomAnchor constraintEqualToAnchor:card.contentView.bottomAnchor constant:-16]
    ]];
    return card;
}

- (UIButton *)iconButton:(NSString *)symbol title:(NSString *)title action:(SEL)action {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    if (@available(iOS 15.0, *)) {
        UIButtonConfiguration *configuration = [UIButtonConfiguration plainButtonConfiguration];
        configuration.image = [UIImage systemImageNamed:symbol];
        configuration.title = title;
        configuration.imagePadding = 4;
        button.configuration = configuration;
    } else {
        [button setImage:[UIImage systemImageNamed:symbol] forState:UIControlStateNormal];
        [button setTitle:title forState:UIControlStateNormal];
    }
    button.accessibilityLabel = title;
    [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return button;
}

- (UIButton *)actionButton:(NSString *)title symbol:(NSString *)symbol action:(SEL)action {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    if (@available(iOS 15.0, *)) {
        UIButtonConfiguration *configuration = [UIButtonConfiguration tintedButtonConfiguration];
        configuration.image = [UIImage systemImageNamed:symbol];
        configuration.title = title;
        configuration.imagePadding = 8;
        configuration.contentInsets = NSDirectionalEdgeInsetsMake(12, 12, 12, 12);
        configuration.cornerStyle = UIButtonConfigurationCornerStyleMedium;
        button.configuration = configuration;
    } else {
        [button setTitle:title forState:UIControlStateNormal];
        [button setImage:[UIImage systemImageNamed:symbol] forState:UIControlStateNormal];
    }
    button.titleLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
    button.titleLabel.adjustsFontForContentSizeCategory = YES;
    button.accessibilityLabel = title;
    [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return button;
}

- (void)refresh {
    BOOL disabled = [[NSFileManager defaultManager] fileExistsAtPath:@"/var/jb/var/root/Library/Preferences/dev.adrian.jb-p1lot.disabled"];
    self.statusDot.backgroundColor = disabled ? UIColor.systemRedColor : UIColor.systemGreenColor;
    self.statusLabel.text = disabled ? @"Disabled" : @"Ready";
    NSMutableArray *addresses = [NSMutableArray array];
    struct ifaddrs *interfaces = NULL;
    if (getifaddrs(&interfaces) == 0) {
        for (struct ifaddrs *entry = interfaces; entry; entry = entry->ifa_next) {
            if (!entry->ifa_addr || !(entry->ifa_flags & IFF_UP) || entry->ifa_addr->sa_family != AF_INET) continue;
            char value[INET_ADDRSTRLEN] = {0};
            inet_ntop(AF_INET, &((struct sockaddr_in *)entry->ifa_addr)->sin_addr, value, sizeof(value));
            NSString *address = [NSString stringWithUTF8String:value];
            if (address && ![addresses containsObject:address] && ![address isEqualToString:@"127.0.0.1"]) [addresses addObject:address];
        }
        freeifaddrs(interfaces);
    }
    self.addressLabel.text = addresses.count ? [addresses componentsJoinedByString:@"\n"] : @"Wi-Fi address unavailable";
}

- (void)appendActivity:(NSString *)value {
    NSString *existing = self.activityLabel.text;
    if ([existing isEqualToString:@"No recent activity"]) existing = @"";
    self.activityLabel.text = existing.length ? [NSString stringWithFormat:@"%@\n%@", value, existing] : value;
}

- (void)restartBridge {
    char *args[] = {"launchctl", "kickstart", "-k", "user/501/dev.adrian.jb-p1lot.daemon", NULL};
    pid_t pid = 0;
    posix_spawn(&pid, "/var/jb/usr/bin/launchctl", NULL, NULL, args, environ);
    self.statusLabel.text = @"Restart requested";
    [self appendActivity:@"Bridge restart requested"];
}

- (void)rotateIdentity {
    [@"rotate" writeToFile:@"/var/jb/var/root/Library/Preferences/dev.adrian.jb-p1lot.rotate" atomically:YES encoding:NSUTF8StringEncoding error:nil];
    [self appendActivity:@"Identity rotation queued"];
}

- (void)revokeHosts {
    unlink("/var/jb/var/root/Library/Preferences/dev.adrian.jb-p1lot.pairings");
    [self appendActivity:@"All paired hosts revoked"];
}

- (void)showDiagnostics {
    [self appendActivity:@"Diagnostics requested"];
}

- (void)openDonationPage {
    NSURL *url = [NSURL URLWithString:@"https://ko-fi.com/castdrian"];
    if (url) {
        [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:nil];
        [self appendActivity:@"Donation page opened"];
    }
}

@end
