#ifndef SNOW_LEOPARD_MENU_BAR_PROTOCOL_H
#define SNOW_LEOPARD_MENU_BAR_PROTOCOL_H

// Shared in-process identifiers/layout values used by more than one Unified
// module. Keep feature-specific implementation details in their owner module.
#define SL_TOP_LEVEL_POPUP_ANCHOR_NOTIFICATION \
    @"com.snowleopardmenubar.TopLevelPopupAnchorDidChange"
#define SL_SPOTLIGHT_RIGHT_MARGIN_ANCHOR_IDENTIFIER \
    @"SnowLeopardRightMarginAnchor"
#define SL_SPOTLIGHT_RIGHT_MARGIN_WINDOW_TITLE \
    @"SnowLeopardRightMargin"

#define SL_SPOTLIGHT_RIGHT_MARGIN_LENGTH 18.0
#define SL_SPOTLIGHT_RUNTIME_PREFERRED_POSITION 53.0f
#define SL_CLOCK_RUNTIME_PREFERRED_POSITION 218.0f

#endif
