/* tb_login_item.h — open the Receiver at login, so an iMac used as a display is
 * waiting for its Mac as soon as it starts.
 *
 * macOS 13 and later register the app with SMAppService (it then appears in
 * System Settings > Login Items). macOS 11 and 12 use a per-user LaunchAgent.
 * Everything here works only when running from an .app bundle.
 */

#ifndef TB_LOGIN_ITEM_H
#define TB_LOGIN_ITEM_H

/* 1 when the Receiver opens at login. */
int  tb_login_item_is_enabled(void);

/* Turn opening at login on or off. Returns 1 on success. */
int  tb_login_item_set_enabled(int enabled);

/* Ask once, with a native dialog, whether to open at login. Does nothing if it
 * was asked before, if it is already on, or outside an app bundle. Call on the
 * main thread after the display is created. */
void tb_login_item_offer_once(void);

#endif
