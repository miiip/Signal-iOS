//
//  Copyright (c) 2022 Open Whisper Systems. All rights reserved.
//

#import "OWSSyncManager.h"
#import "Environment.h"
#import "OWSContactsManager.h"
#import "OWSPreferences.h"
#import "OWSProfileManager.h"
#import <Contacts/Contacts.h>
#import <SignalCoreKit/Cryptography.h>
#import <SignalMessaging/SignalMessaging-Swift.h>
#import <SignalServiceKit/AppReadiness.h>
#import <SignalServiceKit/DataSource.h>
#import <SignalServiceKit/MIMETypeUtil.h>
#import <SignalServiceKit/MessageSender.h>
#import <SignalServiceKit/OWSError.h>
#import <SignalServiceKit/OWSReceiptManager.h>
#import <SignalServiceKit/OWSSyncConfigurationMessage.h>
#import <SignalServiceKit/OWSSyncContactsMessage.h>
#import <SignalServiceKit/OWSSyncFetchLatestMessage.h>
#import <SignalServiceKit/OWSSyncGroupsMessage.h>
#import <SignalServiceKit/OWSSyncKeysMessage.h>
#import <SignalServiceKit/OWSSyncRequestMessage.h>
#import <SignalServiceKit/SSKEnvironment.h>
#import <SignalServiceKit/SignalAccount.h>
#import <SignalServiceKit/SignalServiceKit-Swift.h>
#import <SignalServiceKit/TSAccountManager.h>

NS_ASSUME_NONNULL_BEGIN

NSString *const OWSSyncManagerConfigurationSyncDidCompleteNotification = @"OWSSyncManagerConfigurationSyncDidCompleteNotification";
NSString *const OWSSyncManagerKeysSyncDidCompleteNotification = @"OWSSyncManagerKeysSyncDidCompleteNotification";

NSString *const kSyncManagerLastContactSyncKey = @"kTSStorageManagerOWSSyncManagerLastMessageKey";

@interface OWSSyncManager ()

@property (nonatomic) BOOL isRequestInFlight;

@end

@interface OWSSyncManager (SwiftPrivate)
- (void)sendSyncRequestMessage:(SSKProtoSyncMessageRequestType)requestType
                   transaction:(SDSAnyWriteTransaction *)transaction;
@end

#pragma mark -

@implementation OWSSyncManager

+ (SDSKeyValueStore *)keyValueStore
{
    return [[SDSKeyValueStore alloc] initWithCollection:@"kTSStorageManagerOWSSyncManagerCollection"];
}

#pragma mark -

- (instancetype)initDefault {
    self = [super init];

    if (!self) {
        return self;
    }

    OWSSingletonAssert();

    AppReadinessRunNowOrWhenMainAppDidBecomeReadyAsync(^{
        [self addObservers];
        
        if ([self.tsAccountManager isRegisteredAndReady]) {
            OWSAssertDebug(self.contactsManagerImpl.isSetup);

            if (self.tsAccountManager.isPrimaryDevice) {
                if (CurrentAppContext().isNSE) {
                    return;
                }
                // Flush any pending changes.
                //
                // sendSyncContactsMessageIfNecessary will skipIfRedundant,
                // so this won't yield redundant traffic.
                [self sendSyncContactsMessageIfNecessary];
            } else {
                [self sendAllSyncRequestMessages].catch(^(NSError *error) {
                    OWSLogError(@"Error: %@.", error);
                });
            }
        }
    });

    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)addObservers {
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(signalAccountsDidChange:)
                                                 name:OWSContactsManagerSignalAccountsDidChangeNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(profileKeyDidChange:)
                                                 name:kNSNotificationNameLocalProfileKeyDidChange
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(registrationStateDidChange)
                                                 name:NSNotificationNameRegistrationStateDidChange
                                               object:nil];
}

#pragma mark - Notifications

- (void)signalAccountsDidChange:(id)notification {
    OWSAssertIsOnMainThread();

    [self sendSyncContactsMessageIfPossible];
}

- (void)profileKeyDidChange:(id)notification {
    OWSAssertIsOnMainThread();

    [self sendSyncContactsMessageIfPossible];
}

- (void)registrationStateDidChange
{
    OWSAssertIsOnMainThread();

    [self sendSyncContactsMessageIfPossible];
}

#pragma mark - Methods

