#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Runs a block and catches any Objective-C exception it raises (TextKit raises them for glyph-generation
/// faults, and on a background thread an uncaught one aborts the process). Returns the exception's reason,
/// or nil when the block finished.
NSString * _Nullable TypesetCatchException(void (NS_NOESCAPE ^block)(void));

NS_ASSUME_NONNULL_END
