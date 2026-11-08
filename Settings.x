#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <math.h>
#import <PSHeader/Misc.h>
#import <YouTubeHeader/GOOHeaderViewController.h>
#import <YouTubeHeader/YTUIUtils.h>
#import <YouTubeMusicHeader/YTMAlertView.h>
#import "../Return-YouTube-Dislikes/Settings.h"
#import "../Return-YouTube-Dislikes/TweakSettings.h"

// YTMAccountButton is the same account-menu entry point used by YTMusicUltimate.
@interface YTMAccountButton : UIButton
- (id)initWithTitle:(id)title
         identifier:(id)identifier
               icon:(id)icon
        actionBlock:(void (^)(BOOL finished))actionBlock;
@end

@interface YTMAvatarAccountView : UIView
@end

@interface UIView (RYMDPrivate)
- (id)_viewControllerForAncestor;
@end

// New Auto Skip preferences. These strings must match the keys in Tweak.x.
static NSString * const RYMDAutoSkipEnabledKey = @"RYMDAutoSkipEnabled";
static NSString * const RYMDMinimumDislikesKey = @"RYMDMinimumDislikes";
static NSString * const RYMDMinimumRatioKey = @"RYMDMinimumDislikeLikeRatio";

static NSString * const RYMDAccountButtonTitle = @"Return YouTube Music Dislikes";

NSBundle *RYMDBundle(void) {
    static NSBundle *bundle = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSString *tweakBundlePath = [[NSBundle mainBundle] pathForResource:@"RYMD" ofType:@"bundle"];
        bundle = [NSBundle bundleWithPath:tweakBundlePath ?: PS_ROOT_PATH_NS(@"/Library/Application Support/RYMD.bundle")];
    });
    return bundle;
}

#pragma mark - Standalone RYMD Account settings page

@interface RYMDAccountSettingsController : UIViewController <UITableViewDataSource, UITableViewDelegate, UITextFieldDelegate>
@property (nonatomic, strong) UITableView *tableView;
@end

@implementation RYMDAccountSettingsController

- (void)viewDidLoad {
    [super viewDidLoad];

    self.title = RYMDAccountButtonTitle;
    self.view.backgroundColor = [UIColor systemGroupedBackgroundColor];

    self.tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStyleGrouped];
    self.tableView.translatesAutoresizingMaskIntoConstraints = NO;
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    self.tableView.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;
    [self.view addSubview:self.tableView];

    [NSLayoutConstraint activateConstraints:@[
        [self.tableView.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [self.tableView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [self.tableView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.tableView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor]
    ]];

    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone
                                                                                           target:self
                                                                                           action:@selector(closeSettings)];
}

- (void)closeSettings {
    [self.navigationController dismissViewControllerAnimated:YES completion:nil];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 2;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return section == 0 ? 5 : 2;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return section == 0 ? @"General" : @"Automatic Skip";
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (section == 1) {
        return @"A song is skipped only when both minimum thresholds are reached. Automatic skipping is disabled by default.";
    }
    return nil;
}

- (BOOL)switchValueForRow:(NSInteger)row {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    switch (row) {
        case 0: return TweakEnabled();
        case 1: return VoteSubmissionEnabled();
        case 2: return ExactDislikeNumber();
        case 3: return ExactLikeNumber();
        case 4: return [defaults objectForKey:RYMDAutoSkipEnabledKey]
            ? [defaults boolForKey:RYMDAutoSkipEnabledKey] : NO;
        default: return NO;
    }
}

- (NSString *)titleForSwitchRow:(NSInteger)row {
    switch (row) {
        case 0: return @"Enabled";
        case 1: return @"Vote Submission";
        case 2: return @"Exact Dislike Number";
        case 3: return @"Exact Like Number";
        case 4: return @"Auto Skip Disliked Songs";
        default: return @"";
    }
}

- (void)switchChanged:(UISwitch *)sender {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    switch (sender.tag) {
        case 0:
            [defaults setBool:sender.on forKey:EnabledKey];
            break;
        case 1:
            enableVoteSubmission(sender.on);
            break;
        case 2:
            [defaults setBool:sender.on forKey:ExactDislikeKey];
            break;
        case 3:
            [defaults setBool:sender.on forKey:ExactLikeKey];
            break;
        case 4:
            [defaults setBool:sender.on forKey:RYMDAutoSkipEnabledKey];
            break;
    }
}