- (void)sendSyncContactsMessageIfPossible {
    OWSAssertIsOnMainThread();

    if (!AppReadiness.isAppReady) {
        // Don't bother if app hasn't finished setup.
        return;
    }
    if (!self.contactsManagerImpl.isSetup) {
        // Don't bother if the contacts manager hasn't finished setup.
        return;
    }
    if (self.tsAccountManager.isRegisteredAndReady && self.tsAccountManager.isRegisteredPrimaryDevice) {
        [self sendSyncContactsMessageIfNecessary];
    }
}

- (void)sendConfigurationSyncMessage {
    AppReadinessRunNowOrWhenAppDidBecomeReadyAsync(^{
        if (!self.tsAccountManager.isRegisteredAndReady) {
            return;
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            [self sendConfigurationSyncMessage_AppReady];
        });
    });
}

- (void)sendConfigurationSyncMessage_AppReady {
    OWSLogInfo(@"");

    if (!self.tsAccountManager.isRegisteredAndReady) {
        return;
    }

    BOOL areReadReceiptsEnabled = SSKEnvironment.shared.receiptManager.areReadReceiptsEnabled;
    BOOL showUnidentifiedDeliveryIndicators = Environment.shared.preferences.shouldShowUnidentifiedDeliveryIndicators;
    BOOL showTypingIndicators = self.typingIndicatorsImpl.areTypingIndicatorsEnabled;

    DatabaseStorageAsyncWrite(self.databaseStorage, ^(SDSAnyWriteTransaction *transaction) {
        TSThread *_Nullable thread = [TSAccountManager getOrCreateLocalThreadWithTransaction:transaction];
        if (thread == nil) {
            OWSFailDebug(@"Missing thread.");
            return;
        }

        BOOL sendLinkPreviews = [SSKPreferences areLinkPreviewsEnabledWithTransaction:transaction];

        OWSSyncConfigurationMessage *syncConfigurationMessage =
            [[OWSSyncConfigurationMessage alloc] initWithThread:thread
                                            readReceiptsEnabled:areReadReceiptsEnabled
                             showUnidentifiedDeliveryIndicators:showUnidentifiedDeliveryIndicators
                                           showTypingIndicators:showTypingIndicators
                                               sendLinkPreviews:sendLinkPreviews];

        [self.messageSenderJobQueue addMessage:syncConfigurationMessage.asPreparer transaction:transaction];
    });
}

- (void)processIncomingConfigurationSyncMessage:(SSKProtoSyncMessageConfiguration *)syncMessage transaction:(SDSAnyWriteTransaction *)transaction
{
    if (syncMessage.hasReadReceipts) {
        [SSKEnvironment.shared.receiptManager setAreReadReceiptsEnabled:syncMessage.readReceipts
                                                            transaction:transaction];
    }
    if (syncMessage.hasUnidentifiedDeliveryIndicators) {
        BOOL updatedValue = syncMessage.unidentifiedDeliveryIndicators;
        [Environment.shared.preferences setShouldShowUnidentifiedDeliveryIndicators:updatedValue
                                                                        transaction:transaction];
    }
    if (syncMessage.hasTypingIndicators) {
        [self.typingIndicatorsImpl setTypingIndicatorsEnabledWithValue:syncMessage.typingIndicators
                                                           transaction:transaction];
    }
    if (syncMessage.hasLinkPreviews) {
        [SSKPreferences setAreLinkPreviewsEnabled:syncMessage.linkPreviews
                                  sendSyncMessage:NO
                                      transaction:transaction];
    }

    [transaction addAsyncCompletionOffMain:^{
        [[NSNotificationCenter defaultCenter] postNotificationNameAsync:OWSSyncManagerConfigurationSyncDidCompleteNotification
                                                                 object:nil];
    }];
}

- (void)processIncomingGroupsSyncMessage:(SSKProtoSyncMessageGroups *)syncMessage transaction:(SDSAnyWriteTransaction *)transaction
{
    OWSLogInfo(@"");

    TSAttachmentPointer *attachmentPointer = [TSAttachmentPointer attachmentPointerFromProto:syncMessage.blob albumMessage:nil];
    [attachmentPointer anyInsertWithTransaction:transaction];
    [self.incomingGroupSyncJobQueue addWithAttachmentId:attachmentPointer.uniqueId transaction:transaction];
}

