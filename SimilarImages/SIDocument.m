/*	Copyright 2012 Dorian Johnson <2012@dorianj.net>
 */

#import "SIDocument.h"
#import "SIImageBrowserItem.h"

#import "DJImageTrawler.h"
#import "DJImageHash.h"


#define TRACE_FUNC() NSLog(@"%s", __func__)

@interface SIDocument ()

@property (readwrite, retain) NSArray* observedKeys;

// An array of all found images.
@property (readwrite, retain) NSArray* images;

// The image last searched for.
@property (readwrite, retain) NSURL* needleImageURL;

@end


@implementation SIDocument

// Public properties.
@synthesize needleImagePicker, matchingImages, resultsImageBrowserView, rootURL, haystackPathControl;

// Private properties.
@synthesize images, observedKeys, needleImageURL;



- (id)init
{
    if ((self = [super init]) == nil)
		return nil;
	
	[self setObservedKeys:[NSArray arrayWithObjects:
						   @"matchingImages",   // Update the browser when the results change
						   @"rootURL",          // When rootURL is changed, scan the new one
						   @"needleImageURL",   // When search URL is changed, re-search
						   nil]];
	
	for (NSString* keyPath in [self observedKeys])
		[self addObserver:self forKeyPath:keyPath options:NSKeyValueObservingOptionNew context:NULL];
		
	[[NSUserDefaults standardUserDefaults] addObserver:self forKeyPath:@"SISearchSensitivity" options:NSKeyValueObservingOptionNew context:NULL];
    return self;
}

- (void)dealloc
{
	for (NSString* keyPath in [self observedKeys])
		[self removeObserver:self forKeyPath:keyPath];
	
	[[NSUserDefaults standardUserDefaults] removeObserver:self forKeyPath:@"SISearchSensitivity"];
}

- (void)awakeFromNib
{


	// Configure the results image browser
	[[self resultsImageBrowserView] setCanControlQuickLookPanel:YES];
	[[self resultsImageBrowserView] setCellsStyleMask:(IKCellsStyleNone | IKCellsStyleShadowed | IKCellsStyleTitled /*| IKCellsStyleSubtitled*/)];
	
	[[NSOperationQueue mainQueue] addOperationWithBlock:^{
		[self runRootDirChooserSheet:nil];
	}];
}

