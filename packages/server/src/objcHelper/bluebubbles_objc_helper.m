#import <Foundation/Foundation.h>

BOOL isScalar(id object) {
    return [object isKindOfClass:[NSNumber class]] || [object isKindOfClass:[NSString class]];
}

BOOL isIterable(id object) {
    return [object isKindOfClass:[NSDictionary class]] || [object isKindOfClass:[NSArray class]];
}

NSDictionary* parseAttributedBody(id stringData) {
    // Decode the base64 string
    NSData *data = [[NSData alloc] initWithBase64EncodedString:stringData options:0];

    // Unarchive the data and decode it so we can read the values
    NSUnarchiver *unarchivedObject = [[NSUnarchiver alloc] initForReadingWithData:data];
    NSAttributedString *unarchivedString = [unarchivedObject decodeObject];
    
    // Iterate over each of the attributes and pull out the JSON serializable values
    NSMutableArray *runsArray = [NSMutableArray array];
    [unarchivedString enumerateAttributesInRange: NSMakeRange(0, unarchivedString.string.length)
                               options:NSAttributedStringEnumerationReverse usingBlock:
    ^(NSDictionary *attributes, NSRange range, BOOL *stop) {
        NSMutableDictionary *runAttributes = [[NSMutableDictionary alloc] init];
        for(id key in attributes) {
            NSObject *objValue = attributes[key];
            BOOL isValid = isScalar(objValue) || isIterable(objValue);

            // If it's valid and iterable, we need to check if the iterable is serializable.
            if (isValid) {
                // Make sure the dictionary is serializable
                if ([objValue isKindOfClass:[NSDictionary class]]) {
                    NSDictionary *dictValue = (NSDictionary *)objValue;
                    for(NSString *dictKey in dictValue) {
                        if (!isScalar(dictKey) || !isScalar([dictValue objectForKey:dictKey])) {
                            isValid = false;
                            break;
                        }
                    }
                } else if ([objValue isKindOfClass:[NSArray class]]) {
                    // Make sure the array is serializable
                    NSArray *arrayValue = (NSArray *)objValue;
                    for(NSObject *arrayObjValue in arrayValue) {
                        if (!isScalar(arrayObjValue)) {
                            isValid = false;
                            break;
                        }
                    }
                }
            }

            if (isValid) {
                runAttributes[key] = objValue;
            }
        }

        [runsArray addObject:@{
            @"range": @[@(range.location), @(range.length)],
            @"attributes": runAttributes
        }];
    }];

    NSDictionary *attributedBody = @{
        @"string" : unarchivedString.string,
        @"runs" : runsArray
    };
    
    return attributedBody;
}

NSArray* bulkParseAttributedBody(NSArray *attributedBodies) {
    NSMutableArray *parsedBodies = [NSMutableArray array];
    for (NSDictionary *data in attributedBodies) {
        NSDictionary *parsedBody = parseAttributedBody(data[@"payload"]);
        NSDictionary *returnData = @{
            @"id": data[@"id"],
            @"body": parsedBody
        };

        [parsedBodies addObject:returnData];
    }

    return parsedBodies;
}

void handleCommand(NSString *userInput) {
    NSError *error = nil;
    NSData *jsonData = [userInput dataUsingEncoding:NSUTF8StringEncoding];
    NSDictionary *json = [NSJSONSerialization JSONObjectWithData:jsonData options:0 error:&error];
    if (error) {
        NSLog(@"Parsing Error: %@", error);
        NSLog(@"User Input: %@", userInput);
        return;
    }

    if (![json objectForKey:@"type"]) {
        NSLog(@"Error: missing `type` parameter");
        return;
    }

    @try
    {
        NSObject *output = nil;
        if ([[json objectForKey:@"type"] isEqual:@"attributed-body"]) {
            output = parseAttributedBody((NSString *)json[@"data"]);
        } else if ([[json objectForKey:@"type"] isEqual:@"bulk-attributed-body"]) {
            output = bulkParseAttributedBody((NSArray *)json[@"data"]);
        } else {
            NSLog(@"Error: unknown `type` parameter: %@", json[@"type"]);
        }

        if (output) {
            NSDictionary *outputDict = @{
                @"type" : @"response",
                @"id" : [json objectForKey:@"id"] ?: [NSNull null],
                @"data" : output
            };

            NSData *dataOutput = [NSJSONSerialization dataWithJSONObject:outputDict options:0 error:&error];
            NSString *strOutput = [[NSString alloc]initWithData:dataOutput encoding:NSUTF8StringEncoding];
            NSLog(@"%@", strOutput);
        }
    }
    @catch(id anException) {
        NSLog(@"Handling Error: %@", anException);
    }
}

int main(int argc, char** argv)
{
    NSArray *arguments = [[NSProcessInfo processInfo] arguments];
    if (arguments.count <= 1) {
        NSLog(@"Usage: bluebubbles_objc_helper '<JSON Data>'");
        return 1;
    }
    
    NSString *userInput = arguments[1];
    handleCommand(userInput);
    return 0;
}