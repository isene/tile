/* xwin NAME [PARENT]: a plain window for tile's tests. With PARENT (a
 * window id) it is a dialog of that window. Prints its own id, then waits
 * until it is killed.
 *
 * With OPEN_ON=N (0-based) it first asks tile to open it on workspace N,
 * the way fleet does for a glass it starts. */
#include <X11/Xlib.h>
#include <X11/Xutil.h>
#include <X11/Xatom.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

/* The test ends by stopping the display. Leave without Xlib's complaint. */
static int gone(Display *d) { (void)d; exit(0); }

int main(int argc, char **argv)
{
    Display *d = XOpenDisplay(NULL);
    XSetIOErrorHandler(gone);
    if (!d || argc < 2) return 1;
    Window w = XCreateSimpleWindow(d, DefaultRootWindow(d), 0, 0, 300, 200,
                                   0, 0, 0x336699);
    XClassHint ch = { argv[1], "xwin" };
    XStoreName(d, w, argv[1]);
    XSetClassHint(d, w, &ch);
    if (argc > 2)
        XSetTransientForHint(d, w, (Window)strtoul(argv[2], NULL, 0));
    long pid = getpid();
    XChangeProperty(d, w, XInternAtom(d, "_NET_WM_PID", False), XA_CARDINAL, 32,
                    PropModeReplace, (unsigned char *)&pid, 1);
    if (getenv("OPEN_ON")) {
        XEvent e = { .xclient = { .type = ClientMessage, .window = DefaultRootWindow(d),
                                  .message_type = XInternAtom(d, "_TILE_OPEN_ON", False),
                                  .format = 32 } };
        e.xclient.data.l[0] = atol(getenv("OPEN_ON"));
        e.xclient.data.l[1] = pid;
        XSendEvent(d, DefaultRootWindow(d), False,
                   SubstructureRedirectMask | SubstructureNotifyMask, &e);
    }
    XSelectInput(d, w, StructureNotifyMask);
    XMapWindow(d, w);
    XSync(d, False);
    printf("0x%lx\n", w);
    fflush(stdout);
    for (;;) { XEvent e; XNextEvent(d, &e); }
}
