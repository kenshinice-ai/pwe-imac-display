/* tb_pairing_menu.h — PWE: the receiver's pairing items in its app menu.
 *
 *   Allow Unencrypted Connections   (a check mark; one click turns it off)
 *   Forget All Paired Macs…          (asks first)
 *
 * Call after the SDL window exists (SDL builds the menu bar). The callbacks
 * run on the main thread, from the event loop. */

#ifndef TB_PAIRING_MENU_H
#define TB_PAIRING_MENU_H

typedef void (*tb_pairing_menu_cb)(void *ctx);

void tb_pairing_menu_install(tb_pairing_menu_cb on_toggle_unencrypted,
                             tb_pairing_menu_cb on_forget_all,
                             void *ctx);
/* Titles (localised) and the check mark; call again after a language change. */
void tb_pairing_menu_update(const char *allow_title, int allow_on, const char *forget_title);
/* A modal question. Returns 1 when the first button was chosen. */
int  tb_pairing_menu_confirm(const char *message, const char *confirm, const char *cancel);

#endif
