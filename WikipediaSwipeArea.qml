// Provenance:
// Swipe gesture recognizer for QML
// Public domain by Sergejs Kovrovs: https://gist.github.com/kovrov/1742405
// Adapted for reMarkable Paper Pro Wikipedia reader

import QtQuick

MouseArea {
    property point origin
    property bool ready: false
    signal move(int x, int y)
    signal swipe(string direction)

    onPressed: (mouse) => {
        drag.axis = Drag.XAndYAxis;
        origin = Qt.point(mouse.x, mouse.y);
        mouse.accepted = true;
    }

    onPositionChanged: (mouse) => {
        switch (drag.axis) {
            case Drag.XAndYAxis:
                if (Math.abs(mouse.x - origin.x) > 24) {
                    drag.axis = Drag.XAxis;
                } else if (Math.abs(mouse.y - origin.y) > 24) {
                    drag.axis = Drag.YAxis;
                }
                break;
            case Drag.XAxis:
                move(mouse.x - origin.x, 0);
                break;
            case Drag.YAxis:
                move(0, mouse.y - origin.y);
                break;
        }
        mouse.accepted = true;
    }

    onReleased: (mouse) => {
        switch (drag.axis) {
            case Drag.XAndYAxis:
                break;
            case Drag.XAxis:
                swipe(mouse.x - origin.x < 0 ? "left" : "right");
                break;
            case Drag.YAxis:
                swipe(mouse.y - origin.y < 0 ? "up" : "down");
                break;
        }
        mouse.accepted = true;
    }
}
