//
//  ViewController.m
//  XDOperationQueue
//
//  Created by su xinde on 15/11/21.
//  Copyright © 2015年 com.su. All rights reserved.
//

#import "ViewController.h"
#import "XDOperation.h"
#import "XDTestOperation.h"
#import "XDTestOperation2.h"

@interface ViewController ()

@end

@implementation ViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    [self test];
}


- (void)test
{
    XDOperationQueue *queue = [[XDOperationQueue alloc] init];
    XDTestOperation *operation = [[XDTestOperation alloc] init];
    XDTestOperation2 *operation2 = [[XDTestOperation2 alloc] init];
    [queue addOperation:operation];
    [queue addOperation:operation2];
}

@end
