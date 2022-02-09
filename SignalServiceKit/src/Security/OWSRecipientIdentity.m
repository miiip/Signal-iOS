//
//  Copyright (c) 2021 Open Whisper Systems. All rights reserved.
//

#import "OWSRecipientIdentity.h"
#import "OWSIdentityManager.h"
#import <SignalCoreKit/Cryptography.h>
#import <SignalServiceKit/SignalServiceKit-Swift.h>

NS_ASSUME_NONNULL_BEGIN

NSString *OWSVerificationStateToString(OWSVerificationState verificationState)
{
    switch (verificationState) {
        case OWSVerificationStateDefault:
            return @"OWSVerificationStateDefault";
        case OWSVerificationStateVerified:
            return @"OWSVerificationStateVerified";
        case OWSVerificationStateNoLongerVerified:
            return @"OWSVerificationStateNoLongerVerified";
    }
}

SSKProtoVerifiedState OWSVerificationStateToProtoState(OWSVerificationState verificationState)
{
    switch (verificationState) {
        case OWSVerificationStateDefault:
            return SSKProtoVerifiedStateDefault;
        case OWSVerificationStateVerified:
            return SSKProtoVerifiedStateVerified;
        case OWSVerificationStateNoLongerVerified:
            return SSKProtoVerifiedStateUnverified;
    }
}

SSKProtoVerified *_Nullable BuildVerifiedProtoWithAddress(SignalServiceAddress *address,
    NSData *identityKey,
    OWSVerificationState verificationState,
    NSUInteger paddingBytesLength)
{
    OWSCAssertDebug(identityKey.length == kIdentityKeyLength);
    OWSCAssertDebug(address.isValid);
    // we only sync user's marking as un/verified. Never sync the conflicted state, the sibling device
    // will figure that out on it's own.
    OWSCAssertDebug(verificationState != OWSVerificationStateNoLongerVerified);

    SSKProtoVerifiedBuilder *verifiedBuilder = [SSKProtoVerified builder];
    verifiedBuilder.destinationE164 = address.phoneNumber;
    verifiedBuilder.destinationUuid = address.uuidString;
    verifiedBuilder.identityKey = identityKey;
    verifiedBuilder.state = OWSVerificationStateToProtoState(verificationState);

    if (paddingBytesLength > 0) {
        // We add the same amount of padding in the VerificationStateSync message and it's corresponding NullMessage so
        // that the sync message is indistinguishable from an outgoing Sent transcript corresponding to the NullMessage.
        // We pad the NullMessage so as to obscure it's content. The sync message (like all sync messages) will be
        // *additionally* padded by the superclass while being sent. The end result is we send a NullMessage of a
        // non-distinct size, and a verification sync which is ~1-512 bytes larger then that.
        verifiedBuilder.nullMessage = [Cryptography generateRandomBytes:paddingBytesLength];
    }

    NSError *error;
    SSKProtoVerified *_Nullable verifiedProto = [verifiedBuilder buildAndReturnError:&error];
    if (error || !verifiedProto) {
        OWSCFailDebug(@"%@ could not build protobuf: %@", @"[BuildVerifiedProtoWithRecipientId]", error);
        return nil;
    }
    return verifiedProto;
}

NSUInteger const RecipientIdentitySchemaVersion = 1;

@interface OWSRecipientIdentity ()

@property (atomic) OWSVerificationState verificationState;
@property (nonatomic, readonly) NSUInteger recipientIdentitySchemaVersion;

@end

/**
 * Record for a recipients identity key and some meta data around it used to make trust decisions.
 *
 * NOTE: Instances of this class MUST only be retrieved/persisted via it's internal `dbConnection`,
 *       which makes some special accommodations to enforce consistency.
 */
@implementation OWSRecipientIdentity

#pragma mark - Table Contents

- (nullable instancetype)initWithCoder:(NSCoder *)coder
{
    self = [super initWithCoder:coder];

    if (self) {
        if (![coder decodeObjectForKey:@"verificationState"]) {
            _verificationState = OWSVerificationStateDefault;
        }

        if (_recipientIdentitySchemaVersion < 1) {
            _accountId = [coder decodeObjectForKey:@"recipientId"];
            OWSAssertDebug(_accountId);
        }

        _recipientIdentitySchemaVersion = RecipientIdentitySchemaVersion;
    }

    return self;
}

- (instancetype)initWithAccountId:(NSString *)accountId
                      identityKey:(NSData *)identityKey
                  isFirstKnownKey:(BOOL)isFirstKnownKey
                        createdAt:(NSDate *)createdAt
                verificationState:(OWSVerificationState)verificationState
{
    self = [super initWithUniqueId:accountId];
    if (!self) {
        return self;
    }

    _accountId = accountId;
    _identityKey = identityKey;
    _isFirstKnownKey = isFirstKnownKey;
    _createdAt = createdAt;
    _verificationState = verificationState;
    _recipientIdentitySchemaVersion = RecipientIdentitySchemaVersion;

    return self;
}

// --- CODE GENERATION MARKER

// This snippet is generated by /Scripts/sds_codegen/sds_generate.py. Do not manually edit it, instead run `sds_codegen.sh`.

// clang-format off

- (instancetype)initWithGrdbId:(int64_t)grdbId
                      uniqueId:(NSString *)uniqueId
                       accountId:(NSString *)accountId
                       createdAt:(NSDate *)createdAt
                     identityKey:(NSData *)identityKey
                 isFirstKnownKey:(BOOL)isFirstKnownKey
               verificationState:(OWSVerificationState)verificationState
{
    self = [super initWithGrdbId:grdbId
                        uniqueId:uniqueId];

    if (!self) {
        return self;
    }

    _accountId = accountId;
    _createdAt = createdAt;
    _identityKey = identityKey;
    _isFirstKnownKey = isFirstKnownKey;
    _verificationState = verificationState;

    return self;
}

// clang-format on

// --- CODE GENERATION MARKER

- (void)updateWithVerificationState:(OWSVerificationState)verificationState
                        transaction:(SDSAnyWriteTransaction *)transaction
{
    OWSAssertDebug(transaction);

    // Ensure changes are persisted without clobbering any work done on another thread or instance.
    [self anyUpdateWithTransaction:transaction
                             block:^(OWSRecipientIdentity *_Nonnull obj) {
                                 obj.verificationState = verificationState;
                             }];
}

#pragma mark - debug

+ (void)printAllIdentities
{
    OWSLogInfo(@"### All Recipient Identities ###");
    __block int count = 0;
    [self.databaseStorage readWithBlock:^(SDSAnyReadTransaction *transaction) {
        [OWSRecipientIdentity
            anyEnumerateWithTransaction:transaction
                                batched:YES
                                  block:^(OWSRecipientIdentity *recipientIdentity, BOOL *stop) {
                                      OWSLogInfo(@"Identity %d: %@", count, recipientIdentity.debugDescription);
                                  }];
    }];
}

@end

NS_ASSUME_NONNULL_END
