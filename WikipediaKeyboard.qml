// Provenance:
// On-screen touch keyboard adapted from https://github.com/Eeems/oxidize (MIT)
// Copyright (c) 2019 Nathaniel van Diepen
// Adapted for reMarkable Paper Pro Wikipedia reader

import QtQuick
import "."

Item {
    id: keyboard
    objectName: "keyboard"
    clip: true
    anchors.bottom: parent.bottom
    anchors.left: parent.left
    anchors.right: parent.right
    height: 520

    property int page: 0
    property bool hasCaps: false
    property bool hasShift: false
    property bool hasAlt: false
    property bool hasCtrl: false
    property bool hasMeta: false

    signal characterEntered(string text)
    signal actionRequested(string action)

    function charPress(text, modifiers) {
        characterEntered(text);
    }

    function stringPress(text, modifiers) {
        characterEntered(text);
    }

    function keyPress(key, modifiers, val) {
        if (key === Qt.Key_Backspace) {
            actionRequested("key-del");
        } else if (key === Qt.Key_Space) {
            characterEntered(" ");
        } else if (key === Qt.Key_Return || key === Qt.Key_Enter) {
            actionRequested("key-enter");
        }
    }

    function hide() {
        keyboard.visible = false;
    }

    function caps(state) {
        keyboard.hasCaps = state;
        keyboard.hasShift = state;
    }

    function shift(state) {
        keyboard.hasShift = state;
    }

    function ctrl(state) {
        keyboard.hasCtrl = state;
    }

    function alt(state) {
        keyboard.hasAlt = state;
    }

    function meta(state) {
        keyboard.hasMeta = state;
    }

    MouseArea {
        anchors.fill: parent
    }

    Rectangle {
        color: "#1a1a1a"
        anchors.fill: parent

        Column {
            id: qwerty
            anchors.centerIn: parent
            spacing: 6

            // Row 1: Numbers & Symbols
            Row {
                spacing: parent.spacing
                anchors.horizontalCenter: parent.horizontalCenter
                WikipediaKeyboardKey { text: "`"; shifttext: "~" }
                WikipediaKeyboardKey { text: "1"; shifttext: "!" }
                WikipediaKeyboardKey { text: "2"; shifttext: "@" }
                WikipediaKeyboardKey { text: "3"; shifttext: "#" }
                WikipediaKeyboardKey { text: "4"; shifttext: "$" }
                WikipediaKeyboardKey { text: "5"; shifttext: "%" }
                WikipediaKeyboardKey { text: "6"; shifttext: "^" }
                WikipediaKeyboardKey { text: "7"; shifttext: "&" }
                WikipediaKeyboardKey { text: "8"; shifttext: "*" }
                WikipediaKeyboardKey { text: "9"; shifttext: "(" }
                WikipediaKeyboardKey { text: "0"; shifttext: ")" }
                WikipediaKeyboardKey { text: "-"; shifttext: "_" }
                WikipediaKeyboardKey { text: "="; shifttext: "+" }
                WikipediaKeyboardKey { text: "⌫"; size: 1.8; key: Qt.Key_Backspace; fontsize: 12 }
            }

            // Row 2: QWERTY
            Row {
                spacing: parent.spacing
                anchors.horizontalCenter: parent.horizontalCenter
                WikipediaKeyboardKey { text: "Tab"; size: 1.4; key: Qt.Key_Tab; fontsize: 9 }
                WikipediaKeyboardKey { text: "q"; shifttext: "Q" }
                WikipediaKeyboardKey { text: "w"; shifttext: "W" }
                WikipediaKeyboardKey { text: "e"; shifttext: "E" }
                WikipediaKeyboardKey { text: "r"; shifttext: "R" }
                WikipediaKeyboardKey { text: "t"; shifttext: "T" }
                WikipediaKeyboardKey { text: "y"; shifttext: "Y" }
                WikipediaKeyboardKey { text: "u"; shifttext: "U" }
                WikipediaKeyboardKey { text: "i"; shifttext: "I" }
                WikipediaKeyboardKey { text: "o"; shifttext: "O" }
                WikipediaKeyboardKey { text: "p"; shifttext: "P" }
                WikipediaKeyboardKey { text: "["; shifttext: "{" }
                WikipediaKeyboardKey { text: "]"; shifttext: "}" }
                WikipediaKeyboardKey { text: "\\"; shifttext: "|"; size: 1.4 }
            }

            // Row 3: ASDF
            Row {
                spacing: parent.spacing
                anchors.horizontalCenter: parent.horizontalCenter
                WikipediaKeyboardKey { id: capsKey; text: "Caps"; key: Qt.Key_CapsLock; size: 1.8; onClick: keyboard.caps(this.state()); toggle: true; fontsize: 9 }
                WikipediaKeyboardKey { text: "a"; shifttext: "A" }
                WikipediaKeyboardKey { text: "s"; shifttext: "S" }
                WikipediaKeyboardKey { text: "d"; shifttext: "D" }
                WikipediaKeyboardKey { text: "f"; shifttext: "F" }
                WikipediaKeyboardKey { text: "g"; shifttext: "G" }
                WikipediaKeyboardKey { text: "h"; shifttext: "H" }
                WikipediaKeyboardKey { text: "j"; shifttext: "J" }
                WikipediaKeyboardKey { text: "k"; shifttext: "K" }
                WikipediaKeyboardKey { text: "l"; shifttext: "L" }
                WikipediaKeyboardKey { text: ";"; shifttext: ":" }
                WikipediaKeyboardKey { text: "'"; shifttext: "\"" }
                WikipediaKeyboardKey { text: "Enter"; size: 2.0; key: Qt.Key_Return; fontsize: 10 }
            }

            // Row 4: ZXCV
            Row {
                spacing: parent.spacing
                anchors.horizontalCenter: parent.horizontalCenter
                WikipediaKeyboardKey { id: lshift; text: "Shift"; key: Qt.Key_Shift; size: 2.3; onClick: keyboard.shift(this.state()); toggle: true; fontsize: 9 }
                WikipediaKeyboardKey { text: "z"; shifttext: "Z" }
                WikipediaKeyboardKey { text: "x"; shifttext: "X" }
                WikipediaKeyboardKey { text: "c"; shifttext: "C" }
                WikipediaKeyboardKey { text: "v"; shifttext: "V" }
                WikipediaKeyboardKey { text: "b"; shifttext: "B" }
                WikipediaKeyboardKey { text: "n"; shifttext: "N" }
                WikipediaKeyboardKey { text: "m"; shifttext: "M" }
                WikipediaKeyboardKey { text: ","; shifttext: "<" }
                WikipediaKeyboardKey { text: "."; shifttext: ">" }
                WikipediaKeyboardKey { text: "/"; shifttext: "?" }
                WikipediaKeyboardKey { id: rshift; text: "Shift"; key: Qt.Key_Shift; size: 2.3; onClick: keyboard.shift(this.state()); toggle: true; fontsize: 9 }
            }

            // Row 5: Space & Controls
            Row {
                spacing: parent.spacing
                anchors.horizontalCenter: parent.horizontalCenter
                WikipediaKeyboardKey { text: "Hide"; size: 2.0; key: 0; onClick: keyboard.hide(); fontsize: 9 }
                WikipediaKeyboardKey { text: "Space"; size: 8.0; key: Qt.Key_Space; value: " " }
                WikipediaKeyboardKey { text: "Clear"; size: 2.0; key: 0; onClick: keyboard.actionRequested("key-clear"); fontsize: 9 }
            }
        }
    }
}
