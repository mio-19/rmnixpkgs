// Provenance:
// Integrated libzim C++ backend for reMarkable Paper Pro (ferrari)
// Base concept from https://github.com/dps/remarkable-wikipedia (MIT)
// Copyright (c) 2019 David Singleton
// libzim integration: https://github.com/openzim/libzim (GPL-2.0-or-later)

#include "wikipedia-backend.h"

#include <zim/zim.h>
#include <zim/archive.h>
#include <zim/entry.h>
#include <zim/item.h>
#include <zim/blob.h>
#include <zim/suggestion.h>
#include <zim/suggestion_iterator.h>

#include <QDir>
#include <QFileInfo>
#include <QDebug>
#include <QRegularExpression>
#include <QByteArray>
#include <stdexcept>

WikipediaBackend::WikipediaBackend(QObject *parent)
    : QObject(parent)
{
}

WikipediaBackend::~WikipediaBackend() = default;

bool WikipediaBackend::hasArchive() const
{
    return m_archive != nullptr;
}

bool WikipediaBackend::openArchive(const QString &path)
{
    try {
        m_archive = std::make_unique<zim::Archive>(path.toStdString());
        m_searcher = std::make_unique<zim::SuggestionSearcher>(*m_archive);
        m_archivePath = path;

        // Try reading title metadata
        try {
            m_archiveTitle = QString::fromStdString(m_archive->getMetadata("Title"));
        } catch (...) {
            m_archiveTitle = QFileInfo(path).baseName();
        }

        // Determine main page
        if (m_archive->hasMainEntry()) {
            m_mainPage = QString::fromStdString(m_archive->getMainEntry().getPath());
        } else if (m_archive->hasEntryByPath("main")) {
            m_mainPage = "main";
        } else if (m_archive->hasEntryByPath("Main_Page")) {
            m_mainPage = "Main_Page";
        } else if (m_archive->hasEntryByPath("A/Main_Page.html")) {
            m_mainPage = "A/Main_Page.html";
        } else {
            m_mainPage.clear();
        }

        qInfo() << "[WikipediaBackend] Loaded archive:" << path
                << "Title:" << m_archiveTitle
                << "MainPage:" << m_mainPage;

        emit archiveChanged();
        return true;
    } catch (const std::exception &e) {
        qWarning() << "[WikipediaBackend] Failed to open archive:" << path << ":" << e.what();
        m_archive.reset();
        m_searcher.reset();
        m_archiveTitle.clear();
        m_mainPage.clear();
        m_archivePath.clear();
        emit archiveChanged();
        return false;
    }
}

bool WikipediaBackend::autoOpen(const QString &preferredDir)
{
    QStringList candidates;
    if (!preferredDir.isEmpty()) {
        candidates.append(preferredDir);
    }
    candidates << "/home/root/zim" << "/home/root" << ".";

    for (const QString &dirPath : candidates) {
        QDir dir(dirPath);
        if (!dir.exists()) {
            continue;
        }

        QStringList zims = dir.entryList(QStringList() << "*.zim", QDir::Files | QDir::Readable, QDir::Name);
        if (!zims.isEmpty()) {
            QString fullPath = dir.filePath(zims.first());
            if (openArchive(fullPath)) {
                return true;
            }
        }
    }
    return false;
}

QStringList WikipediaBackend::availableArchives(const QString &searchDir)
{
    QString target = searchDir.isEmpty() ? "/home/root/zim" : searchDir;
    QDir dir(target);
    QStringList paths;
    if (dir.exists()) {
        const auto entries = dir.entryList(QStringList() << "*.zim", QDir::Files | QDir::Readable);
        for (const auto &entry : entries) {
            paths.append(dir.filePath(entry));
        }
    }
    return paths;
}

