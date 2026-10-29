/* tb_clipboard.h — the iMac's clipboard, kept off the main loop (PWE 1.1, T40).
 *
 * When the iMac's keyboard and mouse drive the Mac ("receiverMaster"), the
 * receiver sends the iMac's copied text to the Mac, and puts the Mac's copied
 * text on the iMac. Upstream did both on the main loop by running pbpaste
 * every 100 ms and pbcopy per packet. Reading the clipboard waits for the app
 * that owns it to supply its data: with a Screen Sharing session on the iMac
 * that wait reached 45 s (RC4, macOS 13.7.8), and the picture and the
 * connection froze with it.
 *
 * Every pasteboard call now runs on one worker thread, with NSPasteboard and
 * no child processes. The worker looks at the pasteboard's change count every
 * 100 ms (cheap: no data is fetched) and reads the text only when the count
 * changed. New text waits in a slot until the main loop takes it and sends it.
 * Text from the Mac is written on the worker too; the change count that write
 * produced is remembered, so the worker does not send the Mac its own text back.
 *
 * Text is limited to TB_CLIPBOARD_MAX_TEXT - 1 bytes (cut at a character
 * boundary), as upstream's 4096-byte buffer did.
 */

#ifndef TB_CLIPBOARD_H
#define TB_CLIPBOARD_H

#include <stddef.h>

#define TB_CLIPBOARD_MAX_TEXT     4096   /* bytes, with the terminating NUL */
#define TB_CLIPBOARD_POLL_MS       100   /* as upstream */
#define TB_CLIPBOARD_SLOW_READ_MS 1000   /* a read this slow is logged */

struct tb_clipboard;

/* Start the worker. `name`: NULL for the system clipboard (the general
 * pasteboard); "" for a private pasteboard of this process; anything else
 * for the pasteboard of that name. Tests never pass NULL. NULL if the worker
 * could not start; every call below accepts NULL and does nothing. */
struct tb_clipboard *tb_clipboard_create(const char *name);

/* Main loop: look for new text while `on` (receiverMaster with a sender
 * connected). Turning it off drops text not yet taken. */
void tb_clipboard_set_polling(struct tb_clipboard *c, int on);

/* Main loop: a session started or ended. The Mac's copy of the clipboard is
 * unknown again, so the next poll sends the current text if it is not empty
 * (upstream behaviour). PWE (1.1.1, R1): the Mac's text queued and not yet
 * written is dropped; one already being written finishes, but is never sent
 * to the next session's Mac as the iMac's text. */
void tb_clipboard_new_session(struct tb_clipboard *c);

/* Main loop: put the Mac's text on the iMac's clipboard. Returns at once;
 * only the latest text waits if the worker is busy. PWE (1.1.1, R1): it
 * belongs to the session it was queued in, and is not written over a copy
 * made on the iMac after the worker last looked. */
void tb_clipboard_write(struct tb_clipboard *c, const char *text);

/* Main loop: 1 and the text when the iMac's clipboard has text the Mac does
 * not have yet; 0 otherwise. Never waits on the pasteboard. */
int  tb_clipboard_take(struct tb_clipboard *c, char *dest, size_t size);

/* At exit: stop the worker, waiting at most `wait_ms`. 1 when it finished.
 * 0 when it is still waiting for the pasteboard and was left behind: the
 * caller should end the process with _exit(). */
int  tb_clipboard_destroy(struct tb_clipboard *c, unsigned wait_ms);

#endif
