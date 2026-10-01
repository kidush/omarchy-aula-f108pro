import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Alma F108 Pro: battery, clock sync and backlight over the 2.4G dongle.
// All hardware access and the saved light state live in keyboard.sh.
Panel {
    id: root
    moduleName: "kidush.aula-f108pro"
    ipcTarget: "kidush.aula-f108pro"
    // Owns the IpcHandler so keybinds can reach setColor/setMode, not just open/close.
    manageIpc: false

    readonly property string runner: decodeURIComponent(String(Qt.resolvedUrl("keyboard.sh")).replace(/^file:\/\//, ""))
    property int battery: -1
    property string connection: "dongle" // usb | dongle, from almactl info
    property string status: "Verificando teclado…"
    property string syncStatus: ""
    property string operation: "info"

    readonly property var swatches: [
        "FF0000", "FF5500", "FFAA00", "FFFF00", "55FF00", "00FF55",
        "00FFFF", "0088FF", "0000FF", "8800FF", "FF00FF", "FFFFFF"
    ]
    readonly property var modes: [
        { value: "static", label: "Fixo" },
        { value: "breathing", label: "Respirar" },
        { value: "cycle", label: "Arco-íris" },
        { value: "off", label: "Desligado" }
    ]

    property bool capsLock: false
    property bool numLock: false

    property var light: ({ color: "FF0000", mode: "static", brightness: 100, followTheme: false, themeColor: "", effectiveColor: "FF0000" })
    property var pendingLight: ({})
    readonly property color lightColor: "#" + (light.effectiveColor || "FF0000")
    readonly property bool lit: light.mode !== "off"

    function run(action) {
        if (request.running) return
        operation = action
        request.command = ["bash", runner, action]
        request.running = true
    }

    function connectionLabel() {
        // Over the cable the keyboard reports no battery (it is charging).
        return connection === "usb" ? "Conectado por cabo USB" : "Conectado pelo dongle 2.4G"
    }

    function modeLabel(value) {
        for (var i = 0; i < modes.length; i++) if (modes[i].value === value) return modes[i].label
        return value
    }

    function hex(c) {
        return String(c).replace("#", "").slice(-6).toUpperCase()
    }

    // Updates the UI at once; changes made while the dongle is still busy are
    // merged into a single keyboard.sh call.
    function changeLight(values) {
        var next = Object.assign({}, light, values)
        if (values.color !== undefined) {
            next.followTheme = false
            next.effectiveColor = values.color
        }
        if (values.followTheme === true && light.themeColor) next.effectiveColor = hex(light.themeColor)
        if (values.followTheme === false && values.color === undefined) next.effectiveColor = light.color
        light = next

        pendingLight = Object.assign({}, pendingLight, values)
        if (!lightSet.running) flushLight()
    }

    function flushLight() {
        var keys = Object.keys(pendingLight)
        if (keys.length === 0) return
        var cmd = ["bash", runner, "light", "set"]
        keys.forEach(function(k) { cmd.push(k, String(pendingLight[k])) })
        pendingLight = {}
        lightSet.command = cmd
        lightSet.running = true
    }

    function loadLight(raw) {
        try {
            var parsed = JSON.parse(raw)
            if (parsed && parsed.mode) light = parsed
        } catch (e) {}
    }

    Component.onCompleted: {
        run("info")
        lightGet.running = true
    }
    onOpenedChanged: if (opened) {
        run("info")
        if (!lightSet.running) lightGet.running = true
    }
    implicitWidth: button.implicitWidth
    implicitHeight: button.implicitHeight

    IpcHandler {
        target: "kidush.aula-f108pro"

        function open(): void { root.open() }
        function close(): void { root.close() }
        function show(): void { root.open() }
        function hide(): void { root.close() }
        function toggle(): void { root.toggle() }
        function setColor(color: string): void { root.changeLight({ color: root.hex(color) }) }
        function setMode(mode: string): void { root.changeLight({ mode: mode }) }
        function setBrightness(value: int): void { root.changeLight({ brightness: value }) }
        function toggleLight(): void { root.changeLight({ mode: root.light.mode === "off" ? "static" : "off" }) }
        function state(): string { return JSON.stringify({ battery: root.battery, status: root.status, light: root.light }) }
    }

    // One process serializes polling and clock sync for this widget.
    Process {
        id: request
        stdout: StdioCollector { id: output }
        stderr: StdioCollector { id: errors }
        onExited: function(code) {
            if (code !== 0) {
                root.battery = -1
                root.status = errors.text.trim().replace(/^almactl: /, "") || "Teclado indisponível"
                if (root.operation === "sync-time") root.syncStatus = "Falha ao sincronizar o relógio"
                return
            }
            if (root.operation === "info") {
                const link = output.text.match(/^connection\s+(\S+)/m)
                const match = output.text.match(/^battery\s+(\d+)%/m)
                root.connection = link && link[1] === "usb" ? "usb" : "dongle"
                root.battery = match ? Number(match[1]) : -1
                root.status = root.connectionLabel()
            } else {
                root.syncStatus = output.text.trim().replace(/^clock set to/, "Relógio ajustado para")
                root.status = root.connectionLabel()
            }
        }
    }

    Process {
        id: lightGet
        command: ["bash", root.runner, "light", "get"]
        stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.loadLight(text) }
    }

    Process {
        id: lightSet
        stdout: StdioCollector {
            waitForEnd: true
            onStreamFinished: if (Object.keys(root.pendingLight).length === 0) root.loadLight(text)
        }
        onExited: root.flushLight()
    }

    // Caps/Num Lock for the screen tiles, read from Hyprland while the panel is open.
    Process {
        id: locks
        command: ["hyprctl", "devices", "-j"]
        stdout: StdioCollector {
            waitForEnd: true
            onStreamFinished: {
                try {
                    const kbs = JSON.parse(text).keyboards || []
                    const kb = kbs.find(k => k.name.startsWith("f108pro-dongle")) || kbs.find(k => k.main)
                    if (kb) {
                        root.capsLock = kb.capsLock === true
                        root.numLock = kb.numLock === true
                    }
                } catch (e) {}
            }
        }
    }

    Timer {
        interval: 500
        repeat: true
        running: root.opened
        triggeredOnStart: true
        onTriggered: if (!locks.running) locks.running = true
    }

    Timer {
        interval: 60000
        repeat: true
        running: true
        onTriggered: root.run("info")
    }

    BarIconButton {
        id: button
        anchors.fill: parent
        bar: root.bar
        text: "󰌌"
        tooltipText: root.battery >= 0 ? "F108 Pro · " + root.battery + "%"
            : (root.connection === "usb" ? "F108 Pro · cabo USB" : "F108 Pro · indisponível")
        onPressed: function(b) {
            if (b === Qt.RightButton) root.changeLight({ mode: root.light.mode === "off" ? "static" : "off" })
            else root.toggle()
        }
    }

    KeyboardPanel {
        id: popup
        anchorItem: button
        owner: root
        bar: root.bar
        open: root.opened
        focusTarget: keys
        contentWidth: popup.fittedContentWidth(Style.space(380))
        contentHeight: popup.fittedContentHeight(column.implicitHeight)

        PanelKeyCatcher {
            id: keys
            anchors.fill: parent
            onCloseRequested: root.close()
            onTabRequested: function(direction) { root.switchPanel(direction) }

            Column {
                id: column
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: parent.top
                spacing: Style.space(14)

                // ---------- Mirror of the keyboard's LCD dashboard ----------
                KeyboardScreen {
                    width: parent.width
                    height: implicitHeight
                    battery: root.battery
                    connection: root.connection
                    capsLock: root.capsLock
                    numLock: root.numLock
                    running: root.opened
                    iconFont: root.bar.fontFamily
                }

                Text {
                    width: parent.width
                    textFormat: Text.PlainText
                    text: ("F108 Pro · " + (request.running && root.operation === "info" ? "Verificando…" : root.status)).toUpperCase()
                    color: Qt.darker(root.bar.foreground, 1.4)
                    font.family: root.bar.fontFamily
                    font.pixelSize: Style.font.caption
                    font.bold: true
                    font.letterSpacing: 1.2
                    elide: Text.ElideRight
                    horizontalAlignment: Text.AlignHCenter
                }

                // ---------- Color ----------
                PanelSeparator { foreground: root.bar.foreground }

                Column {
                    width: parent.width
                    spacing: Style.space(10)

                    PanelSectionHeader {
                        text: "COR · #" + root.light.effectiveColor
                        foreground: root.bar.foreground
                        fontFamily: root.bar.fontFamily
                    }

                    Grid {
                        id: swatchGrid
                        width: parent.width
                        columns: 6
                        spacing: Style.space(6)

                        readonly property real cell: (width - spacing * (columns - 1)) / columns

                        Repeater {
                            model: root.swatches

                            Rectangle {
                                required property string modelData
                                readonly property bool selected: !root.light.followTheme && root.light.effectiveColor === modelData
                                width: swatchGrid.cell
                                height: Style.space(26)
                                radius: Style.cornerRadius > 0 ? Style.space(4) : 0
                                color: "#" + modelData
                                // A faint border keeps white visible on light themes.
                                border.width: selected || swatchMouse.containsMouse ? 2 : 1
                                border.color: selected || swatchMouse.containsMouse
                                    ? root.bar.foreground
                                    : Qt.rgba(root.bar.foreground.r, root.bar.foreground.g, root.bar.foreground.b, 0.15)

                                Text {
                                    visible: parent.selected
                                    anchors.centerIn: parent
                                    text: "󰄬"
                                    color: parent.color.hslLightness > 0.6 ? "#000000" : "#FFFFFF"
                                    font.family: root.bar.fontFamily
                                    font.pixelSize: Style.font.title
                                }

                                MouseArea {
                                    id: swatchMouse
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: root.changeLight({ color: modelData })
                                }
                            }
                        }
                    }

                    // Free hue: dragging previews the knob, releasing applies it.
                    Item {
                        width: parent.width
                        height: Style.space(22)

                        Rectangle {
                            anchors.left: parent.left
                            anchors.right: parent.right
                            anchors.verticalCenter: parent.verticalCenter
                            anchors.leftMargin: Style.space(6)
                            anchors.rightMargin: Style.space(6)
                            height: Style.space(6)
                            radius: height / 2
                            gradient: Gradient {
                                orientation: Gradient.Horizontal
                                GradientStop { position: 0.0; color: "#FF0000" }
                                GradientStop { position: 0.17; color: "#FFFF00" }
                                GradientStop { position: 0.33; color: "#00FF00" }
                                GradientStop { position: 0.5; color: "#00FFFF" }
                                GradientStop { position: 0.67; color: "#0000FF" }
                                GradientStop { position: 0.83; color: "#FF00FF" }
                                GradientStop { position: 1.0; color: "#FF0000" }
                            }
                        }

                        PanelSlider {
                            bar: root.bar
                            anchors.fill: parent
                            anchors.leftMargin: Style.space(6)
                            anchors.rightMargin: Style.space(6)
                            minimum: 0
                            maximum: 359
                            step: 1
                            integer: true
                            trackColor: "transparent"
                            fillColor: "transparent"
                            knobColor: dragging ? Qt.hsva(liveValue / 360, 1, 1, 1) : root.bar.foreground
                            value: root.lightColor.hsvHue >= 0 ? Math.round(root.lightColor.hsvHue * 360) : 0
                            onReleased: function(v) { root.changeLight({ color: root.hex(Qt.hsva(v / 360, 1, 1, 1)) }) }
                        }
                    }

                    Row {
                        width: parent.width
                        spacing: Style.space(10)

                        TextField {
                            id: hexField
                            width: Style.space(120)
                            text: "#" + root.light.effectiveColor
                            placeholderText: "#RRGGBB"
                            font.family: root.bar.fontFamily
                            foreground: root.bar.foreground
                            validator: RegularExpressionValidator { regularExpression: /#?[0-9A-Fa-f]{0,6}/ }
                            onAccepted: {
                                var v = text.replace("#", "")
                                if (v.length === 6) root.changeLight({ color: v.toUpperCase() })
                            }
                        }

                        Button {
                            width: parent.width - hexField.width - parent.spacing
                            height: hexField.height
                            text: root.light.themeColor ? "Cor do tema" : "Tema sem cor"
                            iconText: "󰏘"
                            fontSize: Style.font.bodySmall
                            foreground: root.bar.foreground
                            fontFamily: root.bar.fontFamily
                            bordered: true
                            active: root.light.followTheme === true
                            tooltipText: "Acompanha a cor de destaque ao trocar de tema"
                            onClicked: root.changeLight({ followTheme: !root.light.followTheme })
                        }
                    }
                }

                // ---------- Brightness ----------
                PanelSeparator { foreground: root.bar.foreground }

                Column {
                    width: parent.width
                    spacing: Style.space(10)

                    PanelSectionHeader {
                        text: "BRILHO · " + Math.round(brightnessSlider.liveValue) + "%"
                        foreground: root.bar.foreground
                        fontFamily: root.bar.fontFamily
                    }

                    PanelSlider {
                        id: brightnessSlider
                        bar: root.bar
                        width: parent.width
                        // The keyboard only has 5 brightness levels.
                        minimum: 20
                        maximum: 100
                        step: 20
                        integer: true
                        value: root.light.brightness
                        onReleased: function(v) { root.changeLight({ brightness: Math.round(v) }) }
                    }
                }

                // ---------- Effect ----------
                PanelSeparator { foreground: root.bar.foreground }

                Column {
                    width: parent.width
                    spacing: Style.space(10)

                    PanelSectionHeader {
                        text: "EFEITO"
                        foreground: root.bar.foreground
                        fontFamily: root.bar.fontFamily
                    }

                    Row {
                        id: modeRow
                        width: parent.width
                        spacing: Style.space(6)

                        readonly property real cellWidth: (width - spacing * (root.modes.length - 1)) / root.modes.length

                        Repeater {
                            model: root.modes

                            Button {
                                required property var modelData
                                width: modeRow.cellWidth
                                text: modelData.label
                                fontSize: Style.font.bodySmall
                                foreground: root.bar.foreground
                                fontFamily: root.bar.fontFamily
                                verticalPadding: Style.spacing.controlPaddingY + Style.space(2)
                                bordered: true
                                active: root.light.mode === modelData.value
                                onClicked: root.changeLight({ mode: modelData.value })
                            }
                        }
                    }
                }

                // ---------- Device ----------
                PanelSeparator { foreground: root.bar.foreground }

                Row {
                    width: parent.width
                    spacing: Style.space(8)

                    Button {
                        width: (parent.width - parent.spacing) / 2
                        iconText: "󰑐"
                        text: "Atualizar"
                        fontSize: Style.font.bodySmall
                        bordered: true
                        enabled: !request.running
                        foreground: root.bar.foreground
                        fontFamily: root.bar.fontFamily
                        onClicked: root.run("info")
                    }

                    Button {
                        width: (parent.width - parent.spacing) / 2
                        iconText: "󰥔"
                        text: request.running && root.operation === "sync-time" ? "Sincronizando…" : "Sincronizar relógio"
                        fontSize: Style.font.bodySmall
                        bordered: true
                        enabled: !request.running
                        foreground: root.bar.foreground
                        fontFamily: root.bar.fontFamily
                        onClicked: root.run("sync-time")
                    }
                }

                Text {
                    width: parent.width
                    visible: root.syncStatus !== ""
                    text: root.syncStatus
                    textFormat: Text.PlainText
                    wrapMode: Text.Wrap
                    color: root.bar.foreground
                    font.family: root.bar.fontFamily
                    font.pixelSize: Style.font.bodySmall
                    opacity: 0.7
                }
            }
        }
    }
}
