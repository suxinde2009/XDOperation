//
//  XDTestOperation.m
//  XDOperationQueue
//
//  Created by su xinde on 15/11/21.
//  Copyright © 2015年 com.su. All rights reserved.
//

#import "XDTestOperation.h"

@implementation XDTestOperation

- (void)main
{
    for (int i = 0; i < 10000; i++) {
        NSLog(@"%@: %@", [self class], [NSDate date]);
        if (i == 9999) {
            i = 0;
        }
    }

}

@end
