// Provenance:
// Button component adapted from https://github.com/dps/remarkable-wikipedia (MIT)
// Copyright (c) 2019 David Singleton

import QtQuick

Item {
    id: root
    clip: true
    property string text: ""
    property string color: "black"
    property string backgroundColor: "transparent"
    property string borderColor: "black"
    property string selectedColor: "transparent"
    property string selectedBackgroundColor: "black"
    property string selectedBorderColor: "transparent"
    property int transitionTime: 150
    property int fontsize: 10
    property int borderwidth: 3
    property bool toggle: false

    signal click()
    signal hold()
    signal release()

    property bool isSelected: false
    property bool isHeld: false

    Rectangle {
        id: background
        anchors.fill: root
        color: root.backgroundColor
        border.color: root.borderColor
        border.width: root.borderwidth

        Text {
            id: label
            color: root.color
            text: root.text
            anchors.centerIn: parent
            font.pointSize: root.fontsize
        }
    }

    Timer {
        id: timer
        interval: root.transitionTime
        repeat: false
        onTriggered: {
            root.isSelected = false;
        }
    }

    MouseArea {
        anchors.fill: root
        hoverEnabled: false
        onClicked: {
            if (root.toggle) {
                root.isSelected = !root.isSelected;
            } else {
                root.isSelected = true;
                timer.start();
            }
            root.click();
        }
        onPressAndHold: {
            root.isSelected = true;
            root.isHeld = true;
            root.hold();
        }
        onReleased: {
            if (root.isSelected) {
                if (root.isHeld) {
                    root.isSelected = false;
                    root.isHeld = false;
                }
                root.release();
            }
        }
    }

    state: "resting"
    states: [
        State { name: "resting"; when: !root.isSelected },
        State { name: "pressed"; when: root.isSelected }
    ]
    transitions: [
        Transition {
            from: "resting"
            to: "pressed"
            PropertyAction { target: label; property: "color"; value: root.selectedColor }
            PropertyAction { target: background; property: "color"; value: root.selectedBackgroundColor }
            PropertyAction { target: background; property: "border.color"; value: root.selectedBorderColor }
        },
        Transition {
            from: "pressed"
            to: "resting"
            PropertyAction { target: label; property: "color"; value: root.color }
            PropertyAction { target: background; property: "color"; value: root.backgroundColor }
            PropertyAction { target: background; property: "border.color"; value: root.borderColor }
        }
    ]
}
