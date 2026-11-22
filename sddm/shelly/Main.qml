// The Sign-in step of the Shelly lock screen (src/ui/lock/lock_window.cpp, data/css/lock.css)
// as an SDDM greeter: the blurred, tinted wallpaper, the circular photo, the name, the
// password field, the feedback line and the session actions, with Shelly's tokens.
//
// One thing the lock screen does not have: a button at the bottom right that opens a menu
// of the installed sessions. It shows only when there is more than one to choose from.

import QtQml
import QtQuick
import QtQuick.Effects
import QtQuick.Window

Rectangle {
    id: root

    Tokens { id: t }
    FontLoader { id: tabler; source: Qt.resolvedUrl("fonts/tabler.ttf") }

    readonly property string iconFont: tabler.name
    readonly property string textFont: setting("font", "sans-serif")

    // ---- theme.conf ---------------------------------------------------------------------

    function setting(key, fallback) {
        const value = typeof config !== "undefined" && config ? config[key] : undefined
        return value === undefined || value === null || String(value) === "" ? fallback : String(value)
    }
    function numberSetting(key, fallback) {
        const value = parseFloat(setting(key, ""))
        return isNaN(value) ? fallback : Math.max(0, Math.min(1, value))
    }
    function fileUrl(path) {
        if (path === "") {
            return ""
        }
        return path.startsWith("/") ? "file://" + path : Qt.resolvedUrl(path)
    }

    readonly property bool allowEmptyPassword: setting("allowEmptyPassword", "false") === "true"

    // ---- Users and sessions -------------------------------------------------------------

    Instantiator {
        id: users
        model: userModel
        delegate: QtObject {
            readonly property string name: model.name
            readonly property string realName: model.realName || ""
            readonly property string icon: model.icon || ""
        }
    }
    Instantiator {
        id: sessions
        model: sessionModel
        delegate: QtObject {
            readonly property string name: model.name
        }
    }

    property int userIndex: Math.max(0, userModel.lastIndex)
    property int sessionIndex: Math.max(0, sessionModel.lastIndex)

    readonly property var user: users.count > 0 ? users.objectAt(Math.min(userIndex, users.count - 1)) : null
    readonly property string userName: user ? user.name : userModel.lastUser
    readonly property string displayName: user && user.realName !== "" ? user.realName : userName
    // SDDM hands out its stock face for a user without a photo; Shelly shows the glyph then.
    readonly property string photo: user && !/\/faces\/\.face\.icon$/.test(user.icon) ? user.icon : ""

    // ---- The feedback line (lock::status_line) -------------------------------------------

    property bool busy: false
    property string message: ""
    property bool messageIsError: false
    readonly property bool capsLock: typeof keyboard !== "undefined" && keyboard ? keyboard.capsLock : false

    readonly property bool statusIsError: (messageIsError && message !== "") || capsLock
    readonly property string statusText: messageIsError && message !== "" ? message
                                       : capsLock ? "Caps Lock is on"
                                       : busy && message === "" ? "Authenticating…"
                                       : message !== "" ? message
                                       : "Type your password and press Enter."

    function submit() {
        if (busy || (password.text.length === 0 && !allowEmptyPassword)) {
            return
        }
        message = ""
        messageIsError = false
        busy = true
        sddm.login(userName, password.text, sessionIndex)
    }

    Connections {
        target: sddm
        ignoreUnknownSignals: true
        function onLoginFailed() {
            root.busy = false
            password.text = ""
            if (!(root.messageIsError && root.message !== "")) {
                root.message = "Authentication failure"
                root.messageIsError = true
            }
            shake.restart()
            password.forceActiveFocus()
        }
        function onInformationMessage(message) {
            root.message = message
            root.messageIsError = true
        }
    }

    // Text typed while a button has the focus goes to the password, as on the lock screen.
    Keys.onPressed: (event) => {
        if (menu.visible || event.text.length === 0) {
            return
        }
        const code = event.text.charCodeAt(0)
        if (code < 32 || code === 127 || (event.modifiers & (Qt.ControlModifier | Qt.AltModifier | Qt.MetaModifier))) {
            return
        }
        password.forceActiveFocus()
        if (!busy) {
            password.insert(password.length, event.text)
            message = ""
        }
        event.accepted = true
    }

    color: t.surface

    // Shelly is a GTK program: it draws in the screen's own pixels, whatever Qt's scale factor
    // says (QT_SCALE_FACTOR, the X server's DPI). So everything here is laid out in a stage
    // that undoes Qt's factor; "scale" in theme.conf then enlarges it for a HiDPI screen,
    // as the compositor's monitor scale does for the lock screen.
    readonly property real uiScale: {
        const value = parseFloat(setting("scale", "1"))
        return isNaN(value) || value <= 0 ? 1 : value
    }
    readonly property real stageFactor: uiScale / Screen.devicePixelRatio

    Item {
        id: stage
        width: root.width / root.stageFactor
        height: root.height / root.stageFactor
        scale: root.stageFactor
        transformOrigin: Item.TopLeft

        Background {
            anchors.fill: parent
            source: root.fileUrl(root.setting("background", ""))
            fill: root.setting("fillColor", t.surface)
            blurIntensity: root.numberSetting("blurIntensity", 0.5)
            tint: root.setting("tintColor", t.surface)
            tintIntensity: root.numberSetting("tintIntensity", 0.3)
            ratio: root.uiScale
        }

        // ---- Sign-in --------------------------------------------------------------------------

        Column {
            id: signIn
            anchors.centerIn: parent
            spacing: t.space3

            // A circular photo, or the user glyph on a container fill (LOCK-05).
            Rectangle {
                id: avatar
                anchors.horizontalCenter: parent.horizontalCenter
                width: t.lockAvatar
                height: t.lockAvatar
                radius: width / 2
                color: t.surfaceContainerHigh

                readonly property bool hasPhoto: root.photo !== "" && picture.status === Image.Ready

                Text {
                    anchors.centerIn: parent
                    visible: !avatar.hasPhoto
                    text: t.glyphUser
                    font.family: root.iconFont
                    font.pixelSize: t.lockAvatarGlyph
                    color: t.textDim
                }
                Image {
                    id: picture
                    anchors.fill: parent
                    source: root.photo
                    sourceSize: Qt.size(t.lockAvatar * 2, t.lockAvatar * 2)
                    fillMode: Image.PreserveAspectCrop
                    asynchronous: true
                    visible: false
                }
                Rectangle {
                    id: circle
                    anchors.fill: parent
                    radius: width / 2
                    visible: false
                    layer.enabled: true
                }
                MultiEffect {
                    anchors.fill: parent
                    source: picture
                    maskEnabled: true
                    maskSource: circle
                    maskThresholdMin: 0.5
                    maskSpreadAtMin: 1.0
                    visible: avatar.hasPhoto
                }
                // More than one account: a click takes the next one.
                MouseArea {
                    anchors.fill: parent
                    enabled: users.count > 1 && !root.busy
                    cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
                    onClicked: {
                        root.userIndex = (root.userIndex + 1) % users.count
                        password.text = ""
                        root.message = ""
                        password.forceActiveFocus()
                    }
                }
            }

            Item {
                anchors.horizontalCenter: parent.horizontalCenter
                width: name.width
                height: name.height + t.space2
                Text {
                    id: name
                    width: Math.min(implicitWidth, stage.width - 2 * t.space6)
                    text: root.displayName
                    elide: Text.ElideRight
                    font.family: root.textFont
                    font.pixelSize: t.lockNameSize
                    font.weight: t.weightSemibold
                    color: t.textMain
                }
            }

            // The large text field: 40 high, padding 0 12, a lock glyph, radius 8.
            Item {
                id: field
                anchors.horizontalCenter: parent.horizontalCenter
                width: t.lockFieldWidth
                height: t.controlHeightLarge
                opacity: root.busy ? t.disabledOpacity : 1
                transform: Translate { id: shift }

                // The focus ring: the border plus one more pixel outside it.
                Rectangle {
                    anchors.fill: parent
                    anchors.margins: -1
                    radius: t.radiusMd + 1
                    color: "transparent"
                    border.width: 1
                    border.color: t.focusRing
                    opacity: password.activeFocus ? 1 : 0
                    Behavior on opacity {
                        NumberAnimation { duration: t.motionHover; easing.type: Easing.BezierSpline; easing.bezierCurve: t.ease }
                    }
                }
                Rectangle {
                    anchors.fill: parent
                    radius: t.radiusMd
                    color: fieldHover.hovered ? t.surfaceContainerHigh : t.surfaceContainer
                    border.width: 1
                    border.color: password.activeFocus ? t.focusRing : t.outlineVariant
                    Behavior on border.color {
                        ColorAnimation { duration: t.motionHover; easing.type: Easing.BezierSpline; easing.bezierCurve: t.ease }
                    }
                }
                HoverHandler { id: fieldHover; cursorShape: Qt.IBeamCursor }

                Text {
                    id: lockGlyph
                    x: t.space3 + 1
                    anchors.verticalCenter: parent.verticalCenter
                    text: t.glyphLock
                    font.family: root.iconFont
                    font.pixelSize: t.textfieldLargeIcon
                    color: t.textDim
                }
                TextInput {
                    id: password
                    anchors.left: lockGlyph.right
                    anchors.leftMargin: t.space2
                    anchors.right: parent.right
                    anchors.rightMargin: t.space3 + 1
                    anchors.top: parent.top
                    anchors.bottom: parent.bottom
                    verticalAlignment: TextInput.AlignVCenter
                    clip: true
                    focus: true
                    readOnly: root.busy
                    echoMode: TextInput.Password
                    passwordCharacter: "●"
                    inputMethodHints: Qt.ImhSensitiveData | Qt.ImhNoPredictiveText | Qt.ImhNoAutoUppercase
                    font.family: root.textFont
                    font.pixelSize: t.textfieldLargeFont
                    color: t.textMain
                    selectionColor: Qt.rgba(t.secondary.r, t.secondary.g, t.secondary.b, 0.35)
                    selectedTextColor: t.textMain
                    KeyNavigation.tab: suspend
                    onTextEdited: {
                        root.message = ""
                        root.messageIsError = false
                    }
                    onAccepted: root.submit()
                    // LOCK-04: Escape empties the field.
                    Keys.onEscapePressed: {
                        if (text.length > 0 && !root.busy) {
                            text = ""
                            root.message = "Password cleared"
                            root.messageIsError = false
                        }
                    }

                    Text {
                        anchors.fill: parent
                        verticalAlignment: Text.AlignVCenter
                        visible: password.text.length === 0 && password.preeditText.length === 0
                        text: "Password"
                        font: password.font
                        color: t.textDim
                    }
                }

                // LOCK-06: a wrong password shakes the field.
                SequentialAnimation {
                    id: shake
                    readonly property int step: t.motionShake / 5
                    NumberAnimation { target: shift; property: "x"; to: -t.lockShake; duration: shake.step; easing.type: Easing.BezierSpline; easing.bezierCurve: t.ease }
                    NumberAnimation { target: shift; property: "x"; to: t.lockShake; duration: shake.step; easing.type: Easing.BezierSpline; easing.bezierCurve: t.ease }
                    NumberAnimation { target: shift; property: "x"; to: -t.lockShake / 2; duration: shake.step; easing.type: Easing.BezierSpline; easing.bezierCurve: t.ease }
                    NumberAnimation { target: shift; property: "x"; to: t.lockShake / 2; duration: shake.step; easing.type: Easing.BezierSpline; easing.bezierCurve: t.ease }
                    NumberAnimation { target: shift; property: "x"; to: 0; duration: shake.step; easing.type: Easing.BezierSpline; easing.bezierCurve: t.ease }
                }
            }

            // The feedback line keeps its height whether or not it says anything.
            Text {
                anchors.horizontalCenter: parent.horizontalCenter
                width: Math.min(implicitWidth, stage.width - 2 * t.space6)
                height: Math.max(Math.round(t.fontCaption * 1.5), implicitHeight)
                verticalAlignment: Text.AlignVCenter
                elide: Text.ElideRight
                text: root.statusText
                font.family: root.textFont
                font.pixelSize: t.fontCaption
                color: root.statusIsError ? t.error : t.textDim
            }

            Item {
                anchors.horizontalCenter: parent.horizontalCenter
                width: actions.width
                height: actions.height + t.space4
                Row {
                    id: actions
                    anchors.bottom: parent.bottom
                    spacing: t.space2

                    ActionButton {
                        id: suspend
                        tokens: t; iconFont: root.iconFont; textFont: root.textFont
                        glyph: t.glyphSuspend
                        label: "Suspend"
                        enabled: sddm.canSuspend
                        KeyNavigation.tab: reboot
                        KeyNavigation.backtab: password
                        onClicked: sddm.suspend()
                    }
                    ActionButton {
                        id: reboot
                        tokens: t; iconFont: root.iconFont; textFont: root.textFont
                        glyph: t.glyphReboot
                        label: "Reboot"
                        enabled: sddm.canReboot
                        KeyNavigation.tab: shutdown
                        KeyNavigation.backtab: suspend
                        onClicked: sddm.reboot()
                    }
                    ActionButton {
                        id: shutdown
                        tokens: t; iconFont: root.iconFont; textFont: root.textFont
                        glyph: t.glyphShutdown
                        label: "Shut down"
                        destructive: true
                        enabled: sddm.canPowerOff
                        KeyNavigation.tab: sessionButton.visible ? sessionButton : password
                        KeyNavigation.backtab: reboot
                        onClicked: sddm.powerOff()
                    }
                }
            }
        }

        // ---- The session menu -------------------------------------------------------------------

        // Shelly's large icon button: 40 square, radius 8, a 24 px glyph.
        Item {
            id: sessionButton
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            anchors.margins: t.space6
            width: t.controlHeightLarge
            height: t.controlHeightLarge
            visible: sessions.count > 1
            activeFocusOnTab: true
            KeyNavigation.tab: password
            KeyNavigation.backtab: shutdown

            readonly property bool lit: sessionMouse.containsMouse || menu.visible

            Keys.onReturnPressed: menu.open(true)
            Keys.onEnterPressed: menu.open(true)
            Keys.onSpacePressed: menu.open(true)

            Rectangle {
                anchors.fill: parent
                anchors.margins: -4
                radius: t.radiusMd + 4
                color: "transparent"
                border.width: 2
                border.color: t.focusRing
                visible: sessionButton.activeFocus
            }
            Rectangle {
                anchors.fill: parent
                radius: t.radiusMd
                color: Qt.rgba(t.textMain.r, t.textMain.g, t.textMain.b,
                               sessionMouse.pressed || menu.visible ? t.statePressed
                               : sessionMouse.containsMouse ? t.stateHover : 0)
                Behavior on color {
                    ColorAnimation { duration: t.motionHover; easing.type: Easing.BezierSpline; easing.bezierCurve: t.ease }
                }
            }
            Text {
                anchors.centerIn: parent
                text: t.glyphSession
                font.family: root.iconFont
                font.pixelSize: t.iconLarge
                color: sessionButton.lit ? t.textMain : t.textDim
                Behavior on color {
                    ColorAnimation { duration: t.motionHover; easing.type: Easing.BezierSpline; easing.bezierCurve: t.ease }
                }
            }
            MouseArea {
                id: sessionMouse
                anchors.fill: parent
                hoverEnabled: true
                onClicked: menu.visible ? menu.close() : menu.open(false)
            }
        }

        // A click anywhere else closes the menu.
        MouseArea {
            anchors.fill: parent
            visible: menu.visible
            hoverEnabled: true
            acceptedButtons: Qt.AllButtons
            onPressed: menu.close()
        }

        // Shelly's dropdown menu: surface, border, radius 12, the one shadow, rows 32 high with
        // a check on the chosen one.
        FocusScope {
            id: menu
            visible: false
            anchors.right: sessionButton.right
            anchors.bottom: sessionButton.top
            anchors.bottomMargin: t.space1
            width: rows.width + 2 * (t.space1 + 1)
            height: rows.height + 2 * (t.space1 + 1)

            property int cursor: 0
            property bool byKeyboard: false
            property real labelWidth: 0

            function open(keyboard) {
                cursor = root.sessionIndex
                byKeyboard = keyboard
                visible = true
                forceActiveFocus()
            }
            function close() {
                visible = false
                password.forceActiveFocus()
            }
            function choose(index) {
                root.sessionIndex = index
                close()
            }

            Keys.onEscapePressed: close()
            Keys.onUpPressed: { byKeyboard = true; cursor = (cursor + sessions.count - 1) % sessions.count }
            Keys.onDownPressed: { byKeyboard = true; cursor = (cursor + 1) % sessions.count }
            Keys.onReturnPressed: choose(cursor)
            Keys.onEnterPressed: choose(cursor)
            Keys.onSpacePressed: choose(cursor)
            Keys.onTabPressed: close()
            Keys.onBacktabPressed: close()

            RectangularShadow {
                anchors.fill: panel
                offset: Qt.vector2d(0, 8)
                blur: 24
                radius: panel.radius
                color: Qt.rgba(0, 0, 0, 0.45)
            }
            Rectangle {
                id: panel
                anchors.fill: parent
                radius: t.radiusLg
                color: t.surface
                border.width: 1
                border.color: t.outlineVariant
            }
            // No click falls through the menu's padding.
            MouseArea { anchors.fill: parent; acceptedButtons: Qt.AllButtons }

            Column {
                id: rows
                x: t.space1 + 1
                y: t.space1 + 1
                width: Math.max(128, menu.labelWidth + 3 * t.space2 + t.iconSmall)

                Repeater {
                    model: sessionModel
                    delegate: Rectangle {
                        id: row
                        required property int index
                        required property string name
                        width: rows.width
                        height: t.controlHeight
                        radius: t.radiusMd
                        color: rowMouse.pressed ? t.surfaceContainerHigh
                             : rowMouse.containsMouse ? t.surfaceContainer
                             : "transparent"
                        Behavior on color {
                            ColorAnimation { duration: t.motionHover; easing.type: Easing.BezierSpline; easing.bezierCurve: t.ease }
                        }

                        Rectangle {
                            anchors.fill: parent
                            radius: parent.radius
                            color: "transparent"
                            border.width: 2
                            border.color: t.focusRing
                            visible: menu.byKeyboard && menu.cursor === row.index
                        }
                        Text {
                            id: label
                            x: t.space2
                            anchors.verticalCenter: parent.verticalCenter
                            text: row.name
                            font.family: root.textFont
                            font.pixelSize: t.fontBody
                            color: t.textMain
                            onImplicitWidthChanged: menu.labelWidth = Math.max(menu.labelWidth, implicitWidth)
                            Component.onCompleted: menu.labelWidth = Math.max(menu.labelWidth, implicitWidth)
                        }
                        Text {
                            anchors.right: parent.right
                            anchors.rightMargin: t.space2
                            anchors.verticalCenter: parent.verticalCenter
                            text: t.glyphCheck
                            font.family: root.iconFont
                            font.pixelSize: t.iconSmall
                            color: t.primary
                            opacity: root.sessionIndex === row.index ? 1 : 0
                        }
                        MouseArea {
                            id: rowMouse
                            anchors.fill: parent
                            hoverEnabled: true
                            onClicked: menu.choose(row.index)
                        }
                    }
                }
            }
        }
    }

    Component.onCompleted: password.forceActiveFocus()
}