- (void)processIncomingContactsSyncMessage:(SSKProtoSyncMessageContacts *)syncMessage transaction:(SDSAnyWriteTransaction *)transaction
{
    TSAttachmentPointer *attachmentPointer = [TSAttachmentPointer attachmentPointerFromProto:syncMessage.blob
                                                                                albumMessage:nil];
    [attachmentPointer anyInsertWithTransaction:transaction];
    [self.incomingContactSyncJobQueue addWithAttachmentId:attachmentPointer.uniqueId transaction:transaction];
}

#pragma mark - Groups Sync

- (void)syncGroupsWithTransaction:(SDSAnyWriteTransaction *)transaction completion:(void (^)(void))completion
{
    if (SSKDebugFlags.dontSendContactOrGroupSyncMessages.value) {
        OWSLogInfo(@"Skipping group sync message.");
        return;
    }

    TSThread *_Nullable thread = [TSAccountManager getOrCreateLocalThreadWithTransaction:transaction];
    if (thread == nil) {
        OWSFailDebug(@"Missing thread.");
        return;
    }
    OWSSyncGroupsMessage *syncGroupsMessage = [[OWSSyncGroupsMessage alloc] initWithThread:thread];
    NSURL *_Nullable syncFileUrl = [syncGroupsMessage buildPlainTextAttachmentFileWithTransaction:transaction];
    if (!syncFileUrl) {
        OWSFailDebug(@"Failed to serialize groups sync message.");
        return;
    }
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSError *error;
        id<DataSource> dataSource = [DataSourcePath dataSourceWithURL:syncFileUrl
                                           shouldDeleteOnDeallocation:YES
                                                                error:&error];
        OWSAssertDebug(error == nil);
        [self.messageSenderJobQueue addMediaMessage:syncGroupsMessage
                                         dataSource:dataSource
                                        contentType:OWSMimeTypeApplicationOctetStream
                                     sourceFilename:nil
                                            caption:nil
                                     albumMessageId:nil
                              isTemporaryAttachment:YES];
        completion();
    });
}

#pragma mark - Local Sync

- (AnyPromise *)syncLocalContact
{
    // OWSContactsOutputStream requires all signalAccount to have a contact.
    Contact *contact = [[Contact alloc] initWithSystemContact:[CNContact new]];
    SignalAccount *signalAccount =
        [[SignalAccount alloc] initWithSignalServiceAddress:self.tsAccountManager.localAddress
                                                    contact:contact
                                   multipleAccountLabelText:nil];

    return [self syncContactsForSignalAccounts:@[ signalAccount ] skipIfRedundant:NO debounce:NO isDurableSend:YES];
}

#pragma mark - Contacts Sync

- (AnyPromise *)syncAllContacts
{
    NSArray<SignalAccount *> *allSignalAccounts = [self.contactsManagerImpl unsortedSignalAccountsWithSneakyTransaction];
    return [self syncContactsForSignalAccounts:allSignalAccounts
                               skipIfRedundant:NO
                                      debounce:NO
                                 isDurableSend:NO];
}

- (AnyPromise *)syncContactsForSignalAccounts:(NSArray<SignalAccount *> *)signalAccounts
{
    return [self syncContactsForSignalAccounts:signalAccounts skipIfRedundant:NO debounce:NO isDurableSend:NO];
}

- (void)sendSyncContactsMessageIfNecessary
{
    OWSAssertDebug(self.tsAccountManager.isRegisteredPrimaryDevice);

    NSArray<SignalAccount *> *allSignalAccounts = [self.contactsManagerImpl unsortedSignalAccountsWithSneakyTransaction];
    [self syncContactsForSignalAccounts:allSignalAccounts
                        skipIfRedundant:YES
                               debounce:YES
                          isDurableSend:NO];
}

- (dispatch_queue_t)serialQueue
{
    static dispatch_queue_t _serialQueue;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        _serialQueue = dispatch_queue_create("org.whispersystems.contacts.syncing", DISPATCH_QUEUE_SERIAL);
    });

    return _serialQueue;
}

