/*
 * Claudometer — main.qml
 *
 * Root of the plasmoid. Owns ALL state and the polling loop:
 *   Timer → run bundled helper via the "executable" engine → parse stdout
 * The compact (panel) representation lives inline here; the popup is in
 * FullRepresentation.qml.
 */
import QtQuick
import QtQuick.Layouts
import org.kde.plasma.plasmoid
import org.kde.plasma.core as PlasmaCore
import org.kde.plasma.plasma5support as P5Support
import org.kde.kirigami as Kirigami

PlasmoidItem {
    id: root

    // ---- state ------------------------------------------------------------
    property var buckets: []          // [{id,label,pct,resets_at}]
    property var extraUsage: ({})     // {enabled, used_credits, monthly_limit}
    property bool hasData: false      // ever had a successful fetch?
    property string errorType: ""     // "" = healthy
    property string errorMessage: ""
    property double lastSuccess: 0    // ms epoch of last good fetch
    property double lastAttempt: 0    // ms epoch of last fetch attempt
    property double cooldownUntil: 0  // ms epoch; no fetch before this (server 429)
    property int retryAfterSec: 0     // server's stated wait, for display
    property var notified: ({})       // per-bucket notification latches

    readonly property int intervalMs: Plasmoid.configuration.updateInterval * 1000

    // Data is "stale" when the last success is older than 3 polling intervals.
    readonly property bool stale:
        hasData && (now - lastSuccess > 3 * intervalMs)

    // True while we're honoring a server-mandated 429 cooldown. Driven by
    // `now` (the 30 s clock) so the UI counts down on its own.
    readonly property bool rateLimited: now < cooldownUntil
    readonly property int cooldownLeftSec: Math.max(0, Math.round((cooldownUntil - now) / 1000))

    // A coarse clock for countdown labels ("resets in 2h 14m") so they tick
    // without re-fetching anything.
    property double now: Date.now()
    Timer { interval: 30000; running: true; repeat: true
            onTriggered: root.now = Date.now() }

    // The two headline buckets, for the panel bars and tooltip.
    readonly property var sessionBucket: findBucket("five_hour")
    readonly property var weeklyBucket: findBucket("seven_day")
    function findBucket(id) {
        for (let i = 0; i < buckets.length; i++)
            if (buckets[i].id === id) return buckets[i]
        return null
    }

    // Buckets shown in the popup: just the two headliners (session + week).
    readonly property var visibleBuckets:
        buckets.filter(b => b.id === "five_hour" || b.id === "seven_day")

    // ---- colors -----------------------------------------------------------
    // The classic palette (green/blue/orange/red/white), always applied — every
    // color is user-editable in settings, so there's no separate theme mode.
    // `normal` is the sub-warning fill and differs per bar (session green vs
    // weekly blue); warning/critical are shared once a bar crosses its threshold.
    function barColor(pct, normal) {
        const cfg = Plasmoid.configuration
        if (pct >= cfg.critThreshold) return cfg.colorCritical
        if (pct >= cfg.warnThreshold) return cfg.colorWarning
        return normal
    }

    // The per-bar "normal" color: green for the 5h session, blue for the weekly
    // limit (and any extra per-model bucket).
    function normalColorFor(id) {
        const cfg = Plasmoid.configuration
        return id === "five_hour" ? cfg.colorSession : cfg.colorWeekly
    }

    // Panel label color (the countdown + percentage text).
    function panelTextColor() {
        return Plasmoid.configuration.colorText
    }

    // ---- fetching ---------------------------------------------------------
    // One fixed command, nothing interpolated into it (it runs via /bin/sh).
    readonly property string helperCmd: "python3 '"
        + Qt.resolvedUrl("../scripts/claudometer.py").toString().replace("file://", "")
        + "'"

    P5Support.DataSource {
        id: exec
        engine: "executable"
        connectedSources: []
        onNewData: function (source, data) {
            disconnectSource(source)  // one-shot: stop the engine re-running it
            if (source === root.helperCmd)
                root.handleResult(data["stdout"], data["exit code"])
            // notify-send sources need no result handling
        }
    }

    function fetchNow(force) {
        // Server-mandated 429 cooldown is absolute — it gates even manual
        // refreshes, so we can never re-trip the limit by retrying too early.
        if (Date.now() < cooldownUntil) return
        // Otherwise throttle bursts (timer + popup-open may coincide).
        if (!force && Date.now() - lastAttempt < 60000) return
        lastAttempt = Date.now()
        exec.connectSource(helperCmd)
    }

    // Constant cadence; fetchNow() self-gates on the cooldown, so a long 429
    // wait simply means the next few ticks no-op until the server is ready.
    Timer {
        interval: root.intervalMs
        running: true; repeat: true; triggeredOnStart: true
        onTriggered: root.fetchNow(false)
    }

    // Refresh when the popup opens, so the details are current on click.
    onExpandedChanged: if (expanded) fetchNow(false)

    function handleResult(stdout, exitCode) {
        let payload
        try {
            payload = JSON.parse(stdout)
        } catch (e) {
            setError("helper", "Helper produced invalid output (exit " + exitCode + ")")
            return
        }
        if (!payload.ok) {
            setError(payload.error_type, payload.error, payload.retry_after)
            return
        }
        errorType = ""
        errorMessage = ""
        cooldownUntil = 0
        retryAfterSec = 0
        buckets = payload.buckets
        extraUsage = payload.extra_usage || {}
        hasData = true
        lastSuccess = Date.now()
        now = Date.now()
        checkNotifications()
    }

    function setError(type, message, retryAfter) {
        errorType = type
        errorMessage = message
        // Rate limited → wait exactly as long as the server asked (plus a
        // 15 s margin). Falls back to 15 min if the header was missing.
        if (type === "rate_limited") {
            var wait = (retryAfter && retryAfter > 0) ? retryAfter : 900
            retryAfterSec = wait
            cooldownUntil = Date.now() + (wait + 15) * 1000
            now = Date.now()  // refresh derived rateLimited/cooldownLeftSec now
        }
    }

    // ---- notifications ----------------------------------------------------
    // Fixed message strings + integer percentages only — nothing from the
    // API ever reaches the shell, so injection is structurally impossible.
    function checkNotifications() {
        if (!Plasmoid.configuration.notificationsEnabled) return
        const cfg = Plasmoid.configuration
        const watch = { five_hour: "Session limit", seven_day: "Weekly limit" }
        for (const id in watch) {
            const b = findBucket(id)
            if (!b) continue
            const pct = Math.round(b.pct)
            const state = notified[id] || ""
            if (pct >= cfg.critThreshold && state !== "crit") {
                notify("dialog-error", watch[id] + " at " + pct + "%", "critical")
                notified[id] = "crit"
            } else if (pct >= cfg.warnThreshold && state === "") {
                notify("dialog-warning", watch[id] + " at " + pct + "%", "normal")
                notified[id] = "warn"
            } else if (pct < cfg.warnThreshold) {
                notified[id] = ""   // reset latch after the limit resets
            }
        }
    }
    function notify(icon, body, urgency) {
        exec.connectSource("notify-send -a Claudometer -i " + icon
                           + " -u " + urgency + " 'Claude usage' '" + body + "'")
    }

    // ---- formatting helpers (shared with FullRepresentation) ---------------
    function fmtCountdown(resetsAt) {
        if (!resetsAt) return ""
        const ms = new Date(resetsAt).getTime() - now
        if (isNaN(ms) || ms <= 0) return i18n("resets soon")
        const min = Math.ceil(ms / 60000)
        if (min < 60) return i18n("resets in %1m", min)
        const h = Math.floor(min / 60)
        if (h < 48) return i18n("resets in %1h %2m", h, min % 60)
        return i18n("resets in %1d %2h", Math.floor(h / 24), h % 24)
    }
    // Short panel form — time left on a limit, largest unit, rounded UP:
    // "14m" / "3h" / "5d". 4h30m → "5h"; drops to "4h" only once under 4h00m
    // (same for minutes and days). Single ceil per unit keeps it monotonic — it
    // never skips a value ticking down. Uses root.now so the panel ticks for
    // free, no re-fetch.
    function fmtCompactCountdown(resetsAt) {
        if (!resetsAt) return ""
        const ms = new Date(resetsAt).getTime() - now
        if (isNaN(ms)) return ""
        if (ms <= 0) return i18n("0m")
        const min = ms / 60000            // minutes left (fractional)
        if (min < 60) return i18n("%1m", Math.ceil(min))     // 1m … 59m
        const h = ms / 3600000            // hours left (fractional)
        if (h < 24) return i18n("%1h", Math.ceil(h))         // 1h … 24h
        return i18n("%1d", Math.ceil(ms / 86400000))         // 1d … 7d
    }
    function fmtAgo(t) {
        if (!t) return i18n("never")
        const s = Math.max(0, Math.round((now - t) / 1000))
        if (s < 60) return i18n("%1s ago", s)
        return i18n("%1m ago", Math.round(s / 60))
    }
    // Bare duration ("45s" / "8m") — callers supply the surrounding phrasing.
    function fmtCooldown() {
        const s = cooldownLeftSec
        if (s <= 0) return ""
        return s < 60 ? i18n("%1s", s) : i18n("%1m", Math.ceil(s / 60))
    }

    // ---- plasmoid chrome ---------------------------------------------------
    Plasmoid.icon: "speedometer"
    toolTipMainText: i18n("Claude usage")
    toolTipSubText: {
        if (errorType && !hasData)
            return rateLimited ? i18n("%1 Retrying in %2.", errorMessage, fmtCooldown())
                               : errorMessage
        if (!hasData) return i18n("Waiting for first update…")
        let lines = []
        if (sessionBucket)
            lines.push(i18n("Session %1% — %2", Math.round(sessionBucket.pct),
                            fmtCountdown(sessionBucket.resets_at)))
        if (weeklyBucket)
            lines.push(i18n("Week %1% — %2", Math.round(weeklyBucket.pct),
                            fmtCountdown(weeklyBucket.resets_at)))
        if (rateLimited) lines.push(i18n("⚠ Rate limited — retrying in %1", fmtCooldown()))
        else if (stale) lines.push(i18n("⚠ data is stale (%1)", fmtAgo(lastSuccess)))
        else if (errorType) lines.push("⚠ " + errorMessage)
        return lines.join("\n")
    }

    // ---- compact representation (the panel face) ----------------------------
    // Classic look: [countdown] [chunky rounded-rectangle bar] [percentage].
    // Each label is centered in a fixed-width column, so the bar stays put and
    // the numbers line up row-to-row regardless of digit count.
    compactRepresentation: MouseArea {
        id: compact
        onClicked: root.expanded = !root.expanded

        // 30 + 4 + 80 + 4 + 36 = 154 content + 8 padding = 162.
        Layout.minimumWidth: 162
        Layout.preferredWidth: 162

        // Dim the bars when data is stale or erroring; badge explains why.
        opacity: (root.stale || (root.errorType && !root.hasData)) ? 0.5 : 1.0

        ColumnLayout {
            anchors.centerIn: parent
            spacing: 4

            Repeater {
                // id drives the per-bar color (green session / blue weekly);
                // full is the max-window label shown before a limit is first
                // used (the API reports no reset time until then).
                model: [
                    { id: "five_hour", bucket: root.sessionBucket, full: "5h" },
                    { id: "seven_day", bucket: root.weeklyBucket, full: "7d" },
                ]
                delegate: RowLayout {
                    spacing: 4

                    // Left: time left on this limit, centered in its column.
                    // Falls back to the full window ("5h"/"7d") when unused.
                    Text {
                        text: root.fmtCompactCountdown(
                                  modelData.bucket ? modelData.bucket.resets_at : null)
                              || modelData.full
                        color: root.panelTextColor()
                        font.pixelSize: 12
                        font.bold: true
                        font.family: "Noto Serif"
                        Layout.alignment: Qt.AlignVCenter
                        Layout.preferredWidth: 30
                        Layout.fillWidth: false
                        horizontalAlignment: Text.AlignHCenter
                    }

                    // Center: chunky rounded-rectangle bar (track + fill).
                    Item {
                        implicitWidth: 80
                        Layout.preferredWidth: 80
                        Layout.fillWidth: false
                        height: 15
                        Layout.alignment: Qt.AlignVCenter
                        // translucent track…
                        Rectangle {
                            anchors.fill: parent
                            radius: 4
                            color: root.panelTextColor()
                            opacity: 0.15
                        }
                        // …with a colored fill on top
                        Rectangle {
                            height: parent.height
                            radius: 4
                            width: parent.width *
                                Math.min(1, (modelData.bucket ? modelData.bucket.pct : 0) / 100)
                            color: root.barColor(
                                modelData.bucket ? modelData.bucket.pct : 0,
                                root.normalColorFor(modelData.id))
                            Behavior on width { NumberAnimation { duration: 300 } }
                        }
                    }

                    // Right: percentage, centered in its column.
                    Text {
                        text: modelData.bucket
                            ? Math.round(modelData.bucket.pct) + "%"
                            : "–%"
                        color: root.panelTextColor()
                        font.pixelSize: 12
                        font.bold: true
                        font.family: "Noto Serif"
                        Layout.alignment: Qt.AlignVCenter
                        Layout.preferredWidth: 36
                        Layout.fillWidth: false
                        horizontalAlignment: Text.AlignHCenter
                    }
                }
            }
        }

        // Small warning emblem when something is wrong.
        Kirigami.Icon {
            visible: root.errorType !== "" || root.stale
            source: "emblem-warning"
            width: Kirigami.Units.iconSizes.small
            height: width
            anchors.right: parent.right
            anchors.bottom: parent.bottom
        }
    }

    fullRepresentation: FullRepresentation {}
}
