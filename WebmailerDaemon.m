/*******************************************************************************
 Copyright (c) 2006-2011 Jordy Rose
 
 Permission is hereby granted, free of charge, to any person obtaining a copy
 of this software and associated documentation files (the "Software"), to deal
 in the Software without restriction, including without limitation the rights
 to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
 copies of the Software, and to permit persons to whom the Software is
 furnished to do so, subject to the following conditions:
 
 The above copyright notice and this permission notice shall be included in
 all copies or substantial portions of the Software.
 
 THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
 SOFTWARE.
 
 Except as contained in this notice, the name(s) of the above copyright holders
 shall not be used in advertising or otherwise to promote the sale, use or other
 dealings in this Software without prior authorization.
*******************************************************************************/

#import "WebmailerDaemon.h"
#import "WebmailerShared.h"
#import "ImageForStateTransformer.h"
#import "NSString+PrototypeExpansion.h"

#import "ScriptingBridgeApps.h"

// to stop warnings on pre-10.6 builds
@interface NSEvent (ComBelkadanWebmailer_NoWarn)
+ (NSUInteger)modifierFlags;
@end


@interface WebmailerDaemon (ComBelkadanWebmailer_Private)
- (void)extractEventData:(NSAppleEventDescriptor *)event;

- (void)launchShellScript:(NSString *)script;
- (void)launchTerminal:(NSString *)script;

- (NSURL *)chooseAppForOpeningURL:(NSURL *)url;
@end


/*!
 * Returns YES if the shift key is currently held, NO if not.
 */
BOOL isShiftKeyDown ()
{
	BOOL result;

#if defined(MAC_OS_X_VERSION_10_6) && MAC_OS_X_VERSION_10_6 <= MAC_OS_X_VERSION_MAX_ALLOWED
# if MAC_OS_X_VERSION_10_6 <= MAC_OS_X_VERSION_MIN_REQUIRED
	result = (([NSEvent modifierFlags] & NSShiftKeyMask) != 0);

# else /* MAC_OS_X_VERSION_MIN_REQUIRED < MAC_OS_X_VERSION_10_6 */
	if ([NSEvent respondsToSelector:@selector(modifierFlags)])
	{
		result = (([NSEvent modifierFlags] & NSShiftKeyMask) != 0);
	}
	else
	{
		CGEventRef tempEvent = CGEventCreate(NULL /*default event source*/);
		result = ((CGEventGetFlags(tempEvent) & kCGEventFlagMaskShift) != 0);
		CFRelease(tempEvent);
	}

# endif

#else /* MAC_OS_X_VERSION_MAX_ALLOWED < MAC_OS_X_VERSION_10_6 */
	CGEventRef tempEvent = CGEventCreate(NULL /*default event source*/);
	result = ((CGEventGetFlags(tempEvent) & kCGEventFlagMaskShift) != 0);
	CFRelease(tempEvent);

#endif

	return result;
}

/*!
 * Returns the image used to represent the currently selected destination.
 */
NSImage *GetActiveDestinationImage ()
{
	NSImage *image;

	// If available, use the active state image that comes with Mac OS X.
#if defined(MAC_OS_X_VERSION_10_6) && MAC_OS_X_VERSION_10_6 <= MAC_OS_X_VERSION_MAX_ALLOWED
	image = [NSImage imageNamed:@"NSStatusAvailable"]; // don't use the constant to avoid crash on Tiger
	if (!image)
#endif
	{
		// Otherwise, use our own bundled image.
		image = [NSImage imageNamed:@"active"];
	}

	return image;
}

/*!
 * Finds the URL of a running application with a given process serial number.
 * If the URL cannot be found, for whatever reason (perhaps the application has
 * quit), returns nil.
 */
NSURL *GetURLForPSN (const ProcessSerialNumber *psn) {
	if (psn->highLongOfPSN == 0 && psn->lowLongOfPSN == 0)
		return nil;
	
	FSRef bundleLocation;
	OSStatus status = GetProcessBundleLocation(psn, &bundleLocation);
	if (status != noErr)
		return nil;
	
	NSURL *appURL = (NSURL *)CFURLCreateFromFSRef(NULL, &bundleLocation);
	return [appURL autorelease];
}