// skipIfRedundant: Don't bother sending sync messages with the same data as the
//                  last successfully sent contact sync message.
// debounce: Only have one sync message in flight at a time.
- (AnyPromise *)syncContactsForSignalAccounts:(NSArray<SignalAccount *> *)signalAccounts
                              skipIfRedundant:(BOOL)skipIfRedundant
                                     debounce:(BOOL)debounce
                                isDurableSend:(BOOL)isDurableSend
{
    if (SSKDebugFlags.dontSendContactOrGroupSyncMessages.value) {
        OWSLogInfo(@"Skipping contact sync message.");
        return [AnyPromise promiseWithValue:@(YES)];
    }
    if (!self.contactsManagerImpl.isSetup) {
        return [AnyPromise promiseWithError:OWSErrorMakeAssertionError(@"Contacts manager not yet ready.")];
    }
    if (!self.tsAccountManager.isRegisteredPrimaryDevice) {
        return [AnyPromise promiseWithError:OWSErrorMakeAssertionError(@"should not sync from secondary device")];
    }
    if (!self.tsAccountManager.isRegisteredAndReady) {
        return [AnyPromise promiseWithError:OWSErrorMakeAssertionError(@"Not yet registered and ready.")];
    }
    // TODO: Rewrite this in Swift and replace these flags with a "mode" enum.
    if (isDurableSend) {
        OWSAssertDebug(!skipIfRedundant);
        OWSAssertDebug(!debounce);
    } else if (skipIfRedundant) {
        OWSAssertDebug(!isDurableSend);
    }

    AnyPromise *promise = AnyPromise.withFuture(^(AnyFuture *future) {
        AppReadinessRunNowOrWhenAppDidBecomeReadyAsync(^{
            dispatch_async(self.serialQueue, ^{
                if (debounce && self.isRequestInFlight) {
                    // De-bounce.  It's okay if we ignore some new changes;
                    // `sendSyncContactsMessageIfPossible` is called fairly
                    // often so we'll sync soon.
                    return [future resolveWithValue:@(1)];
                }

                TSThread *_Nullable thread = [TSAccountManager getOrCreateLocalThreadWithSneakyTransaction];
                if (thread == nil) {
                    OWSFailDebug(@"Missing thread.");
                    NSError *error = [OWSError withError:OWSErrorCodeContactSyncFailed
                                             description:@"Could not sync contacts."
                                             isRetryable:NO];
                    return [future rejectWithError:error];
                }

                OWSSyncContactsMessage *syncContactsMessage =
                    [[OWSSyncContactsMessage alloc] initWithThread:thread signalAccounts:signalAccounts];
                __block NSURL *_Nullable syncFileUrl;
                __block NSData *_Nullable lastMessageHash;
                [self.databaseStorage readWithBlock:^(SDSAnyReadTransaction *transaction) {
                    syncFileUrl = [syncContactsMessage buildPlainTextAttachmentFileWithTransaction:transaction];
                    lastMessageHash = [OWSSyncManager.keyValueStore getData:kSyncManagerLastContactSyncKey
                                                                transaction:transaction];
                } file:__FILE__ function:__FUNCTION__ line:__LINE__];

                if (!syncFileUrl) {
                    OWSFailDebug(@"Failed to serialize contacts sync message.");
                    NSError *error = [OWSError withError:OWSErrorCodeContactSyncFailed
                                             description:@"Could not sync contacts."
                                             isRetryable:NO];
                    return [future rejectWithError:error];
                }

                NSError *_Nullable hashError;
                NSData *_Nullable messageHash = [Cryptography computeSHA256DigestOfFileAt:syncFileUrl error:&hashError];
                if (hashError != nil || messageHash == nil) {
                    OWSFailDebug(@"Error: %@.", hashError);
                    NSError *error = [OWSError withError:OWSErrorCodeContactSyncFailed
                                             description:@"Could not sync contacts."
                                             isRetryable:NO];
                    return [future rejectWithError:error];
                }

                if (skipIfRedundant && [NSObject isNullableObject:messageHash equalTo:lastMessageHash]) {
                    // Ignore redundant contacts sync message.
                    return [future resolveWithValue:@(1)];
                }

                if (debounce) {
                    self.isRequestInFlight = YES;
                }

                // DURABLE CLEANUP - we could replace the custom durability logic in this class
                // with a durable JobQueue.
                NSError *writeError;
                id<DataSource> dataSource = [DataSourcePath dataSourceWithURL:syncFileUrl
                                                   shouldDeleteOnDeallocation:YES
                                                                        error:&writeError];
                if (writeError != nil) {
                    if (debounce) {
                        self.isRequestInFlight = NO;
                    }
                    [future rejectWithError:writeError];
                    return;
                }

                if (isDurableSend) {
                    [self.messageSenderJobQueue addMediaMessage:syncContactsMessage
                                                     dataSource:dataSource
                                                    contentType:OWSMimeTypeApplicationOctetStream
                                                 sourceFilename:nil
                                                        caption:nil
                                                 albumMessageId:nil
                                          isTemporaryAttachment:YES];
                    if (debounce) {
                        self.isRequestInFlight = NO;
                    }
                    return [future resolveWithValue:@(1)];
                } else {
                    [self.messageSender sendTemporaryAttachment:dataSource
                        contentType:OWSMimeTypeApplicationOctetStream
                        inMessage:syncContactsMessage
                        success:^{
                            OWSLogInfo(@"Successfully sent contacts sync message.");

                            if (messageHash != nil) {
                                DatabaseStorageWrite(self.databaseStorage, ^(SDSAnyWriteTransaction *transaction) {
                                    [OWSSyncManager.keyValueStore setData:messageHash
                                                                      key:kSyncManagerLastContactSyncKey
                                                              transaction:transaction];
                                });
                            }

                            dispatch_async(self.serialQueue, ^{
                                if (debounce) {
                                    self.isRequestInFlight = NO;
                                }

                                [future resolveWithValue:@(1)];
                            });
                        }
                        failure:^(NSError *error) {
                            OWSLogError(@"Failed to send contacts sync message with error: %@", error);

                            dispatch_async(self.serialQueue, ^{
                                if (debounce) {
                                    self.isRequestInFlight = NO;
                                }

                                [future rejectWithError:error];
                            });
                        }];
                }
            });
        });
    });
    return promise;
}

