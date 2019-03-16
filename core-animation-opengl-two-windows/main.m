/**
 * clang++ main.mm -framework Cocoa -framework QuartzCore -framework IOSurface -framework OpenGL -o test && ./test
 **/

#import <Cocoa/Cocoa.h>
#import <QuartzCore/QuartzCore.h>
#import <IOSurface/IOSurfaceObjC.h>
#import <OpenGL/gl.h>

static NSOpenGLContext* MakeOffscreenGLContext(void);

@interface OpenGLDrawer : NSObject
{
    GLuint programID_;
    GLuint texture_;
    GLuint textureUniform_;
    GLuint angleUniform_;
    GLuint rectUniform_;
    GLuint posAttribute_;
    GLuint vertexBuffer_;
    
    NSSize textureSize_;
    uint64_t frameCounter_;
}

- (instancetype)init;
- (void)drawToFBO:(GLuint)fbo width:(int)width height:(int)height angle:(float)angle;

@end

@protocol IOSurfaceProvider
- (IOSurface*)surfaceWithWidth:(NSInteger)width height:(NSInteger)height;
- (void)returnSurface:(IOSurface*)surface;
@end

@interface IOSurfaceContentsDrawerUsingOpenGL : NSObject<IOSurfaceProvider>
{
    NSOpenGLContext* glContext_;
    OpenGLDrawer* glDrawer_;
    NSMutableDictionary<NSNumber*, NSDictionary<NSString*, NSNumber*>*>* mRegisteredIOSurfaces;
}
- (id)initWithContext:(NSOpenGLContext*)context;
- (void)drawIntoSurface:(IOSurface*)surface;
@end

@class IOSurface;

// A CAIOSurfaceLayer is CALayer subclass which wraps a "swapchain" of IOSurfaces.
// It supports setting an opaque region and it keeps track of invalid areas
// within the surfaces.
// Internally, it is assembled of one or more sublayers, depending on the
// opaque region: Regular CALayers only support a per-layer "is opaque" setting,
// so CASurfaceLayer creates layers for the opaque and transparent rectangles
// that together form the full layer. All sublayers share the same IOSurface.
// Submitting a new frame updates all sublayers.
@interface CAIOSurfaceLayer : CALayer {
    NSObject<IOSurfaceProvider>* mIOSurfaceProvider; // [strong]
    
    // The surface we returned from the most recent call to takeNextSurfaceWithWidth:height.
    // Can be null if notifySurfaceReadyForUse has been called.
    IOSurface* mCurrentSurface; // [strong]
    
    // Whether we're ready to submit mCurrentSurface during the next call to
    // display. Meaningless as long as mCurrentSurface is null.
    BOOL mCurrentSurfaceIsReadyForUse;
    
    // Really, it's a state machine:
    // NoCurrentSurface -[takeNextSurface]-> CurrentSurfaceButNotReady
    // -[notifySurfaceReadyForUse]-> CurrentSurfaceReady -[display]-> NoCurrentSurface
    
    // The queue of surfaces which make up our "swap chain".
    // [mSurfaces firstObject] is the next surface we'll attempt to use.
    // [mSurfaces lastObject] is the one we submitted most recently.
    NSMutableArray<IOSurface*>* mSurfaces; // [strong]
}

- (id)initWithIOSurfaceProvider:(NSObject<IOSurfaceProvider>*)provider;
+ (CAIOSurfaceLayer*)layerWithIOSurfaceProvider:(NSObject<IOSurfaceProvider>*)provider;
// - (void)invalidateRectThroughoutSwapchain:(NSRect)aRect;
- (IOSurface*)takeNextSurfaceWithWidth:(NSInteger)width height:(NSInteger)height;
// - (NSRect)currentSurfaceInvalidRect;
// - (NSRect)opaqueRect;
- (void)notifySurfaceReadyForUse;
- (BOOL)hasReadySurface;

@end

@interface TestView: NSView<CALayerDelegate>
{
    IOSurfaceContentsDrawerUsingOpenGL* drawer_;
    uint64_t frameCounter_;
    CAIOSurfaceLayer* contentLayer_;
}

