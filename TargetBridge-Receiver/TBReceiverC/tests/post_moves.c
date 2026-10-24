/* post_moves.c — PWE (1.1.1) smoke helper: post <count> mouse-moved events,
 * one every <interval_ms>, at the pointer's current place with no movement,
 * so the receiver's event tap has input to forward and the pointer stays put.
 *
 *   post_moves 900 5
 */

#include <ApplicationServices/ApplicationServices.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

int main(int argc, char **argv) {
    if (argc != 3) {
        fprintf(stderr, "usage: post_moves <count> <interval_ms>\n");
        return 2;
    }
    const int count = atoi(argv[1]);
    const unsigned interval_ms = (unsigned)atoi(argv[2]);
    CGEventRef here = CGEventCreate(NULL);
    if (!here) return 1;
    const CGPoint at = CGEventGetLocation(here);
    CFRelease(here);
    for (int i = 0; i < count; i++) {
        CGEventRef move = CGEventCreateMouseEvent(NULL, kCGEventMouseMoved, at, kCGMouseButtonLeft);
        if (!move) return 1;
        CGEventPost(kCGHIDEventTap, move);
        CFRelease(move);
        usleep(interval_ms * 1000u);
    }
    return 0;
}
