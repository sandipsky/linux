// Shelly's Button (.shelly-button): 32 high, padding 0 12, a 1 px border, radius 8, a
// glyph and a label 8 apart. Default or Destructive.

import QtQuick

Item {
    id: root

    property var tokens
    property string iconFont
    property string textFont
    property string glyph
    property string label
    property bool destructive: false
    signal clicked()

    implicitWidth: content.implicitWidth + 2 * (tokens.space3 + 1)
    implicitHeight: tokens.controlHeight
    opacity: enabled ? 1 : tokens.disabledOpacity
    activeFocusOnTab: true

    Keys.onReturnPressed: clicked()
    Keys.onEnterPressed: clicked()
    Keys.onSpacePressed: clicked()

    // :focus-visible, an outline 2 px wide and 2 px away.
    Rectangle {
        anchors.fill: parent
        anchors.margins: -4
        radius: tokens.radiusMd + 4
        color: "transparent"
        border.width: 2
        border.color: tokens.focusRing
        visible: root.activeFocus
    }

    Rectangle {
        id: face
        anchors.fill: parent
        radius: tokens.radiusMd
        border.width: 1
        border.color: root.destructive ? tokens.error : tokens.outlineVariant
        color: root.destructive ? tokens.error
             : mouse.pressed ? tokens.outlineVariant
             : mouse.containsMouse ? tokens.surfaceContainerHigh
             : tokens.surfaceContainer
        Behavior on color {
            ColorAnimation { duration: tokens.motionHover; easing.type: Easing.BezierSpline; easing.bezierCurve: tokens.ease }
        }

        // Filled buttons react with a layer of their own text colour.
        Rectangle {
            anchors.fill: parent
            radius: parent.radius
            color: tokens.textOnError
            visible: root.destructive
            opacity: mouse.pressed ? tokens.statePressed : mouse.containsMouse ? tokens.stateHover : 0
        }
    }

    Row {
        id: content
        anchors.centerIn: parent
        spacing: tokens.space2
        Text {
            anchors.verticalCenter: parent.verticalCenter
            text: root.glyph
            font.family: root.iconFont
            font.pixelSize: tokens.iconPanel
            color: root.destructive ? tokens.textOnError : tokens.textMain
        }
        Text {
            anchors.verticalCenter: parent.verticalCenter
            text: root.label
            font.family: root.textFont
            font.pixelSize: tokens.fontBody
            font.weight: tokens.weightMedium
            color: root.destructive ? tokens.textOnError : tokens.textMain
        }
    }

    MouseArea {
        id: mouse
        anchors.fill: parent
        hoverEnabled: true
        onClicked: root.clicked()
    }
}