@end

@implementation TestView

- (id)initWithFrame:(NSRect)aFrame
{
    self = [super initWithFrame:aFrame];
    
    frameCounter_ = 0;
    
    self.layer = [CALayer layer];
    self.wantsLayer = YES;
    self.layer.delegate = self;
    self.layerContentsRedrawPolicy = NSViewLayerContentsRedrawDuringViewResize;
    
    drawer_ = [[IOSurfaceContentsDrawerUsingOpenGL alloc] initWithContext:MakeOffscreenGLContext()];
    
    contentLayer_ = [[CAIOSurfaceLayer layerWithIOSurfaceProvider:drawer_] retain];
    contentLayer_.position = NSZeroPoint;
    contentLayer_.anchorPoint = NSZeroPoint;
    contentLayer_.bounds = self.bounds;
    NSSize backingSize = [self convertSizeToBacking:self.bounds.size];
    IOSurface* surface = [contentLayer_ takeNextSurfaceWithWidth:(int)backingSize.width height:(int)backingSize.height];
    [drawer_ drawIntoSurface:surface];
    [contentLayer_ notifySurfaceReadyForUse];
    [self.layer addSublayer:contentLayer_];
    
    CALayer* colorLayer = [CALayer layer];
    colorLayer.backgroundColor = [[NSColor colorWithDeviceRed:0.0 green:0.8 blue:0.0 alpha:1.0] CGColor];
    colorLayer.position = NSZeroPoint;
    colorLayer.anchorPoint = NSZeroPoint;
    colorLayer.bounds = NSMakeRect(0, 0, 10, 5);
    colorLayer.zPosition = 1.0;
    [self.layer addSublayer:colorLayer];
    return self;
}

- (void)dealloc
{
    [contentLayer_ release];
    [drawer_ release];
    [super dealloc];
}

- (void)displayLayer:(CALayer *)layer
{
    
    //     NSLog(@"updateLayer in window %@", [self window]);
    [contentLayer_ setNeedsDisplay];
    @synchronized(self) {
        if (![contentLayer_ hasReadySurface]) {
            NSSize backingSize = [self convertSizeToBacking:self.bounds.size];
            IOSurface* surface = [contentLayer_ takeNextSurfaceWithWidth:(int)backingSize.width height:(int)backingSize.height];
            if (surface) {
                [drawer_ drawIntoSurface:surface];
                [contentLayer_ notifySurfaceReadyForUse];
            }
        }
    }
    [CATransaction setDisableActions:YES];
    contentLayer_.bounds = self.bounds;
    self.layer.sublayers.lastObject.position = NSMakePoint(640 + (frameCounter_ % 60) * 10, self.bounds.size.height - 5);
    [CATransaction setDisableActions:NO];
    
    frameCounter_++;
}

@end

@interface TerminateOnClose : NSObject<NSWindowDelegate>
@end

@implementation TerminateOnClose
- (void)windowWillClose:(NSNotification*)notification
{
    [NSApp terminate:self];
}
- (void)windowDidChangeScreen:(NSNotification*)notification
{
    NSLog(@"should re-setup CVDisplayLink");
}
@end

@interface Compositor : NSObject
{
    NSArray<TestView*>* mViews;
    CVDisplayLinkRef mDisplayLink;
}
- (id)initWithViews:(NSArray<TestView*>*)views;
- (void)tick;
@end

static CVReturn MyDisplayLinkCallback(CVDisplayLinkRef displayLink, const CVTimeStamp* now,
                                      const CVTimeStamp* outputTime, CVOptionFlags flagsIn,
                                      CVOptionFlags* flagsOut, void* displayLinkContext)
{
    [(Compositor*)displayLinkContext tick];
    return kCVReturnSuccess;
}

@implementation Compositor

