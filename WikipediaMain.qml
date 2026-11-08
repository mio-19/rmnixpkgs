// Provenance:
// Native Wikipedia reader for reMarkable Paper Pro (ferrari)
// Base design adapted from https://github.com/dps/remarkable-wikipedia (MIT)
// Copyright (c) 2019 David Singleton
// Direct libzim C++ backend integration to eliminate kiwix-serve HTTP daemon.

import QtQuick
import QtQuick.Window
import "."

Window {
    id: appWindow
    visible: true
    title: qsTr("Wikipedia")
    width: 1620
    height: 2160
    color: "white"

    property string currentTitle: ""
    property var backStack: []
    property int scrollOffset: 120
    property int pageStep: 1800

    Component.onCompleted: {
        onLoad();
    }

    function onLoad() {
        if (zimBackend.hasArchive) {
            var home = zimBackend.mainPage;
            if (home && home.length > 0) {
                navigateTo(home);
            } else {
                navigateTo("Main_Page");
            }
        } else {
            log.text = zimBackend.getArticleHtml("");
        }
    }

    function navigateTo(target) {
        if (!target || target.length === 0) return;

        // Skip internal page anchors or external http links for now
        if (target.startsWith("#")) {
            return;
        }

        var clean = target;
        if (clean.startsWith("./")) {
            clean = clean.substring(2);
        }
        if (clean.startsWith("/")) {
            clean = clean.substring(1);
        }

        // Update back stack
        if (backStack.length === 0 || backStack[backStack.length - 1] !== clean) {
            backStack.push(clean);
        }

        currentTitle = clean;
        queryInput.text = clean;
        scrollOffset = 120;
        log.y = scrollOffset;

        log.text = "<h1>Loading article...</h1>";
        var content = zimBackend.getArticleHtml(clean);
        showArticle(content);
        keyboard.hide();
    }

    function navigateBack() {
        if (backStack.length > 1) {
            backStack.pop(); // Remove current
            var prev = backStack.pop(); // Pop target, navigateTo will re-push it
            navigateTo(prev);
        }
    }

    function showArticle(htmlText) {
        scrollOffset = 120;
        log.y = scrollOffset;
        log.text = htmlText;
    }

    function pageDown() {
        scrollOffset -= pageStep;
        log.y = scrollOffset;
    }

    function pageUp() {
        scrollOffset = Math.min(120, scrollOffset + pageStep);
        log.y = scrollOffset;
    }

    function refreshSuggestions() {
        var q = queryInput.text.trim();
        if (q.length < 2) {
            return;
        }
        var suggestions = zimBackend.getSuggestions(q, 8);
        var html = "<h2>Search Suggestions:</h2>";
        if (suggestions.length === 0) {
            html += "<p><i>No articles matching '" + q + "'</i></p>";
        } else {
            for (var i = 0; i < suggestions.length; ++i) {
                var item = suggestions[i];
                html += "<p style='margin-bottom: 24px;'><a href='" + item.path + "' style='font-size: 26px; color: black; font-weight: bold;'>";
                html += item.title;
                html += "</a>";
                if (item.snippet && item.snippet.length > 0) {
                    html += "<br/><span style='color: #444; font-size: 18px;'>" + item.snippet + "</span>";
                }
                html += "</p>";
            }
        }
        showArticle(html);
    }

    // Hardware / Swipe Area
    WikipediaSwipeArea {
        anchors.fill: parent
        propagateComposedEvents: true
        onSwipe: (direction) => {
            if (direction === "up") {
                pageDown();
            } else if (direction === "down") {
                pageUp();
            }
        }
    }

    // Main Article Content
    Rectangle {
        id: contentContainer
        anchors.fill: parent
        color: "white"

        Text {
            id: log
            y: 120
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.margins: 40
            text: "<h1>reMarkable Wikipedia</h1>"
            textFormat: Text.RichText
            wrapMode: Text.Wrap
            font.pointSize: 15
            color: "black"
            onLinkActivated: (link) => navigateTo(link)
        }
    }

    // Top Navigation Bar
    Rectangle {
        id: topBar
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        height: 110
        color: "#ffffff"
        border.color: "#333333"
        border.width: 2

        Row {
            anchors.fill: parent
            anchors.margins: 10
            spacing: 12

            // Back Button
            Rectangle {
                width: 90
                height: 90
                border.color: "black"
                border.width: 3
                radius: 12
                color: backStack.length > 1 ? "#ffffff" : "#f0f0f0"

                Text {
                    text: "⬅"
                    font.pointSize: 22
                    anchors.centerIn: parent
                    color: backStack.length > 1 ? "black" : "#888888"
                }

                MouseArea {
                    anchors.fill: parent
                    onClicked: navigateBack()
                }
            }

            // Search / Title Input Field
            Rectangle {
                width: parent.width - 90 - 90 - 90 - (12 * 4)
                height: 90
                border.color: "black"
                border.width: 3
                radius: 12
                color: "white"
                clip: true

                TextInput {
                    id: queryInput
                    anchors.fill: parent
                    anchors.margins: 15
                    verticalAlignment: TextInput.AlignVCenter
                    font.pointSize: 16
                    color: "black"
                    selectByMouse: true

                    onTextEdited: {
                        refreshSuggestions();
                    }

                    onAccepted: {
                        navigateTo(queryInput.text);
                    }
                }
            }

            // Home Button
            Rectangle {
                width: 90
                height: 90
                border.color: "black"
                border.width: 3
                radius: 12
                color: "white"

                Text {
                    text: "🏠"
                    font.pointSize: 22
                    anchors.centerIn: parent
                }

                MouseArea {
                    anchors.fill: parent
                    onClicked: {
                        var home = zimBackend.mainPage;
                        navigateTo(home && home.length > 0 ? home : "Main_Page");
                    }
                }
            }

            // Keyboard Toggle Button
            Rectangle {
                width: 90
                height: 90
                border.color: "black"
                border.width: 3
                radius: 12
                color: keyboard.visible ? "#000000" : "#ffffff"

                Text {
                    text: "⌨"
                    font.pointSize: 22
                    anchors.centerIn: parent
                    color: keyboard.visible ? "white" : "black"
                }

                MouseArea {
                    anchors.fill: parent
                    onClicked: {
                        keyboard.visible = !keyboard.visible;
                        if (keyboard.visible) {
                            queryInput.forceActiveFocus();
                        }
                    }
                }
            }
        }
    }

    // Floating Page Up / Page Down Buttons
    Column {
        anchors.right: parent.right
        anchors.bottom: keyboard.visible ? keyboard.top : parent.bottom
        anchors.margins: 24
        spacing: 16
        z: 10

        Rectangle {
            width: 100
            height: 100
            radius: 50
            color: "white"
            border.color: "black"
            border.width: 4

            Text {
                text: "▲"
                font.pointSize: 24
                anchors.centerIn: parent
                color: "black"
            }

            MouseArea {
                anchors.fill: parent
                onClicked: pageUp()
            }
        }

        Rectangle {
            width: 100
            height: 100
            radius: 50
            color: "white"
            border.color: "black"
            border.width: 4

            Text {
                text: "▼"
                font.pointSize: 24
                anchors.centerIn: parent
                color: "black"
            }

            MouseArea {
                anchors.fill: parent
                onClicked: pageDown()
            }
        }
    }

    // On-Screen Keyboard
    WikipediaKeyboard {
        id: keyboard
        visible: false
        z: 20

        onCharacterEntered: (ch) => {
            queryInput.text += ch;
            refreshSuggestions();
        }

        onActionRequested: (action) => {
            if (action === "key-del") {
                if (queryInput.text.length > 0) {
                    queryInput.text = queryInput.text.substring(0, queryInput.text.length - 1);
                    refreshSuggestions();
                }
            } else if (action === "key-enter") {
                navigateTo(queryInput.text);
            } else if (action === "key-clear") {
                queryInput.text = "";
                showArticle("<h2>Start typing to search...</h2>");
            }
        }
    }
}
