#import "PPSettingsViewController.h"
#import "PPCatalogService.h"

// Sections.
typedef NS_ENUM(NSInteger, PPSettingsSection) {
    PPSettingsSectionCatalog = 0,   // GitHub token
    PPSettingsSectionAbout,         // version, repo link, report issue
    PPSettingsSectionCount,
};

@interface PPSettingsViewController ()
@end

@implementation PPSettingsViewController

- (instancetype)init {
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    if (self) {
        self.title = @"Settings";
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    [self.tableView registerClass:[UITableViewCell class]
           forCellReuseIdentifier:@"row"];
    self.tableView.cellLayoutMarginsFollowReadableWidth = YES;
}

#pragma mark - Helpers

// Convenience accessor — pulls CFBundleShortVersionString from Info.plist
// so the row labels stay in sync if we bump versions later.
- (NSString *)appVersionString {
    NSDictionary *info = [NSBundle mainBundle].infoDictionary;
    NSString *v = info[@"CFBundleShortVersionString"] ?: @"0.0";
    NSString *b = info[@"CFBundleVersion"]            ?: @"1";
    return [NSString stringWithFormat:@"%@ (%@)", v, b];
}

#pragma mark - UITableViewDataSource

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return PPSettingsSectionCount;
}

- (NSInteger)tableView:(UITableView *)tableView
 numberOfRowsInSection:(NSInteger)section {
    switch (section) {
        case PPSettingsSectionCatalog: return 1; // GitHub token
        case PPSettingsSectionAbout:   return 3; // version / repo / report
        default:                       return 0;
    }
}

- (NSString *)tableView:(UITableView *)tableView
titleForHeaderInSection:(NSInteger)section {
    switch (section) {
        case PPSettingsSectionCatalog: return @"Online catalog";
        case PPSettingsSectionAbout:   return @"About";
        default:                       return nil;
    }
}

- (NSString *)tableView:(UITableView *)tableView
titleForFooterInSection:(NSInteger)section {
    if (section == PPSettingsSectionCatalog) {
        return @"Optional. Without a token GitHub allows ~60 catalog "
               @"refreshes per hour. With a personal access token (any "
               @"scope) the limit jumps to 5000/hour. Generate one at "
               @"github.com/settings/tokens.";
    }
    return nil;
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"row"
                                                            forIndexPath:indexPath];
    cell.accessoryType    = UITableViewCellAccessoryNone;
    cell.accessoryView    = nil;
    cell.textLabel.text   = nil;
    cell.detailTextLabel.text = nil;
    cell.selectionStyle   = UITableViewCellSelectionStyleDefault;

    if (indexPath.section == PPSettingsSectionCatalog) {
        // GitHub token row. Shows whether one is set, lets the user
        // tap to enter / clear it.
        NSString *t = [PPCatalogService shared].githubToken;
        cell.textLabel.text = @"GitHub Token";
        cell.detailTextLabel.text = t.length ? @"Set" : @"None";
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        return cell;
    }

    if (indexPath.section == PPSettingsSectionAbout) {
        switch (indexPath.row) {
            case 0:
                cell.textLabel.text       = @"Version";
                cell.detailTextLabel.text = [self appVersionString];
                cell.selectionStyle = UITableViewCellSelectionStyleNone;
                break;
            case 1:
                cell.textLabel.text = @"View on GitHub";
                cell.accessoryType  = UITableViewCellAccessoryDisclosureIndicator;
                break;
            case 2:
                cell.textLabel.text = @"Report an issue";
                cell.accessoryType  = UITableViewCellAccessoryDisclosureIndicator;
                break;
        }
    }
    return cell;
}

#pragma mark - UITableViewDelegate

- (void)tableView:(UITableView *)tableView
didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];

    if (indexPath.section == PPSettingsSectionCatalog) {
        [self promptForGithubToken];
        return;
    }

    if (indexPath.section == PPSettingsSectionAbout) {
        switch (indexPath.row) {
            case 1: // GitHub
                [self openURL:@"https://github.com/kirayxa2/PocketPlayer"];
                break;
            case 2: // Report issue
                [self openURL:@"https://github.com/kirayxa2/PocketPlayer/issues/new"];
                break;
        }
    }
}

#pragma mark - Token entry

// UIAlertController with a single secure-text field. Cancel leaves the
// existing token alone; Save writes the new one (empty string clears).
- (void)promptForGithubToken {
    NSString *current = [PPCatalogService shared].githubToken;
    UIAlertController *ac = [UIAlertController
        alertControllerWithTitle:@"GitHub Token"
                         message:@"Paste a personal access token to raise the catalog rate limit. Leave empty to clear."
                  preferredStyle:UIAlertControllerStyleAlert];
    [ac addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder       = @"ghp_...";
        tf.text              = current ?: @"";
        tf.secureTextEntry   = YES;
        tf.autocorrectionType = UITextAutocorrectionTypeNo;
        tf.autocapitalizationType = UITextAutocapitalizationTypeNone;
    }];
    [ac addAction:[UIAlertAction actionWithTitle:@"Cancel"
                                           style:UIAlertActionStyleCancel
                                         handler:nil]];
    __weak typeof(self) weakSelf = self;
    [ac addAction:[UIAlertAction actionWithTitle:@"Save"
                                           style:UIAlertActionStyleDefault
                                         handler:^(UIAlertAction *_) {
        NSString *raw = ac.textFields.firstObject.text ?: @"";
        NSString *trimmed = [raw stringByTrimmingCharactersInSet:
                              [NSCharacterSet whitespaceAndNewlineCharacterSet]];
        [PPCatalogService shared].githubToken = trimmed.length ? trimmed : nil;
        [weakSelf.tableView reloadSections:[NSIndexSet indexSetWithIndex:PPSettingsSectionCatalog]
                          withRowAnimation:UITableViewRowAnimationAutomatic];
    }]];
    [self presentViewController:ac animated:YES completion:nil];
}

#pragma mark - URL opening

- (void)openURL:(NSString *)urlString {
    NSURL *url = [NSURL URLWithString:urlString];
    if (!url) return;
    if ([[UIApplication sharedApplication] canOpenURL:url]) {
        [[UIApplication sharedApplication] openURL:url
                                           options:@{}
                                 completionHandler:nil];
    }
}

@end