- (double)defaultValueForThresholdRow:(NSInteger)row {
    return row == 0 ? 100000.0 : 30.0;
}

- (NSString *)storedValueForThresholdRow:(NSInteger)row {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSString *key = row == 0 ? RYMDMinimumDislikesKey : RYMDMinimumRatioKey;
    id storedValue = [defaults objectForKey:key];
    double value = [storedValue respondsToSelector:@selector(doubleValue)]
        ? [storedValue doubleValue] : [self defaultValueForThresholdRow:row];
    if (!isfinite(value) || value < 0.0) value = [self defaultValueForThresholdRow:row];

    NSNumber *number = row == 0 ? @((long long)value) : @(value);
    return [NSNumberFormatter localizedStringFromNumber:number numberStyle:NSNumberFormatterDecimalStyle];
}

- (UITextField *)thresholdTextFieldForRow:(NSInteger)row {
    UITextField *field = [[UITextField alloc] initWithFrame:CGRectMake(0, 0, 118, 34)];
    field.delegate = self;
    field.tag = row;
    field.textAlignment = NSTextAlignmentRight;
    field.keyboardType = row == 0 ? UIKeyboardTypeNumberPad : UIKeyboardTypeDecimalPad;
    field.borderStyle = UITextBorderStyleNone;
    field.placeholder = row == 0 ? @"100000" : @"30";
    field.text = [self storedValueForThresholdRow:row];
    field.accessibilityLabel = row == 0 ? @"Minimum Dislikes" : @"Minimum Dislike/Like Ratio";

    UIToolbar *toolbar = [[UIToolbar alloc] initWithFrame:CGRectMake(0, 0, 0, 44)];
    UIBarButtonItem *flexibleSpace = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace
                                                                                   target:nil
                                                                                   action:nil];
    UIBarButtonItem *done = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone
                                                                          target:self
                                                                          action:@selector(dismissThresholdKeyboard:)];
    toolbar.items = @[flexibleSpace, done];
    field.inputAccessoryView = toolbar;
    return field;
}

- (void)dismissThresholdKeyboard:(id)sender {
    [self.view endEditing:YES];
}

- (void)saveThresholdField:(UITextField *)textField {
    NSInteger row = textField.tag;
    NSString *key = row == 0 ? RYMDMinimumDislikesKey : RYMDMinimumRatioKey;
    NSString *text = [textField.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];

    if (text.length == 0) {
        text = [NSString stringWithFormat:@"%.0f", [self defaultValueForThresholdRow:row]];
    }

    NSNumberFormatter *formatter = [NSNumberFormatter new];
    formatter.numberStyle = NSNumberFormatterDecimalStyle;
    NSNumber *number = [formatter numberFromString:text];
    if (!number) {
        // Accept a period as the decimal separator even when the device locale uses a comma.
        number = @([text doubleValue]);
    }

    double value = number.doubleValue;
    if (!isfinite(value) || value < 0.0) {
        value = [self defaultValueForThresholdRow:row];
    }
    if (row == 0) value = floor(value);

    [[NSUserDefaults standardUserDefaults] setObject:@(value) forKey:key];
    textField.text = [self storedValueForThresholdRow:row];
}

- (void)textFieldDidEndEditing:(UITextField *)textField {
    [self saveThresholdField:textField];
}

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    [textField resignFirstResponder];
    return YES;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section == 0) {
        static NSString * const switchReuseIdentifier = @"RYMDSwitchSettingCell";
        UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:switchReuseIdentifier];
        if (!cell) {
            cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:switchReuseIdentifier];
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
        }

        cell.textLabel.text = [self titleForSwitchRow:indexPath.row];
        UISwitch *settingSwitch = [[UISwitch alloc] initWithFrame:CGRectZero];
        settingSwitch.tag = indexPath.row;
        settingSwitch.on = [self switchValueForRow:indexPath.row];
        [settingSwitch addTarget:self action:@selector(switchChanged:) forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = settingSwitch;
        return cell;
    }

    static NSString * const thresholdReuseIdentifier = @"RYMDThresholdSettingCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:thresholdReuseIdentifier];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:thresholdReuseIdentifier];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    }

    NSInteger row = indexPath.row;
    cell.textLabel.text = row == 0 ? @"Minimum Dislikes" : @"Minimum Dislike/Like Ratio (%)";
    cell.accessoryView = [self thresholdTextFieldForRow:row];
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section == 1) {
        UITableViewCell *cell = [tableView cellForRowAtIndexPath:indexPath];
        if ([cell.accessoryView isKindOfClass:[UITextField class]]) {
            [(UITextField *)cell.accessoryView becomeFirstResponder];
        }
    }
}

