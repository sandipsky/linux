// Shelly's design tokens (data/css/tokens.css), with the lock screen's larger type (D256),
// and the Tabler glyphs the lock screen uses.

import QtQuick

QtObject {
    readonly property color surface: "#0B0B0E"
    readonly property color surfaceContainer: "#17171C"
    readonly property color surfaceContainerHigh: "#1E1E24"
    readonly property color outlineVariant: "#2A2A33"
    readonly property color textMain: "#ECECF1"
    readonly property color textDim: "#9C9CA8"
    readonly property color primary: "#F7E9A8"
    readonly property color secondary: "#B3B8ED"
    readonly property color error: "#ED8296"
    readonly property color textOnError: "#3B2029"
    readonly property color focusRing: secondary

    readonly property real stateHover: 0.08
    readonly property real statePressed: 0.14
    readonly property real disabledOpacity: 0.4

    readonly property int space1: 4
    readonly property int space2: 8
    readonly property int space3: 12
    readonly property int space4: 16
    readonly property int space6: 24

    readonly property int radiusMd: 8
    readonly property int radiusLg: 12

    readonly property int fontCaption: 14
    readonly property int fontBody: 16
    readonly property int weightRegular: 400
    readonly property int weightMedium: 500
    readonly property int weightSemibold: 600

    readonly property int iconSmall: 14
    readonly property int iconPanel: 18
    readonly property int iconLarge: 24

    readonly property int controlHeight: 32
    readonly property int controlHeightLarge: 40
    readonly property int textfieldLargeFont: 16
    readonly property int textfieldLargeIcon: 20

    readonly property int lockAvatar: 128
    readonly property int lockAvatarGlyph: 56
    readonly property int lockNameSize: 32
    readonly property int lockFieldWidth: 280
    readonly property int lockShake: 8

    readonly property int motionHover: 120
    readonly property int motionShake: 360
    // cubic-bezier(0.2, 0, 0, 1)
    readonly property var ease: [0.2, 0, 0, 1, 1, 1]

    readonly property string glyphUser: ""
    readonly property string glyphLock: ""
    readonly property string glyphSuspend: ""   // player-pause
    readonly property string glyphReboot: ""    // refresh
    readonly property string glyphShutdown: ""  // power
    readonly property string glyphSession: ""   // settings
    readonly property string glyphCheck: ""
}