/*!
 * Returns YES if the application at the first URL can open the second URL.
 * Basically a wrapper around LSCanURLAcceptURL().
 */
BOOL CanOpenURLWithApplication (NSURL *url, NSURL *appURL) {
	Boolean canHandle;
	OSStatus status = LSCanURLAcceptURL((CFURLRef)url, (CFURLRef)appURL, kLSRolesViewer, kLSAcceptDefault, &canHandle);
	
	if (status != noErr)
		return NO;
	
	return canHandle ? YES : NO; // conversion from Boolean to BOOL...doesn't hurt!
}

/*!
 * Open a URL using the given application. 
 * Essentially a wrapper around LSOpenFromURLSpec().
 */
void OpenURLWithApplication(NSURL *url, NSURL *appURL)
{
	LSLaunchURLSpec launchSpec = {
		.appURL = (CFURLRef)appURL,
		.itemURLs = (CFArrayRef)[NSArray arrayWithObject:url],
		.launchFlags = kLSLaunchDefaults
	};
	(void)LSOpenFromURLSpec(&launchSpec, NULL);
}

/*!
 * Returns the URL of the application the Finder would use to open this URL.
 * If there is no application registered for the URL, returns nil.
 * Basically a wrapper around LSGetApplicationForURL().
 */
NSURL *GetDefaultAppURLForURL(NSURL *url) {
	// TODO: in 10.6, replace this function with -[NSWorkspace URLForApplicationToOpenURL:]
	NSURL *appURL = nil;
	OSStatus status = LSGetApplicationForURL((CFURLRef)url, kLSRolesAll, NULL, (CFURLRef*)&appURL);

	if (status != noErr)
		return nil;
	
	return [appURL autorelease];
}


#pragma mark -

/*!
 * The central controller for the faceless Webmailer application, tucked away inside
 * the preference pane bundle. WebmailerDaemon's entire purpose is to launch, respond
 * to a single Apple Event (GetURL, with a mailto: URL), and quit. If the application
 * is launched before the preference pane has ever been opened (an unlikely event),
 * the preference pane is opened so that the user can configure the settings.
 * <br/>
 * However, should the shift key be held down when Webmailer launches, the user
 * gets to choose which destination URL to use, via a small window that pops up
 * in the center of the screen. After this choice, the evaluation of the URL
 * continues as before.
 * <br/>
 * Why does Webmailer quit, instead of just remaining open? Well, if it didn't,
 * the user might have some trouble if they wanted to uninstall it (hopefully that
 * wouldn't happen anyway). They'd have to log out and log back in first, because
 * there's no way to actually quit it (well, besides Activity Monitor or kill).
 * As far as I can tell there's no significant time lag. (This does make the name
 * "daemon" less applicable, but the behavior of a faceless app still applies).
 */
@implementation WebmailerDaemon
- (void)awakeFromNib
{
	// Make sure the user has configured Webmailer before. 
	defaults = [[DefaultsDomain domainForName:WebmailerAppDomain] retain];
	if ([defaults count] == 0)
	{
		[self openPreferencePane:nil];
	}

	// Register for GetURL events.
	NSAppleEventManager *aevtManager = [NSAppleEventManager sharedAppleEventManager];
	[aevtManager setEventHandler:self andSelector:@selector(handleGetURLEvent:withReplyEvent:) forEventClass:kInternetEventClass andEventID:kAEGetURL];
	
	// Quit if no incoming event after 30s.
	[NSTimer scheduledTimerWithTimeInterval:30 target:NSApp selector:@selector(terminate:) userInfo:nil repeats:NO];
}

- (void)dealloc
{
	[defaults release];
	[mailtoURL release];
	[configurations release];
	[super dealloc];
}

/*!
 * Set up the configuration chooser, then display it and bring the Webmailer app to the front.
 * The user can then choose which configuration to use for the URL that was clicked.
 */
