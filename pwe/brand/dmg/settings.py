# dmgbuild settings for the PWE Screen Encore disk image (pwe/package.sh runs it).
#
#   dmgbuild -s pwe/brand/dmg/settings.py -D stage=<dir> -D icon=<AppIcon.icns> \
#            -D background=pwe/brand/dmg/background.png "<volume name>" <out.dmg>
#
# <stage> holds the two apps, the read-me and Licenses. The window is 640 x 520 pt
# with background.png and, next to it, background@2x.png (pwe/brand/make.py draws
# them; dmgbuild joins the pair into one HiDPI TIFF). The icon centres below must
# match ICONS in make.py, or the pictures and the icons drift apart. No Finder window is opened: dmgbuild writes .DS_Store directly.
import os.path

stage = defines["stage"]   # noqa: F821 (dmgbuild provides `defines`)

SENDER = "PWE Screen Encore.app"
RECEIVER = "PWE Screen Encore Receiver.app"
README = "读我 Read Me First.txt"
LICENCES = "Licenses"

format = "UDZO"
filesystem = "HFS+"
files = [os.path.join(stage, name) for name in (SENDER, RECEIVER, README, LICENCES)]
symlinks = {"Applications": "/Applications"}
icon = defines["icon"]   # noqa: F821  the volume's icon on the desktop: the app's own
# Only the read-me. The hide-extension flag is a com.apple.FinderInfo attribute, and
# on an app bundle it breaks the signature (codesign: "Finder information … not
# allowed"; seen 2026-10-20). Finder hides ".app" by default anyway.
hide_extensions = [README]

background = defines["background"]   # noqa: F821
window_rect = ((200, 120), (640, 520))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
show_icon_preview = False
include_icon_view_settings = True
include_list_view_settings = False
arrange_by = None
grid_spacing = 100
label_pos = "bottom"
text_size = 12
icon_size = 80
icon_locations = {
    SENDER: (150, 190),
    "Applications": (330, 190),
    RECEIVER: (530, 190),
    README: (150, 322),
    LICENCES: (330, 322),
}