- (id)initWithViews:(NSArray<TestView*>*)views
{
    self = [super init];
    mViews = [views retain];
    
    NSWindow* window = [views.firstObject window];
    
    // NSLog(@"%@", [[[window screen] deviceDescription] valueForKey:@"NSScreenNumber"]);
    
    CGDirectDisplayID display = [[[[window screen] deviceDescription] valueForKey:@"NSScreenNumber"] intValue];
    
    // Create a display link capable of being used with all active displays
    CVDisplayLinkCreateWithCGDisplay(display, &mDisplayLink);
    
    // Set the renderer output callback function
    CVDisplayLinkSetOutputCallback(mDisplayLink, &MyDisplayLinkCallback, self);
    
    // Activate the display link
    CVDisplayLinkStart(mDisplayLink);
    
    return self;
}

- (void)dealloc
{
    CVDisplayLinkRelease(mDisplayLink);
    [mViews release];
    [super dealloc];
}

- (void)tick
{
    // NSLog(@"tick");
    [CATransaction begin];
    for (TestView* view in mViews) {
        [view setNeedsDisplay:YES];
    }
    [CATransaction commit];
}

@end

int
main (int argc, char **argv)
{
    NSAutoreleasePool* pool = [[NSAutoreleasePool alloc] init];
    
    [NSApplication sharedApplication];
    [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
    [[NSUserDefaults standardUserDefaults] registerDefaults:@{ @"NSApplicationCrashOnExceptions": @YES }];
    int style =
    NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable | NSWindowStyleMaskMiniaturizable;
    NSRect contentRect1 = NSMakeRect(100, 100, 800, 500);
    NSWindow* window1 = [[NSWindow alloc] initWithContentRect:contentRect1
                                                    styleMask:style
                                                      backing:NSBackingStoreBuffered
                                                        defer:NO];
    
    TestView* view1 = [[TestView alloc] initWithFrame:NSMakeRect(0, 0, contentRect1.size.width, contentRect1.size.height)];
    [view1 setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
    
    [window1 contentView].wantsLayer = YES;
    [[window1 contentView] addSubview:view1];
    [window1 setDelegate:[[TerminateOnClose alloc] autorelease]];
    
    NSRect contentRect2 = NSMakeRect(400, 200, 800, 500);
    NSWindow* window2 = [[NSWindow alloc] initWithContentRect:contentRect2
                                                    styleMask:style
                                                      backing:NSBackingStoreBuffered
                                                        defer:NO];
    
    TestView* view2 = [[TestView alloc] initWithFrame:NSMakeRect(0, 0, contentRect2.size.width, contentRect2.size.height)];
    [view2 setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
    
    [window2 contentView].wantsLayer = YES;
    [[window2 contentView] addSubview:view2];
    [window2 setDelegate:[[TerminateOnClose alloc] autorelease]];
    
    [NSApp activateIgnoringOtherApps:YES];
    [window1 makeKeyAndOrderFront:window1];
    [window2 makeKeyAndOrderFront:window2];
    
    Compositor* compositor = [[Compositor alloc] initWithViews:@[view1, view2]];
    // Compositor* compositor2 = [[Compositor alloc] initWithView:view2];
    
    
    [NSApp run];
    
    [pool release];
    
    return 0;
}

static const char* kVertexShader =
"#version 120\n"
"// Input vertex data, different for all executions of this shader.\n"
"attribute vec2 aPos;\n"
"uniform float uAngle;\n"
"uniform vec4 uRect;\n"
"varying vec2 vPos;\n"
"varying mat4 vColorMat;\n"
"void main(){\n"
"  vPos = aPos;\n"
"  float lumR = 0.2126;\n"
"  float lumG = 0.7152;\n"
"  float lumB = 0.0722;\n"
"  float oneMinusLumR = 1.0 - lumR;\n"
"  float oneMinusLumG = 1.0 - lumG;\n"
"  float oneMinusLumB = 1.0 - lumB;\n"
"  float oneMinusAmount = 1.0 - uAngle;\n"
"  float c = cos(uAngle * 0.01745329251);\n"
"  float s = sin(uAngle * 0.01745329251);\n"
"  vColorMat = mat4(vec4(lumR + oneMinusLumR * c - lumR * s,\n"
"                        lumR - lumR * c + 0.143 * s,\n"
"                        lumR - lumR * c - oneMinusLumR * s,\n"
"                        0.0),\n"
"                   vec4(lumG - lumG * c - lumG * s,\n"
"                        lumG + oneMinusLumG * c + 0.140 * s,\n"
"                        lumG - lumG * c + lumG * s,\n"
"                        0.0),\n"
"                   vec4(lumB - lumB * c + oneMinusLumB * s,\n"
"                        lumB - lumB * c - 0.283 * s,\n"
"                        lumB + oneMinusLumB * c + lumB * s,\n"
"                        0.0),\n"
"                   vec4(0.0, 0.0, 0.0, 1.0));\n"
"  gl_Position = vec4(uRect.xy + aPos * uRect.zw, 0.0, 1.0);\n"
"}\n";

static const char* kFragmentShader =
"#version 120\n"
"varying vec2 vPos;\n"
"varying mat4 vColorMat;\n"
"uniform sampler2D uSampler;\n"
"void main()\n"
"{\n"
"  gl_FragColor = vColorMat * texture2D(uSampler, vPos);\n"
"}\n";

@implementation OpenGLDrawer

- (instancetype)init
{
    self = [super init];
    
    // Create and compile our GLSL program from the shaders.
    programID_ = [self compileProgramWithVertexShader:kVertexShader fragmentShader:kFragmentShader];
    
    textureSize_ = NSMakeSize(300, 200);
    frameCounter_ = 0;
    
    // Create a texture
    texture_ = [self createTextureWithSize:textureSize_ drawingHandler:^(CGContextRef ctx) {
        NSGraphicsContext* oldGC = [NSGraphicsContext currentContext];
        [NSGraphicsContext setCurrentContext:[NSGraphicsContext graphicsContextWithGraphicsPort:ctx flipped:YES]];
        
        CGFloat imageSize = MIN(textureSize_.width, textureSize_.height);
        NSRect squareInTheMiddleOfTexture = {
            textureSize_.width / 2 - imageSize / 2,
            textureSize_.height / 2 - imageSize / 2,
            imageSize,
            imageSize
        };
        
        [[NSImage imageNamed:NSImageNameColorPanel] drawInRect:squareInTheMiddleOfTexture
                                                      fromRect:NSZeroRect
                                                     operation:NSCompositingOperationSourceOver
                                                      fraction:1.0];
        [NSGraphicsContext setCurrentContext:oldGC];
    }];
    textureUniform_ = glGetUniformLocation(programID_, "uSampler");
    angleUniform_ = glGetUniformLocation(programID_, "uAngle");
    rectUniform_ = glGetUniformLocation(programID_, "uRect");
    
    // Get a handle for our buffers
    posAttribute_ = glGetAttribLocation(programID_, "aPos");
    
    static const GLfloat g_vertex_buffer_data[] = {
        0.0f,  0.0f,
        1.0f,  0.0f,
        0.0f,  1.0f,
        1.0f,  1.0f,
    };
    
    glGenBuffers(1, &vertexBuffer_);
    glBindBuffer(GL_ARRAY_BUFFER, vertexBuffer_);
    glBufferData(GL_ARRAY_BUFFER, sizeof(g_vertex_buffer_data), g_vertex_buffer_data, GL_STATIC_DRAW);
    
    return self;
}

- (GLuint)compileProgramWithVertexShader:(const char*)vertexShader fragmentShader:(const char*)fragmentShader
{
    // Create the shaders
    GLuint vertexShaderID = glCreateShader(GL_VERTEX_SHADER);
    GLuint fragmentShaderID = glCreateShader(GL_FRAGMENT_SHADER);
    
    GLint result = GL_FALSE;
    int infoLogLength;
    
    // Compile Vertex Shader
    glShaderSource(vertexShaderID, 1, &vertexShader , NULL);
    glCompileShader(vertexShaderID);
    
    // Check Vertex Shader
    glGetShaderiv(vertexShaderID, GL_COMPILE_STATUS, &result);
    glGetShaderiv(vertexShaderID, GL_INFO_LOG_LENGTH, &infoLogLength);
    if (infoLogLength > 0) {
        NSMutableData* msgData = [NSMutableData dataWithCapacity:infoLogLength+1];
        glGetShaderInfoLog(vertexShaderID, infoLogLength, NULL, (GLchar*)[msgData mutableBytes]);
        NSString* msg = [[NSString alloc] initWithData:msgData encoding:NSASCIIStringEncoding];
        NSLog(@"Vertex shader compilation failed: %@\n", msg);
        [msg release];
        [msgData release];
    }
    
    // Compile Fragment Shader
    glShaderSource(fragmentShaderID, 1, &fragmentShader , NULL);
    glCompileShader(fragmentShaderID);
    
    // Check Fragment Shader
    glGetShaderiv(fragmentShaderID, GL_COMPILE_STATUS, &result);
    glGetShaderiv(fragmentShaderID, GL_INFO_LOG_LENGTH, &infoLogLength);
    if (infoLogLength > 0) {
        NSMutableData* msgData = [NSMutableData dataWithCapacity:infoLogLength+1];
        glGetShaderInfoLog(fragmentShaderID, infoLogLength, NULL, (GLchar*)[msgData mutableBytes]);
        NSString* msg = [[NSString alloc] initWithData:msgData encoding:NSASCIIStringEncoding];
        NSLog(@"Fragment shader compilation failed: %@\n", msg);
        [msg release];
        [msgData release];
    }
    
    // Link the program
    GLuint programID = glCreateProgram();
    glAttachShader(programID, vertexShaderID);
    glAttachShader(programID, fragmentShaderID);
    glLinkProgram(programID);
    
    // Check the program
    glGetProgramiv(programID, GL_LINK_STATUS, &result);
    glGetProgramiv(programID, GL_INFO_LOG_LENGTH, &infoLogLength);
    if (infoLogLength > 0) {
        NSMutableData* msgData = [NSMutableData dataWithCapacity:infoLogLength+1];
        glGetProgramInfoLog(programID, infoLogLength, NULL, (GLchar*)[msgData mutableBytes]);
        NSString* msg = [[NSString alloc] initWithData:msgData encoding:NSASCIIStringEncoding];
        NSLog(@"Program linking failed: %@\n", msg);
        [msg release];
        [msgData release];
    }
    
    glDeleteShader(vertexShaderID);
    glDeleteShader(fragmentShaderID);
    
    return programID;
}

- (GLuint)createTextureWithSize:(NSSize)size drawingHandler:(void (^)(CGContextRef))drawingHandler
{
    int width = size.width;
    int height = size.height;
    CGColorSpaceRef rgb = CGColorSpaceCreateDeviceRGB();
    CGContextRef imgCtx = CGBitmapContextCreate(NULL, width, height, 8, width * 4,
                                                rgb, kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Host);
    CGColorSpaceRelease(rgb);
    drawingHandler(imgCtx);
    CGContextRelease(imgCtx);
    
    GLuint texture = 0;
    glActiveTexture(GL_TEXTURE0);
    glGenTextures(1, &texture);
    glBindTexture(GL_TEXTURE_2D, texture);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, width, height, 0, GL_BGRA, GL_UNSIGNED_BYTE, CGBitmapContextGetData(imgCtx));
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    return texture;
}

- (void)drawToFBO:(GLuint)fbo width:(int)width height:(int)height angle:(float)angle
{
    glBindFramebuffer(GL_FRAMEBUFFER, fbo);
    
    glViewport(0, 0, width, height);
    
    NSRect wholeViewport = { -1, -1, 2, 2 };
    
    if (1) {
        double alpha = 0.3;
        glClearColor(0.7 * alpha, 0.8 * alpha, 1.0 * alpha, 1.0 * alpha);
        glClear(GL_COLOR_BUFFER_BIT);
    }
    
    glFlush();
    
    if (1) {
        glBlendFuncSeparate(GL_ONE, GL_ONE_MINUS_SRC_ALPHA, GL_ONE, GL_ONE_MINUS_SRC_ALPHA);
        glEnable(GL_BLEND);
    
        glUseProgram(programID_);
    
        glActiveTexture(GL_TEXTURE0);
        glBindTexture(GL_TEXTURE_2D, texture_);
        glUniform1i(textureUniform_, 0);
        glUniform1f(angleUniform_, angle);
        //    glUniform4f(rectUniform_,
        //                wholeViewport.origin.x, wholeViewport.origin.y,
        //                textureSize_.width / width * wholeViewport.size.width,
        //                textureSize_.height / height * wholeViewport.size.height);
        glUniform4f(rectUniform_,
                    wholeViewport.origin.x, wholeViewport.origin.y,
                    wholeViewport.size.width, wholeViewport.size.height);
    
        glEnableVertexAttribArray(posAttribute_);
        glBindBuffer(GL_ARRAY_BUFFER, vertexBuffer_);
        glVertexAttribPointer(posAttribute_, // The attribute we want to configure
                              2,             // size
                              GL_FLOAT,      // type
                              GL_FALSE,      // normalized?
                              0,             // stride
                              (void*)0       // array buffer offset
                              );
    
        glDrawArrays(GL_TRIANGLE_STRIP, 0, 4); // 4 indices starting at 0 -> 2 triangles
    
        glDisable(GL_BLEND);
        glDisableVertexAttribArray(posAttribute_);
    }
    glEnable(GL_SCISSOR_TEST);
    glScissor(0, 0, width, 10);
    glClearColor(0.9, 0.9, 0.9, 1.0);
    glClear(GL_COLOR_BUFFER_BIT);
    glScissor((frameCounter_ % 60) * 20, 0, 20, 10);
    glClearColor(0, 0, 0.8, 1.0);
    glClear(GL_COLOR_BUFFER_BIT);
    glDisable(GL_SCISSOR_TEST);
    
    glBindFramebuffer(GL_FRAMEBUFFER, 0);
    
    frameCounter_++;
}

- (void)dealloc
{
    glDeleteTextures(1, &texture_);
    glDeleteBuffers(1, &vertexBuffer_);
    
    [super dealloc];
}

@end

static IOSurfaceRef
CreateTransparentIOSurface(int aWidth, int aHeight)
{
    NSDictionary* dict = @{
                           IOSurfacePropertyKeyWidth: [NSNumber numberWithInt:aWidth],
                           IOSurfacePropertyKeyHeight: [NSNumber numberWithInt:aHeight],
                           IOSurfacePropertyKeyBytesPerElement: [NSNumber numberWithInt:4],
                           IOSurfacePropertyKeyPixelFormat: [NSNumber numberWithInt:'BGRA'],
                           //(NSString*)kIOSurfaceIsGlobal: [NSNumber numberWithBool:YES]
                           };
    IOSurfaceRef surf = IOSurfaceCreate((CFDictionaryRef)dict);
//    NSLog(@"IOSurface: %@", surf);
    
    return surf;
}

static GLuint
CreateTextureForIOSurface(CGLContextObj cglContext, IOSurfaceRef surf)
{
    GLuint texture;
    glGenTextures(1, &texture);
    glBindTexture(GL_TEXTURE_RECTANGLE_ARB, texture);
    CGLError rv =
    CGLTexImageIOSurface2D(cglContext, GL_TEXTURE_RECTANGLE_ARB, GL_RGBA,
                           (int)IOSurfaceGetWidth(surf), (int)IOSurfaceGetHeight(surf),
                           GL_BGRA, GL_UNSIGNED_INT_8_8_8_8_REV, surf, 0);
    if (rv != 0) {
        NSLog(@"CGLError: %d", rv);
    }
    glBindTexture(GL_TEXTURE_RECTANGLE_ARB, 0);
    return texture;
}

static GLuint
CreateFBOForTexture(GLuint texture)
{
    GLuint framebuffer;
    glGenFramebuffers(1, &framebuffer);
    glBindFramebuffer(GL_FRAMEBUFFER, framebuffer);
    glBindTexture(GL_TEXTURE_RECTANGLE_ARB, texture);
    glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0,
                           GL_TEXTURE_RECTANGLE_ARB, texture, 0);
    GLenum status = glCheckFramebufferStatus(GL_FRAMEBUFFER);
    if (status != GL_FRAMEBUFFER_COMPLETE) {
        NSLog(@"framebuffer incomplete");
    }
    glBindFramebuffer(GL_FRAMEBUFFER, 0);
    glBindTexture(GL_TEXTURE_RECTANGLE_ARB, 0);
    return framebuffer;
}

static NSOpenGLContext*
MakeOffscreenGLContext()
{
    NSOpenGLPixelFormatAttribute attribs[] = {
        NSOpenGLPFAAllowOfflineRenderers,
        //NSOpenGLPFADoubleBuffer,
        (NSOpenGLPixelFormatAttribute)nil
    };
    NSOpenGLPixelFormat* pixelFormat = [[NSOpenGLPixelFormat alloc] initWithAttributes:attribs];
    NSOpenGLContext* ctx = [[NSOpenGLContext alloc] initWithFormat:pixelFormat shareContext:nil];
    [pixelFormat release];
    return [ctx autorelease];
}

@implementation IOSurfaceContentsDrawerUsingOpenGL

- (id)initWithContext:(NSOpenGLContext*)context
{
    self = [super init];
    
    mRegisteredIOSurfaces = [[NSMutableDictionary dictionaryWithCapacity:10] retain];
    glContext_ = [context retain];
    CGLLockContext([glContext_ CGLContextObj]);
    [glContext_ makeCurrentContext];
    glDrawer_ = [[OpenGLDrawer alloc] init];
    [NSOpenGLContext clearCurrentContext];
    CGLUnlockContext([glContext_ CGLContextObj]);
    
    return self;
}

- (void)dealloc
{
    CGLLockContext([glContext_ CGLContextObj]);
    [glContext_ makeCurrentContext];
    // TODO: unregister iosurfaces
    [mRegisteredIOSurfaces release];
    [glDrawer_ release];
    [NSOpenGLContext clearCurrentContext];
    CGLUnlockContext([glContext_ CGLContextObj]);
    [glContext_ release];
    [super dealloc];
}

static float CurrentAngle() { return fmod(CFAbsoluteTimeGetCurrent(), 1.0) * 360; }

- (void)drawIntoSurface:(IOSurface*)surface
{
    NSDictionary<NSString*, NSNumber*>* props = [mRegisteredIOSurfaces objectForKey:[NSNumber numberWithUnsignedInteger:(uintptr_t)surface]];
    GLuint surffbo = [[props objectForKey:@"fbo"] unsignedIntValue];
    CGLLockContext([glContext_ CGLContextObj]);
    [glContext_ makeCurrentContext];
    [glDrawer_ drawToFBO:surffbo width:(int)[surface width] height:(int)[surface height] angle:CurrentAngle()];
    glFlush();
    [NSOpenGLContext clearCurrentContext];
    CGLUnlockContext([glContext_ CGLContextObj]);
}

- (void)returnSurface:(IOSurface *)surface {
    CGLLockContext([glContext_ CGLContextObj]);
    [glContext_ makeCurrentContext];
    NSDictionary<NSString*, NSNumber*>* props = [mRegisteredIOSurfaces objectForKey:[NSNumber numberWithUnsignedInteger:(uintptr_t)surface]];
    
    GLuint surffbo = [[props objectForKey:@"fbo"] unsignedIntValue];
    if (surffbo) {
        glDeleteFramebuffers(1, &surffbo);
        surffbo = 0;
    }
    GLuint surftex = [[props objectForKey:@"tex"] unsignedIntValue];
    if (surftex) {
        glDeleteTextures(1, &surftex);
        surftex = 0;
    }
    [mRegisteredIOSurfaces removeObjectForKey:[NSNumber numberWithUnsignedInteger:(uintptr_t)surface]];
    
    [NSOpenGLContext clearCurrentContext];
    CGLUnlockContext([glContext_ CGLContextObj]);
}

- (IOSurface *)surfaceWithWidth:(NSInteger)width height:(NSInteger)height {
    IOSurfaceRef surf = CreateTransparentIOSurface((int)width, (int)height);
    CGLLockContext([glContext_ CGLContextObj]);
    [glContext_ makeCurrentContext];
    GLuint surftex = CreateTextureForIOSurface([glContext_ CGLContextObj], surf);
    GLuint surffbo = CreateFBOForTexture(surftex);
    NSLog(@"have surf %p surftex %d surffbo %d", surf, surftex, surffbo);
    [NSOpenGLContext clearCurrentContext];
    CGLUnlockContext([glContext_ CGLContextObj]);
    
    [mRegisteredIOSurfaces setObject:@{ @"tex": [NSNumber numberWithUnsignedInteger:surftex], @"fbo": [NSNumber numberWithUnsignedInteger:surffbo]} forKey:[NSNumber numberWithUnsignedInteger:(uintptr_t)surf]];
    
    return [(id)surf autorelease];
}

@end


@implementation CAIOSurfaceLayer

- (id)initWithIOSurfaceProvider:(NSObject<IOSurfaceProvider>*)provider {
    self = [super init];
    
    mIOSurfaceProvider = [provider retain];
    mCurrentSurface = nil;
    mCurrentSurfaceIsReadyForUse = NO;
    mSurfaces = [[NSMutableArray arrayWithCapacity:4] retain];
    
    return self;
}

+ (CAIOSurfaceLayer*)layerWithIOSurfaceProvider:(NSObject<IOSurfaceProvider>*)provider {
    return [[[CAIOSurfaceLayer alloc] initWithIOSurfaceProvider:provider] autorelease];
}

- (void)dealloc
{
    for (id surface in mSurfaces) {
        [mIOSurfaceProvider returnSurface:surface];
    }
    [mSurfaces release];
    
    if (mCurrentSurface) {
        [mIOSurfaceProvider returnSurface:mCurrentSurface];
    }
    [mCurrentSurface release];
    
    [mIOSurfaceProvider release];
    
    [super dealloc];
}

- (IOSurface*)takeNextSurfaceWithWidth:(NSInteger)width height:(NSInteger)height {
    if (mCurrentSurface) {
        abort();
    }
    
    IOSurface* surf = [[mSurfaces firstObject] retain];
    if (surf) {
        // Check if we can reuse surf. If the size has changed, throw the old
        // one out. If it is still in use (usually by the window server), keep
        // it in the queue because it will likely become unused soon.
        if ([surf width] != width || [surf height] != height) {
            [mSurfaces removeObjectAtIndex:0];
            [mIOSurfaceProvider returnSurface:surf];
            [surf release];
            surf = nil;
        } else if ([surf isInUse]) {
            [surf release];
            surf = nil;
        } else {
            [mSurfaces removeObjectAtIndex:0];
//            NSLog(@"reusing surface");
        }
    }
    if (!surf) {
//        NSLog(@"allocating new surface");
        surf = [[mIOSurfaceProvider surfaceWithWidth:width height:height] retain];
    }
    if (!surf) {
//        NSLog(@"surface allocation failed!");
        return nil;
    }
    mCurrentSurface = [surf retain];
    [mCurrentSurface incrementUseCount];
    mCurrentSurfaceIsReadyForUse = NO;
    [surf release];
    surf = nil;
    return mCurrentSurface;
}

- (void)notifySurfaceReadyForUse {
    if (!mCurrentSurface) {
        abort();
    }
    mCurrentSurfaceIsReadyForUse = YES;
}

- (BOOL)hasReadySurface {
    return mCurrentSurface && mCurrentSurfaceIsReadyForUse;
}

- (void)display {
//    NSLog(@"CAIOSurfaceLayer display!");
    @synchronized(self) {
        if (mCurrentSurface && mCurrentSurfaceIsReadyForUse) {
            self.contents = mCurrentSurface;
            [mSurfaces addObject:mCurrentSurface];
            [mCurrentSurface decrementUseCount];
            [mCurrentSurface release];
            mCurrentSurface = nil;
        }
    }
}

@end