- (void)showConfigurationChooser {
	// Set up sort descriptors for destination URLs.
	NSSortDescriptor *sortByName = [[NSSortDescriptor alloc] initWithKey:WebmailerDestinationNameKey ascending:YES selector:@selector(localizedCaseInsensitiveCompare:)];
	NSSortDescriptor *sortByDestination = [[NSSortDescriptor alloc] initWithKey:WebmailerDestinationURLKey ascending:YES];
	NSArray *sortDescriptors = [[NSArray alloc] initWithObjects:sortByName, sortByDestination, nil];
	[sortByName release];
	[sortByDestination release];

	// Sort the configurations.
	NSArray *sortedConfigurations = [[defaults objectForKey:WebmailerConfigurationsKey] sortedArrayUsingDescriptors:sortDescriptors];
	[sortDescriptors release];
	
	// Update the displayed configurations.
	[self willChangeValueForKey:@"configurations"];
	configurations = [sortedConfigurations copy];
	[self didChangeValueForKey:@"configurations"];

		
	// Create a new value transformer that shows an active icon for true values.
	ImageForStateTransformer *transformer = [[ImageForStateTransformer alloc] initWithTrueImage:GetActiveDestinationImage() falseImage:nil];
	[NSValueTransformer setValueTransformer:transformer forName:@"ImageForState"];
	[transformer release];
	
	
	// Select the active destination.
	NSUInteger count = [configurations count];
	NSUInteger i;
	
	for (i = 0; i < count; i += 1)
	{
		if ([[[configurations objectAtIndex:i] objectForKey:WebmailerDestinationIsActiveKey] boolValue])
		{
			[configurationController setSelectionIndex:i];
			[configurationTable scrollRowToVisible:i];
			break;
		}
	}
	
	
	// Set the table to fire an action on double-click.
	[configurationTable setDoubleAction:@selector(confirmConfiguration:)];
	[configurationTable setTarget:self];


	// Bring up the configuration window.
	[NSApp activateIgnoringOtherApps:YES]; // needed because we're an NSUIElement
	[configurationWindow makeKeyAndOrderFront:self];
}

/*!
 * Opens the Webmailer preference pane, using a file open if Webmailer is in the pane's Resources,
 * and either Scripting Bridge or NSAppleScript if it is outside.
 */
- (IBAction)openPreferencePane:(id)sender
{
	NSString *prefPanePath = [[[[[NSBundle mainBundle] bundlePath] stringByDeletingLastPathComponent] stringByDeletingLastPathComponent] stringByDeletingLastPathComponent];
	if ([prefPanePath hasSuffix:@".prefPane"])
	{
		[[NSWorkspace sharedWorkspace] openFile:prefPanePath];
	}
#if defined(MAC_OS_X_VERSION_10_5) && MAC_OS_X_VERSION_MAX_ALLOWED >= MAC_OS_X_VERSION_10_5
	else if (NSClassFromString(@"SBApplication"))
	{
		SystemPreferencesApplication *sysPrefs = [SBApplication applicationWithBundleIdentifier:@"com.apple.systempreferences"];
		[sysPrefs setDelegate:self];
		[sysPrefs activate];
		[sysPrefs setCurrentPane:[[sysPrefs panes] objectWithID:@"com.belkadan.Webmailer"]];
	}
#endif
	else
	{
		// Yes, having a compiled script would make this more efficient.
		// However, then we'd have to read it in from disk, which would be slower
		// and probably just make the bundle bigger overall.
		// This section is only here for 10.4 compatibility anyway.
		NSAppleScript *prefPaneOpenScript = [[NSAppleScript alloc] initWithSource:@"tell application \"System Preferences\"\nset current pane to pane \"com.belkadan.Webmailer\"\nactivate\nend tell"];
		[prefPaneOpenScript executeAndReturnError:NULL];
		[prefPaneOpenScript release];
	}
	[NSApp terminate:self];
}

/*!
 * Confirms the user's choice of destination configuration, and launches the
 * destination URL.
 */
- (IBAction)confirmConfiguration:(id)sender
{
	[configurationWindow orderOut:sender];
	[self launchDestination:[[configurationController selection] valueForKey:WebmailerDestinationURLKey]];
}

#pragma mark -

