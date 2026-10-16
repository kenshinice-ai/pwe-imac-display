/* tb_login_item.h — open the Receiver at login, so an iMac used as a display is
 * waiting for its Mac as soon as it starts.
 *
 * macOS 13 and later register the app with SMAppService (it then appears in
 * System Settings > Login Items). macOS 11 and 12 use a per-user LaunchAgent
 * that asks Launch Services to open the app by its bundle identifier, so it
 * keeps working after the app is moved.
 * Everything here works only when running from an .app bundle, and not from a
 * copy that will be gone at the next login (a disk image, App Translocation).
 */

#ifndef TB_LOGIN_ITEM_H
#define TB_LOGIN_ITEM_H

/* 1 when the Receiver opens at login. */
int  tb_login_item_is_enabled(void);

/* 1 when this copy can be opened at login: it runs from an .app bundle that is
 * not on a disk image or a translocated path. */
int  tb_login_item_available(void);

/* Turn opening at login on or off. Returns 1 on success. Turning it on fails
 * when tb_login_item_available() is 0. */
int  tb_login_item_set_enabled(int enabled);

/* Bring a registration made by an earlier build or macOS up to date: on 13+,
 * replace a LaunchAgent left from macOS 11/12 with SMAppService; on 11/12,
 * rewrite an agent that names the executable path. Call once at startup. */
void tb_login_item_migrate(void);

/* Ask once, with a native dialog, whether to open at login. Does nothing if it
 * was asked before, if it is already on, or if this copy is not available
 * (then it is asked again once the app runs from Applications). Call on the
 * main thread once the idle screen is showing. */
void tb_login_item_offer_once(void);

#endif
