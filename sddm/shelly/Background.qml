// Shelly's lock background: the picture cropped to fill, three rounds of horizontal then
// vertical Gaussian blur at radius = intensity * 40 device pixels, then the tint colour
// over it (GlRenderer::draw_backdrop). The same shader, so the same picture.

import QtQuick
import QtQuick.Window

Item {
    id: root

    property url source
    property color fill: "#0B0B0E"
    property real blurIntensity: 0.5
    property color tint: "#0B0B0E"
    property real tintIntensity: 0.3

    readonly property real blurRadius: Math.min(blurIntensity * 40, 40)
    readonly property bool blurred: blurRadius >= 0.5 && last.status !== ShaderEffect.Error
    // Screen pixels per unit of this item.
    property real ratio: 1
    readonly property size pixels: Qt.size(Math.max(1, Math.ceil(width * ratio)), Math.max(1, Math.ceil(height * ratio)))
    readonly property vector2d texel: Qt.vector2d(1 / pixels.width, 1 / pixels.height)

    component Texture: ShaderEffectSource {
        anchors.fill: parent
        visible: false
        textureSize: root.pixels
    }

    component Pass: ShaderEffect {
        property var source
        property real radius: root.blurRadius
        property vector2d texelSize: root.texel
        property vector2d direction
        anchors.fill: parent
        visible: false
        fragmentShader: Qt.resolvedUrl("shaders/blur.frag.qsb")
    }

    Rectangle {
        id: picture
        anchors.fill: parent
        color: root.fill
        visible: !root.blurred
        Image {
            anchors.fill: parent
            source: root.source
            fillMode: Image.PreserveAspectCrop
            asynchronous: true
            smooth: true
            mipmap: true
        }
    }

    Texture { id: t0; sourceItem: picture }
    Pass { id: h1; source: t0; direction: Qt.vector2d(1, 0) }
    Texture { id: t1; sourceItem: h1 }
    Pass { id: v1; source: t1; direction: Qt.vector2d(0, 1) }
    Texture { id: t2; sourceItem: v1 }
    Pass { id: h2; source: t2; direction: Qt.vector2d(1, 0) }
    Texture { id: t3; sourceItem: h2 }
    Pass { id: v2; source: t3; direction: Qt.vector2d(0, 1) }
    Texture { id: t4; sourceItem: v2 }
    Pass { id: h3; source: t4; direction: Qt.vector2d(1, 0) }
    Texture { id: t5; sourceItem: h3 }
    Pass { id: last; source: t5; direction: Qt.vector2d(0, 1); visible: root.blurred }

    Rectangle {
        anchors.fill: parent
        color: root.tint
        opacity: root.tintIntensity
        visible: root.tintIntensity > 0.001
    }
}
