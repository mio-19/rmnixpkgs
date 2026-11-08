// Provenance:
// reMarkable Wikipedia application entry point
// Upstream concept: https://github.com/dps/remarkable-wikipedia (MIT)
// Copyright (c) 2019 David Singleton
// Enhanced with native libzim backend for reMarkable Paper Pro (ferrari)

#include <QGuiApplication>
#include <QQmlApplicationEngine>
#include <QQmlContext>
#include <QQuickWindow>
#include <QDebug>

#include "wikipedia-backend.h"

int main(int argc, char *argv[])
{
    // Avoid hardware-accelerated offscreen requirements on e-paper framebuffers
    qputenv("QT_QUICK_BACKEND", "software");

    QGuiApplication app(argc, argv);
    app.setOrganizationName("rmpp");
    app.setOrganizationDomain("rmpp.wikipedia");
    app.setApplicationName("rmpp-wikipedia");
    app.setApplicationDisplayName("Wikipedia");

    WikipediaBackend backend;
    if (argc > 1) {
        backend.openArchive(QString::fromUtf8(argv[1]));
    } else {
        backend.autoOpen();
    }

    QQmlApplicationEngine engine;
    engine.rootContext()->setContextProperty("zimBackend", &backend);
    engine.load(QUrl(QStringLiteral("qrc:/wikipedia-main.qml")));

    if (engine.rootObjects().isEmpty()) {
        qCritical() << "[rmpp-wikipedia] Failed to load root QML object";
        return -1;
    }

    return app.exec();
}
