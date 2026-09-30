import QtQuick

// Mirror of the F108 Pro's 240x135 LCD dashboard: date, battery, clock and the
// status tiles. Everything is laid out in LCD pixels (u) and scales to width.
Item {
    id: screen

    property int battery: -1
    property string connection: "dongle" // usb | dongle | bt
    property bool capsLock: false
    property bool numLock: false
    property bool running: true
    property string iconFont: "monospace"
    property date now: new Date()

    readonly property real u: width / 240
    readonly property string lcdFont: "Nimbus Sans Narrow"
    readonly property string clockFont: "Liberation Sans"

    implicitHeight: width * 135 / 240

    Timer {
        interval: 1000
        repeat: true
        running: screen.running
        triggeredOnStart: true
        onTriggered: screen.now = new Date()
    }

    Rectangle {
        anchors.fill: parent
        radius: 10 * screen.u
        color: "#050807"
        border.width: Math.max(1, screen.u)
        border.color: "#1c1f1e"
        clip: true

        // The glass glare across the left of the real panel.
        Rectangle {
            width: parent.width * 0.5
            height: parent.height * 2
            x: -parent.width * 0.28
            y: -parent.height * 0.5
            rotation: 18
            gradient: Gradient {
                orientation: Gradient.Horizontal
                GradientStop { position: 0.0; color: Qt.rgba(1, 1, 1, 0.10) }
                GradientStop { position: 1.0; color: Qt.rgba(1, 1, 1, 0.02) }
            }
        }
    }

    // ---------- Top row: date · battery ----------
    Text {
        x: 22 * screen.u
        anchors.verticalCenter: parent.top
        anchors.verticalCenterOffset: 23 * screen.u
        text: Qt.formatDate(screen.now, "yyyy/MM/dd")
        color: "#6F8FAE"
        font.family: screen.lcdFont
        font.pixelSize: 17 * screen.u
    }

    Row {
        anchors.right: parent.right
        anchors.rightMargin: 20 * screen.u
        anchors.verticalCenter: parent.top
        anchors.verticalCenterOffset: 23 * screen.u
        spacing: 2 * screen.u

        Text {
            anchors.verticalCenter: parent.verticalCenter
            text: screen.battery >= 0 ? screen.battery + "%" : "--%"
            color: "#8FB6E0"
            font.family: screen.lcdFont
            font.pixelSize: 17 * screen.u
        }

        Item {
            anchors.verticalCenter: parent.verticalCenter
            width: 32 * screen.u
            height: 15 * screen.u

            Rectangle {
                id: cell
                width: parent.width - 3 * screen.u
                height: parent.height
                radius: 3 * screen.u
                color: "transparent"
                border.width: 1.6 * screen.u
                border.color: "#5FB8E8"

                Row {
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.leftMargin: 3 * screen.u
                    spacing: 1.2 * screen.u

                    Repeater {
                        model: 5

                        Rectangle {
                            required property int index
                            width: 3.4 * screen.u
                            height: cell.height - 6 * screen.u
                            color: screen.battery <= 20 ? "#E8503A" : "#5BE83A"
                            visible: screen.battery > index * 20
                        }
                    }
                }
            }

            Rectangle {
                anchors.left: cell.right
                anchors.verticalCenter: cell.verticalCenter
                width: 2.4 * screen.u
                height: 6 * screen.u
                color: "#5FB8E8"
            }
        }
    }

    // ---------- Clock ----------
    Text {
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.verticalCenter: parent.top
        anchors.verticalCenterOffset: 65 * screen.u
        text: Qt.formatTime(screen.now, "HH:mm:ss")
        color: "#E6E6E6"
        font.family: screen.clockFont
        font.pixelSize: 29 * screen.u
        font.letterSpacing: 3 * screen.u
    }

    // ---------- Status tiles ----------
    Row {
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.verticalCenter: parent.top
        anchors.verticalCenterOffset: 107 * screen.u
        spacing: 3.5 * screen.u

        Tile { label: "WIN"; accent: "#3E9BE0"; on: true; small: true }
        Tile { glyph: "󰕓"; accent: "#9B5CE0"; on: screen.connection === "usb" }
        Tile { glyph: "󱇰"; accent: "#7BD83A"; on: screen.connection === "dongle" }
        Tile { label: "BT1"; accent: "#4CC3E8"; on: screen.connection === "bt"; small: true }
        // Windows-key lock is keyboard-local state the host cannot read.
        Tile { glyph: "󰌾"; accent: "#E8D54A"; on: false }
        Tile { label: "A"; accent: "#E8D54A"; on: screen.capsLock }
        Tile { label: "1"; accent: "#E8D54A"; on: screen.numLock }
    }

    component Tile: Rectangle {
        property string label: ""
        property string glyph: ""
        property color accent: "white"
        property bool on: false
        property bool small: false

        width: 26 * screen.u
        height: 25 * screen.u
        radius: 3 * screen.u
        color: Qt.rgba(accent.r, accent.g, accent.b, 0.16)
        border.width: 1.6 * screen.u
        border.color: accent
        opacity: on ? 1 : 0.2

        Behavior on opacity { NumberAnimation { duration: 150 } }

        Text {
            anchors.centerIn: parent
            text: parent.glyph !== "" ? parent.glyph : parent.label
            color: parent.accent
            font.family: parent.glyph !== "" ? screen.iconFont : screen.lcdFont
            font.pixelSize: (parent.small ? 11 : 19) * screen.u
            font.bold: true
        }
    }
}