#pragma mark - Fetch Latest

- (void)sendFetchLatestProfileSyncMessage
{
    [self sendFetchLatestSyncMessageWithType:OWSSyncFetchType_LocalProfile];
}

- (void)sendFetchLatestStorageManifestSyncMessage
{
    [self sendFetchLatestSyncMessageWithType:OWSSyncFetchType_StorageManifest];
}

- (void)sendFetchLatestSubscriptionStatusSyncMessage
{
    [self sendFetchLatestSyncMessageWithType:OWSSyncFetchType_SubscriptionStatus];
}

- (void)sendFetchLatestSyncMessageWithType:(OWSSyncFetchType)fetchType
{
    OWSLogInfo(@"");

    if (!self.tsAccountManager.isRegisteredAndReady) {
        OWSFailDebug(@"Unexpectedly tried to send sync message before registration.");
        return;
    }

    DatabaseStorageAsyncWrite(self.databaseStorage, ^(SDSAnyWriteTransaction *transaction) {
        TSThread *_Nullable thread = [TSAccountManager getOrCreateLocalThreadWithTransaction:transaction];
        if (thread == nil) {
            OWSFailDebug(@"Missing thread.");
            return;
        }

        OWSSyncFetchLatestMessage *syncFetchLatestMessage =
            [[OWSSyncFetchLatestMessage alloc] initWithThread:thread fetchType:fetchType];

        [self.messageSenderJobQueue addMessage:syncFetchLatestMessage.asPreparer transaction:transaction];
    });
}

- (void)sendPniIdentitySyncRequestMessage
{
    DatabaseStorageAsyncWrite(self.databaseStorage, ^(SDSAnyWriteTransaction *transaction) {
        [self sendSyncRequestMessage:SSKProtoSyncMessageRequestTypePniIdentity transaction:transaction];
    });
}

- (void)processIncomingFetchLatestSyncMessage:(SSKProtoSyncMessageFetchLatest *)syncMessage
                                  transaction:(SDSAnyWriteTransaction *)transaction
{
    switch (syncMessage.unwrappedType) {
        case SSKProtoSyncMessageFetchLatestTypeUnknown:
            OWSFailDebug(@"Unknown fetch latest type");
            break;
        case SSKProtoSyncMessageFetchLatestTypeLocalProfile: {
            dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0),
                ^{ [self.profileManager fetchLocalUsersProfile]; });
            break;
        }
        case SSKProtoSyncMessageFetchLatestTypeStorageManifest:
            [SSKEnvironment.shared.storageServiceManager restoreOrCreateManifestIfNecessary];
            break;
        case SSKProtoSyncMessageFetchLatestTypeSubscriptionStatus:

            [SubscriptionManager performDeviceSubscriptionExpiryUpdate];
            break;
    }
}

@end

NS_ASSUME_NONNULL_END