- (IBAction)runRootDirChooserSheet:(id)sender
{	
	NSOpenPanel* open_panel = [NSOpenPanel openPanel];
	[open_panel setCanChooseDirectories:YES];
	[open_panel setCanChooseFiles:NO];
	
	if ([sender respondsToSelector:@selector(clickedPathComponentCell)])
		[open_panel setDirectoryURL:[[sender clickedPathComponentCell] URL]];;
	
	[open_panel beginSheetModalForWindow:[self windowForSheet] completionHandler:^(NSInteger result) {
		if (result != NSOKButton)
		{
			if ([self rootURL] == nil)
			{	
				// Didnt' have a root URL previously; showing the window now would leave it unusable.
				[self close];
			}
			
			return;
		}
		
		[self setRootURL:[open_panel URL]];
	}];	
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context
{
	if (object == self)
	{
		if ([keyPath isEqualToString:@"matchingImages"])
		{
			[[self resultsImageBrowserView] performSelectorOnMainThread:@selector(reloadData) withObject:nil waitUntilDone:NO];
		}
		else if ([keyPath isEqualToString:@"rootURL"])
		{
			if ([self rootURL] == nil)
				return;

			NSString* windowTitle = [[self rootURL] lastPathComponent];
			[self setDisplayName:windowTitle];
			[[self windowForSheet] setTitle:windowTitle];
			[[self rootURL] startAccessingSecurityScopedResource];
			[self performSelectorOnMainThread:@selector(trawlRootURL) withObject:nil waitUntilDone:NO];
		}
		else if ([keyPath isEqualToString:@"needleImageURL"])
		{			
			if ([self needleImageURL] == nil)
				return;
			
			[self setMatchingImages:[self findImagesVisuallySimilarToImage:[self needleImageURL]]];
			
			if ([keyPath isEqualToString:@"needleImageURL"] && ([[self matchingImages] count] == 0))
				NSRunAlertPanel(@"No images found", @"No similar images were found. Try reducing sensitivity to get more results.", @"OK", @"", @"");
		}
	}
	else if (object == [NSUserDefaults standardUserDefaults])
	{	
		if ([keyPath isEqualToString:@"SISearchSensitivity"])
		{
			if ([self needleImageURL] == nil)
				return;
			
			BOOL changed = NO;
			NSArray* newMatches = [self findImagesVisuallySimilarToImage:[self needleImageURL]];
			
			if ([newMatches count] != [[self matchingImages] count])
				changed = YES;
			else
			{
				for (NSUInteger i = 0; i < [[self matchingImages] count]; i++)
					if (![[[[self matchingImages] objectAtIndex:i] objectForKey:@"bitem"] isEqual:[[newMatches objectAtIndex:i] objectForKey:@"bitem"]])
					{
						changed = YES;
						break;
					}
			}
			
			if (changed)
				[self setMatchingImages:newMatches];
		}
	}
}


#pragma mark -
#pragma mark Managing the trawl progress sheet

@synthesize trawlProgressWindow, trawlProgressIndicator, trawlProgressImageCount;

- (void)showTrawlProgressSheet
{
	[[NSApplication sharedApplication] beginSheet:[self trawlProgressWindow] modalForWindow:[self windowForSheet] modalDelegate:self didEndSelector:@selector(sheetDidEnd:returnCode:contextInfo:) contextInfo:NULL];
	[[self trawlProgressIndicator] startAnimation:self];
}

- (void)hideTrawlProgressSheet
{
	[[NSApplication sharedApplication] endSheet:[self trawlProgressWindow]];
}

- (void)updateTrawlProgressSheet:(NSDictionary*)trawl_info
{
	if ([[trawl_info objectForKey:@"searchComplete"] boolValue])
	{
		if ([[self trawlProgressIndicator] isIndeterminate])
		{
			[[self trawlProgressIndicator] setIndeterminate:NO];
			[[self trawlProgressIndicator] setMinValue:0];
		}
		
		[[self trawlProgressIndicator] setMaxValue:[[trawl_info objectForKey:@"fileCount"] doubleValue]];
		[[self trawlProgressIndicator] setDoubleValue:[[trawl_info objectForKey:@"completeCount"] doubleValue]];
		[[self trawlProgressIndicator] displayIfNeeded];
	}
	else
	{
		if (![[self trawlProgressIndicator] isIndeterminate])
		{
			[[self trawlProgressIndicator] setIndeterminate:YES];
		}
	}
	
	[[self trawlProgressImageCount] setStringValue:[NSString stringWithFormat:@"%ld / %ld", [[trawl_info objectForKey:@"completeCount"] integerValue], [[trawl_info objectForKey:@"fileCount"] integerValue]]];
}

- (void)sheetDidEnd:(NSWindow *)sheet returnCode:(NSInteger)returnCode contextInfo:(void *)contextInfo
{
	[sheet close];
}

#pragma mark -
#pragma mark NSDocument

- (NSString *)windowNibName
{
	return @"SIDocument";
}

- (void)windowControllerDidLoadNib:(NSWindowController *)aController
{
	[super windowControllerDidLoadNib:aController];
	// Add any code here that needs to be executed once the windowController has loaded the document's window.
}

+ (BOOL)autosavesInPlace
{
    return YES;
}

- (NSData *)dataOfType:(NSString *)typeName error:(NSError **)outError
{
	if (![typeName isEqualToString:@"SimilarImagesSearch"])
	{
		NSLog(@"%s doesn't support data of type %@", __func__, typeName);
		return nil;
	}

	// Pack up the root URL in a secure bookmark.
	NSError* error;
	NSData* rootURLData = [[self rootURL] bookmarkDataWithOptions:NSURLBookmarkCreationWithSecurityScope includingResourceValuesForKeys:nil relativeToURL:nil error:&error];
	
	if (rootURLData == nil)
	{
		NSLog(@"%s: Error saving: couldn't create data of rootURL. %@", __func__, error);
		return nil;
	}

	NSMutableDictionary* searchInfo = [NSMutableDictionary dictionaryWithObjectsAndKeys:
											//   [self images], @"images",
											   rootURLData, @"rootURL",
											   nil];

	//return [NSPropertyListSerialization dataWithPropertyList:archivedSearchInfo format:NSPropertyListBinaryFormat_v1_0 options:NSPropertyListImmutable error:NULL];
	return [NSKeyedArchiver archivedDataWithRootObject:searchInfo];
}

- (BOOL)readFromData:(NSData *)data ofType:(NSString *)typeName error:(NSError **)outError
{
	if (![typeName isEqualToString:@"SimilarImagesSearch"])
	{
		NSLog(@"%s doesn't support data of type %@", __func__, typeName);
		return NO;
	}

	NSDictionary* searchInfo = [NSKeyedUnarchiver unarchiveObjectWithData:data];
	
	NSError* error;
	BOOL bookmarkIsStale;
	NSURL* newRootURL = [NSURL URLByResolvingBookmarkData:[searchInfo objectForKey:@"rootURL"] options:NSURLBookmarkResolutionWithSecurityScope relativeToURL:nil bookmarkDataIsStale:&bookmarkIsStale error:&error];
	
	if (newRootURL == nil)
	{
		NSLog(@"%s: Error loading: couldn't create URL from data. %@", __func__, error);
		return NO;
	}
	
	[self setRootURL:newRootURL];
	return YES;
}


#pragma mark -
#pragma mark Searching directories for images

- (void)trawlRootURL
{
	[self showTrawlProgressSheet];
	
	[[NSOperationQueue new] addOperationWithBlock:^{
		[self setImages:[self trawlImagesInURL:[self rootURL]]];
		[self performSelectorOnMainThread:@selector(hideTrawlProgressSheet) withObject:nil waitUntilDone:NO];
	}];
}

- (NSArray*)trawlImagesInURL:(NSURL*)root_url
{
	DJImageTrawler* trawler = [[DJImageTrawler alloc] initWithURL:root_url];
	[trawler trawlImagesWithProgressBlock:^(NSDictionary* progress_info) {
		[self performSelectorOnMainThread:@selector(updateTrawlProgressSheet:) withObject:progress_info waitUntilDone:NO];
	}];
	return [trawler images];
}


#pragma mark -
#pragma mark Finding visually similar images (after trawling)

- (NSArray*)findImagesVisuallySimilarToImage:(NSURL*)imageURL
{
	NSMutableArray* matches = [NSMutableArray array];
	DJImageHash* needle_hash = [[DJImageHash alloc] initWithURL:imageURL];
	NSNumber* sensitivity = [[NSUserDefaults standardUserDefaults] objectForKey:@"SISearchSensitivity"];
	
	[[self images] enumerateObjectsWithOptions:NSEnumerationConcurrent usingBlock:^(id obj, NSUInteger idx, BOOL *stop) {
		NSDictionary* item = obj;
		
		NSNumber* similarity = [needle_hash similarityTo:[item objectForKey:@"hash"] considerTransforms:YES];
		
		//NSLog(@"Considering %@ (%@ match)", [[item objectForKey:@"url"] lastPathComponent], similarity);
		
		if (!similarity || ([sensitivity compare:similarity] == NSOrderedDescending) )
			return;
		
		//NSLog(@"Found match %@: %@", similarity, [[item objectForKey:@"url"] lastPathComponent]);

		
		// This image is a match: create a browser item for it and add to the matches builder array.
		SIImageBrowserItem* browser_item = [[SIImageBrowserItem alloc] init];
		[browser_item setImageURL:[item objectForKey:@"url"]];
		
		@synchronized (matches)
		{
			[matches addObject:[NSDictionary dictionaryWithObjectsAndKeys:browser_item, @"bitem", similarity, @"dist", nil]];
		}
	}];
	
	[matches sortUsingDescriptors:[NSArray arrayWithObject:[NSSortDescriptor sortDescriptorWithKey:@"dist" ascending:NO]]];
	return matches;
}

- (IBAction)userDidDropImage:(id)sender
{
	[self setNeedleImageURL:nil];
	[self setNeedleImageURL:[[self needleImagePicker] imageURL]];
}

#pragma mark -
#pragma mark Working with the search results

- (NSArray*)selectedResultImageURLs
{
	NSIndexSet* selectedIndices = [[self resultsImageBrowserView] selectionIndexes];
	
	if ([selectedIndices count] == 0)
		return nil;
	
	NSMutableArray* selectedURLs = [NSMutableArray array];
	
	[selectedIndices enumerateIndexesUsingBlock:^(NSUInteger idx, BOOL *stop) {
		[selectedURLs addObject:[[[[self matchingImages] objectAtIndex:idx] objectForKey:@"bitem"] imageURL]];
	}];

	return selectedURLs;
}

- (IBAction)revealSearchResultInFinder:(id)sender
{
	if ([self selectedResultImageURLs])
		[[NSWorkspace sharedWorkspace] activateFileViewerSelectingURLs:[self selectedResultImageURLs]];
}

- (IBAction)openSearchResultWithDefaultApp:(id)sender
{
	//[[NSWorkspace sharedWorkspace] openURL:[[self selectedResultImageURLs] lastObject]];
	[[NSWorkspace sharedWorkspace] openURLs:[self selectedResultImageURLs] withAppBundleIdentifier:@"com.apple.preview" options:NSWorkspaceLaunchDefault additionalEventParamDescriptor:nil launchIdentifiers:NULL];
}


#pragma mark - 
#pragma mark Working with the image browser (IKImageBrowserViewDataSource)

- (NSUInteger)numberOfItemsInImageBrowser:(IKImageBrowserView*)browser;
{
	return [[self matchingImages] count];
}

- (id)imageBrowser:(IKImageBrowserView *)browser itemAtIndex:(NSUInteger)index;
{
	return [[[self matchingImages] objectAtIndex:index] objectForKey:@"bitem"];
}


@end