/*!
 * Respond to a GetURL Apple Event. The URL (the direct object of the event) is
 * stored for now in an instance variable; it must have the mailto: scheme.
 * If the shift key is held down, the configuration-choosing window is opened;
 * otherwise the program progresses directly to launching the destination URL.
 * The reply event is unused.
 */
- (void)handleGetURLEvent:(NSAppleEventDescriptor *)event withReplyEvent:(NSAppleEventDescriptor *)replyEvent
{		
	[self extractEventData:event];

	BOOL shouldShowConfigurations = isShiftKeyDown();
	if (shouldShowConfigurations)
	{
		[self showConfigurationChooser];
	}
	else
	{
		[self launchDestination:[defaults objectForKey:WebmailerCurrentDestinationKey]];
	}
}

/*!
 * Extract any useful information from a GetURL AppleEvent, including the URL
 * that was clicked.
 */
- (void)extractEventData:(NSAppleEventDescriptor *)event {
	// Save mailto URL.
	[mailtoURL release];
	mailtoURL = [[[event paramDescriptorForKeyword:keyDirectObject] stringValue] copy];

	// Save the PSN of the application that sent this message.
	// TODO: Someday, maybe Apple will switch to something other than PSNs for this.
	NSData *data = [[[event attributeDescriptorForKeyword:keyAddressAttr] coerceToDescriptorType: typeProcessSerialNumber] data];
	NSAssert([data length] <= sizeof(sourcePSN), @"PSN key is too big!");
	[data getBytes:&sourcePSN];
}

#pragma mark -

/*!
 * This method uses the given destination URL and rewrites it, using the rules
 * described in the Webmailer Read Me file. Then, it takes the appropriate action,
 * based on whether the result is a URL or a shell script. Non-interactive shell
 * scripts are run using NSTask if possible, defaulting back to NSAppleScript if 
 * not. Interactive shell scripts are launched in Terminal using Scripting Bridge
 * (if available) or NSAppleScript (if not).
 */
- (void)launchDestination:(NSString *)destinationPrototype
{
	if ([destinationPrototype characterAtIndex:0] == '#')
	{
		// It's a background shell script!
		destinationPrototype = [destinationPrototype substringFromIndex:1];
		NSString *script = [destinationPrototype replaceWebmailerPlaceholdersUsingMailtoURLString:mailtoURL alwaysEscapeQuotes:YES];
		[self launchShellScript:script];
	}
	else
	{
		NSString *destination = [destinationPrototype replaceWebmailerPlaceholdersUsingMailtoURLString:mailtoURL alwaysEscapeQuotes:NO];
		NSURL *destinationURL = [[NSURL alloc] initWithString:destination];
		
		if (destinationURL)
		{
			// It's a valid URL
			NSURL *appURL = [self chooseAppForOpeningURL:destinationURL];
			if (appURL)
			{
				OpenURLWithApplication(destinationURL, appURL);
			}
			else
			{
				// Fall back to default URL handler.
				[[NSWorkspace sharedWorkspace] openURL:destinationURL];
			}
			[destinationURL release];
		}
		else
		{
			// It's not a valid URL; must be an "open Terminal" shell script.
			NSString *script = [destinationPrototype replaceWebmailerPlaceholdersUsingMailtoURLString:mailtoURL alwaysEscapeQuotes:YES];
			[self launchTerminal:script];
		}
	}

	[NSApp terminate:self]; // Don't want to just stick around, right?
}


/*!
 * Returns the URL of the application Webmailer should use to open the given
 * destination URL. If smart app choosing is disabled in the preferences, or
 * if no good applications can be found, returns nil.
 *
 * 1. If the app that sent us the mailto URL can handle the destination, pick that.
 * 2. If the default app for the destination URL is open, pick that.
 * 3. If any app that can handle the destination URL is open, pick one of them.
 * 4. Otherwise, give up and return nil.
 */