@end

#pragma mark - Account menu integration

%group RYMDAccountSettings

%hook YTMAvatarAccountView

- (void)setAccountMenuUpperButtons:(id)upperButtons lowerButtons:(id)lowerButtons {
    NSMutableArray *newUpperButtons = [upperButtons isKindOfClass:[NSArray class]]
        ? [upperButtons mutableCopy] : [NSMutableArray new];
    NSMutableArray *newLowerButtons = [lowerButtons isKindOfClass:[NSArray class]]
        ? [lowerButtons mutableCopy] : [NSMutableArray new];

    BOOL alreadyAdded = NO;
    for (id accountButton in [newUpperButtons arrayByAddingObjectsFromArray:newLowerButtons]) {
        if ([[[accountButton titleLabel] text] isEqualToString:RYMDAccountButtonTitle]) {
            alreadyAdded = YES;
            break;
        }
    }

    if (!alreadyAdded) {
        UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(24, 24)];
        UIImage *icon = [renderer imageWithActions:^(UIGraphicsImageRendererContext *rendererContext) {
            UIImage *symbol = nil;
            if ([UIImage respondsToSelector:@selector(systemImageNamed:)]) {
                symbol = [UIImage systemImageNamed:@"hand.thumbsdown.fill"];
                if (!symbol) symbol = [UIImage systemImageNamed:@"hand.thumbsdown"];
            }
            if (!symbol) return;

            UIImageView *imageView = [[UIImageView alloc] initWithImage:symbol];
            imageView.contentMode = UIViewContentModeScaleAspectFit;
            imageView.frame = CGRectMake(0, 0, 24, 24);
            imageView.tintColor = [UIColor darkGrayColor];
            [imageView.layer renderInContext:rendererContext.CGContext];
        }];

        __weak YTMAvatarAccountView *weakAccountView = self;
        YTMAccountButton *button = [[%c(YTMAccountButton) alloc] initWithTitle:RYMDAccountButtonTitle
                                                                    identifier:@"rymd"
                                                                          icon:icon
                                                                   actionBlock:^(BOOL finished) {
            YTMAvatarAccountView *accountView = weakAccountView;
            UIViewController *presenter = (UIViewController *)[accountView _viewControllerForAncestor];
            if (![presenter isKindOfClass:[UIViewController class]]) return;

            RYMDAccountSettingsController *settingsController = [RYMDAccountSettingsController new];
            UINavigationController *navigationController = [[UINavigationController alloc] initWithRootViewController:settingsController];
            navigationController.modalPresentationStyle = UIModalPresentationFullScreen;
            [presenter presentViewController:navigationController animated:YES completion:nil];
        }];

        button.tintColor = [UIColor darkGrayColor];
        button.accessibilityIdentifier = @"rymd_account_settings";
        [newLowerButtons addObject:button];
    }

    %orig(newUpperButtons, newLowerButtons);
}

%end

%end

%ctor {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    if (![defaults boolForKey:DidShowEnableVoteSubmissionAlertKey] && !VoteSubmissionEnabled()) {
        [defaults setBool:YES forKey:DidShowEnableVoteSubmissionAlertKey];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            NSBundle *tweakBundle = RYMDBundle();
            YTMAlertView *alertView = [%c(YTMAlertView) confirmationDialogWithAction:^{
                enableVoteSubmission(YES);
            } actionTitle:_LOC([NSBundle mainBundle], @"dialog.okay")];
            alertView.title = @(TWEAK_NAME);
            alertView.subtitle = [NSString stringWithFormat:LOC(@"WANT_TO_ENABLE"), @(API_URL), @(TWEAK_NAME), LOC(@"ENABLE_VOTE_SUBMIT")];
            [alertView show];
            (void)tweakBundle;
        });
    }

    %init(RYMDAccountSettings);
}
