/* tb_running_app.h — the other copy of this app that is already running
 * (PWE 1.1.1).
 *
 * Only one receiver can listen on the port. When a second copy starts (from
 * a disk image next to the installed one, or `open -n`), it tells the user and
 * brings the running copy to the front instead of failing in silence.
 */

#ifndef TB_RUNNING_APP_H
#define TB_RUNNING_APP_H

/* Bring the running application with this bundle identifier, other than this
 * process, to the front. 1 when one was found, 0 when none is running (or
 * this build is not in a bundle). Never launches anything. */
int tb_running_app_activate(const char *bundle_id);

#endif
