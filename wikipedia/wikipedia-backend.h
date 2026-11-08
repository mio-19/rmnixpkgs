// Provenance:
// Integrated libzim C++ backend for reMarkable Paper Pro (ferrari)
// Base concept from https://github.com/dps/remarkable-wikipedia (MIT)
// Copyright (c) 2019 David Singleton
// libzim integration: https://github.com/openzim/libzim (GPL-2.0-or-later)

#pragma once

#include <QObject>
#include <QString>
#include <QStringList>
#include <QVariantList>
#include <memory>

namespace zim {
class Archive;
class SuggestionSearcher;
class Entry;
}

class WikipediaBackend : public QObject
{
    Q_OBJECT
    Q_PROPERTY(bool hasArchive READ hasArchive NOTIFY archiveChanged)
    Q_PROPERTY(QString archiveTitle READ archiveTitle NOTIFY archiveChanged)
    Q_PROPERTY(QString mainPage READ mainPage NOTIFY archiveChanged)
    Q_PROPERTY(QString archivePath READ archivePath NOTIFY archiveChanged)

public:
    explicit WikipediaBackend(QObject *parent = nullptr);
    ~WikipediaBackend() override;

    bool hasArchive() const;
    QString archiveTitle() const { return m_archiveTitle; }
    QString mainPage() const { return m_mainPage; }
    QString archivePath() const { return m_archivePath; }

    Q_INVOKABLE bool openArchive(const QString &path);
    Q_INVOKABLE bool autoOpen(const QString &preferredDir = QString());
    Q_INVOKABLE QStringList availableArchives(const QString &searchDir = QString());

    Q_INVOKABLE QString getArticleHtml(const QString &pathOrTitle);
    Q_INVOKABLE QVariantList getSuggestions(const QString &query, int limit = 8);

signals:
    void archiveChanged();

private:
    std::unique_ptr<zim::Archive> m_archive;
    std::unique_ptr<zim::SuggestionSearcher> m_searcher;
    QString m_archiveTitle;
    QString m_mainPage;
    QString m_archivePath;

    zim::Entry findEntry(const QString &query);
    QString cleanHtmlForEpaper(const QString &rawHtml);
};