zim::Entry WikipediaBackend::findEntry(const QString &query)
{
    if (!m_archive) {
        throw std::runtime_error("No ZIM archive is currently open");
    }

    QString q = query.trimmed();
    while (q.startsWith("./")) {
        q = q.mid(2);
    }
    while (q.startsWith("/")) {
        q = q.mid(1);
    }

    std::string s = q.toStdString();

    // 1. Direct path lookup
    if (m_archive->hasEntryByPath(s)) {
        return m_archive->getEntryByPath(s);
    }

    // 2. Direct title lookup
    if (m_archive->hasEntryByTitle(s)) {
        return m_archive->getEntryByTitle(s);
    }

    // 3. Namespace A/ prefix fallback (for legacy ZIM layout)
    if (!q.startsWith("A/") && m_archive->hasEntryByPath("A/" + s)) {
        return m_archive->getEntryByPath("A/" + s);
    }

    // 4. Try stripping .html suffix if present
    if (q.endsWith(".html", Qt::CaseInsensitive)) {
        QString stripped = q.left(q.length() - 5);
        std::string ss = stripped.toStdString();
        if (m_archive->hasEntryByPath(ss)) {
            return m_archive->getEntryByPath(ss);
        }
        if (m_archive->hasEntryByTitle(ss)) {
            return m_archive->getEntryByTitle(ss);
        }
        if (m_archive->hasEntryByPath("A/" + ss)) {
            return m_archive->getEntryByPath("A/" + ss);
        }
    }

    // 5. Try adding .html suffix if absent
    if (!q.endsWith(".html", Qt::CaseInsensitive)) {
        std::string withHtml = (q + ".html").toStdString();
        if (m_archive->hasEntryByPath(withHtml)) {
            return m_archive->getEntryByPath(withHtml);
        }
        if (m_archive->hasEntryByPath("A/" + withHtml)) {
            return m_archive->getEntryByPath("A/" + withHtml);
        }
    }

    // 6. Percent decoding
    QByteArray decoded = QByteArray::fromPercentEncoding(q.toUtf8());
    std::string dec = decoded.toStdString();
    if (dec != s) {
        if (m_archive->hasEntryByPath(dec)) {
            return m_archive->getEntryByPath(dec);
        }
        if (m_archive->hasEntryByTitle(dec)) {
            return m_archive->getEntryByTitle(dec);
        }
        if (m_archive->hasEntryByPath("A/" + dec)) {
            return m_archive->getEntryByPath("A/" + dec);
        }
    }

    // 7. Underscores vs spaces
    QString spaceReplaced = q;
    spaceReplaced.replace('_', ' ');
    std::string sspace = spaceReplaced.toStdString();
    if (m_archive->hasEntryByTitle(sspace)) {
        return m_archive->getEntryByTitle(sspace);
    }

    throw std::runtime_error("Entry not found in archive");
}

QString WikipediaBackend::cleanHtmlForEpaper(const QString &rawHtml)
{
    QString html = rawHtml;

    // Isolate main Wikipedia article body if present
    int idx = html.indexOf("<div id=\"bodyContent\"");
    if (idx < 0) {
        idx = html.indexOf("<div class=\"mw-parser-output\"");
    }
    if (idx < 0) {
        idx = html.indexOf("<div id=\"content\"");
    }
    if (idx >= 0) {
        html = html.mid(idx);
    }

    // Style links in black with underline for readability on e-paper
    static const QRegularExpression aRegex("<a\\s+", QRegularExpression::CaseInsensitiveOption);
    html.replace(aRegex, "<a style='color: black; text-decoration: underline;' ");

    return html;
}

QString WikipediaBackend::getArticleHtml(const QString &pathOrTitle)
{
    if (!m_archive) {
        return "<h1>No ZIM Archive Found</h1>"
               "<p>Please place a Wikipedia <code>.zim</code> file in <b>/home/root/zim/</b>.</p>"
               "<p>Example: <code>alpinelinux.zim</code> or <code>wikipedia_en_all_nopic.zim</code>.</p>";
    }

    try {
        zim::Entry entry = findEntry(pathOrTitle);
        // Automatically follow redirect chain if entry is a redirect:
        zim::Item item = entry.getItem(true);
        zim::Blob blob = item.getData();
        QString raw = QString::fromUtf8(blob.data(), static_cast<int>(blob.size()));
        return cleanHtmlForEpaper(raw);
    } catch (const std::exception &e) {
        qWarning() << "[WikipediaBackend] Failed to load article:" << pathOrTitle << ":" << e.what();
        return QString("<h1>Article Not Found</h1>"
                       "<p>Could not locate <b>%1</b> in archive <i>%2</i>.</p>"
                       "<p><small>Error: %3</small></p>")
            .arg(pathOrTitle.toHtmlEscaped(), m_archiveTitle.toHtmlEscaped(), QString::fromUtf8(e.what()).toHtmlEscaped());
    }
}

QVariantList WikipediaBackend::getSuggestions(const QString &query, int limit)
{
    QVariantList list;
    if (!m_searcher || query.trimmed().isEmpty()) {
        return list;
    }

    try {
        auto search = m_searcher->suggest(query.trimmed().toUtf8().toStdString());
        auto results = search.getResults(0, limit);
        for (auto it = results.begin(); it != results.end(); ++it) {
            QVariantMap item;
            item["title"] = QString::fromStdString(it->getTitle());
            item["path"] = QString::fromStdString(it->getPath());
            if (it->hasSnippet()) {
                item["snippet"] = QString::fromStdString(it->getSnippet());
            }
            list.append(item);
        }
    } catch (const std::exception &e) {
        qWarning() << "[WikipediaBackend] Suggestion search error:" << e.what();
    }

    return list;
}