- (NSURL *)chooseAppForOpeningURL:(NSURL *)url
{
	if ([[defaults objectForKey:WebmailerDisableAppChoosingKey] boolValue])
	{
		return nil;
	}
	
	// If the app that sent us the mailto URL can handle the destination, pick that.
	NSURL *source = GetURLForPSN(&sourcePSN);
	if (CanOpenURLWithApplication(url, source)) return source;
	
	// Otherwise, start scanning the list of open applications.
	NSURL *defaultAppURL = GetDefaultAppURLForURL(url);
	
	NSWorkspace *workspace = [NSWorkspace sharedWorkspace];
	NSURL *currentChoice = nil;
	
#if defined(MAC_OS_X_VERSION_10_6) && MAC_OS_X_VERSION_MAX_ALLOWED >= MAC_OS_X_VERSION_10_6
	if ([workspace respondsToSelector:@selector(runningApplications)])
	{
		NSURL *nextAppURL;
		for (NSRunningApplication *nextApp in [workspace runningApplications])
		{
			nextAppURL = nextApp.bundleURL;
			if ([nextAppURL isEqual:defaultAppURL])
			{
				return defaultAppURL;
			}
			else if (!currentChoice && CanOpenURLWithApplication(url, nextAppURL))
			{
				currentChoice = nextAppURL;
			}
		}
	}
	else
#endif
	{
		NSEnumerator *appEnum = [[workspace launchedApplications] objectEnumerator];
		NSDictionary *nextAppInfo;
		NSURL *nextAppURL;
		while (nextAppInfo = [appEnum nextObject])
		{
			nextAppURL = [NSURL fileURLWithPath:[nextAppInfo objectForKey:@"NSApplicationPath"]];
			if ([nextAppURL isEqual:defaultAppURL])
			{
				return defaultAppURL;
			}
			else if (!currentChoice && CanOpenURLWithApplication(url, nextAppURL))
			{
				currentChoice = nextAppURL;
			}
		}
	}
	
	return currentChoice;
}

/*!
 * Run the given script in the user's preferred shell. The output goes to stdout.
 */
- (void)launchShellScript:(NSString *)script
{
	// Find out the user's preferred shell. Default to /bin/sh.
	NSString *userShell = [[[NSProcessInfo processInfo] environment] objectForKey:@"SHELL"];
	if ([userShell length] == 0) userShell = @"/bin/sh";
	
	// Launch the shell.
	NSTask *task = [[NSTask alloc] init];
	NSPipe *pipe = [NSPipe pipe];
	[task setStandardInput:[pipe fileHandleForReading]];
	[task setLaunchPath:userShell];
	[task launch];
	
	// Write the script.
	NSFileHandle *input = [pipe fileHandleForWriting];
	[input writeData:[script dataUsingEncoding:NSUTF8StringEncoding]];
	[input closeFile];
	[task waitUntilExit];
	[task release];
}

/*!
 * Run the given script in the Terminal, so it can be used interactively.
 *
 * TODO: use handler for com.apple.Terminal.shell-script ?
 */
- (void)launchTerminal:(NSString *)script
{
#if defined(MAC_OS_X_VERSION_10_5) && MAC_OS_X_VERSION_MAX_ALLOWED >= MAC_OS_X_VERSION_10_5
	if (NSClassFromString(@"SBApplication"))
	{
		// If ScriptingBridge is available, use that.
		TerminalApplication *terminal = [SBApplication applicationWithBundleIdentifier:@"com.apple.Terminal"];
		[terminal setDelegate:self];
		[terminal activate];
		(void)[terminal doScript:script in:nil];
	}
	else
#endif
	{
		// Otherwise, use AppleScript.
		NSMutableString *scriptSource = [script mutableCopy];
		
		[scriptSource replaceOccurrencesOfString:@"\"" withString:@"\\\"" options:0 range:NSMakeRange(0, [script length])];
		[scriptSource replaceCharactersInRange:NSMakeRange(0, 0) withString:@"tell application \"Terminal\" to do script \""];
		[scriptSource appendString:@"\""];

		NSAppleScript *runScript = [[NSAppleScript alloc] initWithSource:scriptSource];
		[runScript executeAndReturnError:NULL];
		[runScript release];
		[scriptSource release];
	}
}

#pragma mark -

// For SBApplicationDelegate
- (id)eventDidFail:(const AppleEvent *)event withError:(NSError *)error
{
	return nil; // be stupid but forgiving
}
@end
