// SPDX-License-Identifier: GPL-3.0-or-later
#import <AppKit/AppKit.h>
int APDecoderTestsMain(int argc, char **argv);
int main(int argc, char **argv) {
    @autoreleasepool {
        [NSApplication sharedApplication];
        return APDecoderTestsMain(argc, argv);
    }
}
